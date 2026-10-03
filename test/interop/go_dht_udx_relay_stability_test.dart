import 'dart:math';
import 'dart:typed_data';

import 'package:dart_udx/dart_udx.dart';
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/transport_conn.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/network/context.dart' as core_context;
import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/config/stream_muxer.dart';
import 'package:dart_libp2p/p2p/host/basic/basic_host.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/client/reservation.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/multiplexer.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/metrics_observer.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/session.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'helpers/go_process_manager.dart';

/// Yamux muxer provider with configurable yamux settings and optional metrics observer.
class _TestYamuxMuxerProvider extends StreamMuxer {
  _TestYamuxMuxerProvider({
    required MultiplexerConfig yamuxConfig,
    YamuxMetricsObserver? metricsObserver,
  }) : super(
          id: YamuxConstants.protocolId,
          muxerFactory: (Conn secureConn, bool isClient) {
            if (secureConn is! TransportConn) {
              throw ArgumentError(
                  'YamuxMuxer factory expects a TransportConn, got ${secureConn.runtimeType}');
            }
            return YamuxSession(
                secureConn, yamuxConfig, isClient, null, metricsObserver);
          },
        );
}

/// Collects yamux ping/pong metrics for test assertions.
class _TestMetricsObserver implements YamuxMetricsObserver {
  final List<_PingRecord> pings = [];
  final List<_PongRecord> pongs = [];
  final List<String> errors = [];

  @override
  void onPingSent(PeerId remotePeer, int pingId, DateTime timestamp) {
    pings.add(_PingRecord(remotePeer, pingId, timestamp));
  }

  @override
  void onPongReceived(PeerId remotePeer, int pingId, DateTime sentTime,
      DateTime receivedTime, Duration rtt) {
    pongs.add(_PongRecord(remotePeer, pingId, sentTime, receivedTime, rtt));
  }

  @override
  void onStreamOpenStart(PeerId remotePeer, int streamId) {}
  @override
  void onStreamOpened(PeerId remotePeer, int streamId, String? protocol) {}
  @override
  void onStreamClosed(PeerId remotePeer, int streamId, Duration duration,
      int bytesRead, int bytesWritten) {}
  @override
  void onStreamReset(PeerId remotePeer, int streamId, String? reason) {}
  @override
  void onSessionError(PeerId remotePeer, String error, StackTrace? stackTrace) {
    errors.add(error);
  }
}

class _PingRecord {
  final PeerId remotePeer;
  final int pingId;
  final DateTime timestamp;
  _PingRecord(this.remotePeer, this.pingId, this.timestamp);
}

class _PongRecord {
  final PeerId remotePeer;
  final int pingId;
  final DateTime sentTime;
  final DateTime receivedTime;
  final Duration rtt;
  _PongRecord(
      this.remotePeer, this.pingId, this.sentTime, this.receivedTime, this.rtt);
}

void main() {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    if (record.level >= Level.WARNING ||
        record.loggerName.contains('Yamux') ||
        record.loggerName.contains('BasicHost')) {
      print('${record.level.name}: ${record.loggerName}: ${record.message}');
    }
  });

  late String goBinaryPath;

  const keepAliveInterval = Duration(seconds: 3);

  final yamuxConfig = MultiplexerConfig(
    keepAliveInterval: keepAliveInterval,
    maxStreamWindowSize: 1024 * 1024,
    initialStreamWindowSize: 256 * 1024,
    streamWriteTimeout: Duration(seconds: 10),
    maxStreams: 256,
  );

  setUpAll(() async {
    final goSourceDir = goPeerSourceDir();
    goBinaryPath = await GoProcessManager.ensureBinary(goSourceDir);
    print('Go peer binary: $goBinaryPath');
  });

  Future<BasicHost> createHost(
    KeyPair keyPair, {
    List<MultiAddr>? listenAddrs,
    YamuxMetricsObserver? metricsObserver,
    bool enableRelay = false,
  }) async {
    final connMgr = ConnectionManager();
    final udxInstance = UDX();
    final muxerDef = _TestYamuxMuxerProvider(
        yamuxConfig: yamuxConfig, metricsObserver: metricsObserver);

    final config = p2p_config.Config()
      ..peerKey = keyPair
      ..securityProtocols = [await NoiseSecurity.create(keyPair)]
      ..muxers = [muxerDef]
      ..transports = [
        UDXTransport(connManager: connMgr, udxInstance: udxInstance)
      ]
      ..connManager = connMgr
      ..enableRelay = enableRelay;
    config.addrsFactory = (addrs) => addrs;

    if (listenAddrs != null) {
      config.listenAddrs = listenAddrs;
    }

    final host = await config.newNode() as BasicHost;
    await host.start();
    return host;
  }

  /// Helper: open an echo stream, send data, verify echo response.
  Future<void> echoVerify(BasicHost host, PeerId remotePeer,
      {int size = 32}) async {
    final stream = await host.newStream(
        remotePeer, ['/echo/1.0.0'], core_context.Context());
    expect(stream.protocol(), '/echo/1.0.0');

    final random = Random();
    final data =
        Uint8List.fromList(List.generate(size, (_) => random.nextInt(256)));

    await stream.write(data);
    await stream.closeWrite();

    // Read all response data (may arrive in multiple chunks for large payloads)
    final chunks = <Uint8List>[];
    var totalRead = 0;
    while (totalRead < size) {
      try {
        final chunk = await stream.read();
        if (chunk.isEmpty) break;
        chunks.add(chunk);
        totalRead += chunk.length;
      } catch (_) {
        break;
      }
    }
    final response = Uint8List(totalRead);
    var offset = 0;
    for (final chunk in chunks) {
      response.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }

    expect(response, orderedEquals(data),
        reason: 'Echo mismatch for $size bytes');
    await stream.close();
  }

  group('UDX DHT + Relay Stability', () {
    late GoProcessManager goProcess;
    BasicHost? dartHost;
    IpfsDHT? dartDHT;

    setUp(() {
      goProcess = GoProcessManager(binaryPath: goBinaryPath);
    });

    tearDown(() async {
      if (dartDHT != null) {
        await dartDHT!.close();
        dartDHT = null;
      }
      if (dartHost != null) {
        await dartHost!.close();
        dartHost = null;
      }
      await goProcess.stop();
    });

    test('DHT queries succeed while relay CONNECT stream is active over UDX',
        () async {
      // Reproduces production failure from go-ricochet server logs:
      //
      // Production timeline (from 2026-02-24 server logs):
      //   T+0s:  Dart connects over UDX, DHT FIND_NODE/PING succeed
      //   T+5s:  Dart makes relay reservation → long-lived HOP stream
      //   T+10s: Go DHT RT refresh tries opening stream TO Dart →
      //          "context deadline exceeded"
      //   T+12s: "failed to open stream: timed out"
      //   T+13s: "failed to open stream: i/o deadline reached"
      //
      // Root cause hypothesis: yamux write serialization under UDX flow
      // control — the relay HOP stream + DHT streams compete for the
      // yamux write lock, causing Go's SYN frames to time out.
      //
      // Key: the failure is Go opening streams TO Dart (DHT routing table
      // maintenance), NOT Dart opening streams to Go. So Dart must run
      // DHT in server mode so Go's RT refresh will query Dart.

      // 1. Start Go peer as combined DHT server + relay over UDX
      //    with aggressive keepalive to match production config
      await goProcess.startDHTRelayServer(
        transport: 'udx',
        yamuxKeepAliveInterval: keepAliveInterval,
        yamuxWriteTimeout: const Duration(seconds: 10),
      );
      final goAddr = goProcess.listenAddr;
      final goPeerId = goProcess.peerId;
      print('Go DHT+relay server: $goAddr (${goPeerId.toBase58()})');

      // 2. Create Dart host ("mobile client") with UDX + relay + DHT
      //    Must listen on UDX so Go can open streams back to us
      final metricsObserver = _TestMetricsObserver();
      final keyPairA = await crypto_ed25519.generateEd25519KeyPair();
      final dartPeerId = await PeerId.fromPublicKey(keyPairA.publicKey);
      dartHost = await createHost(keyPairA,
          listenAddrs: [MultiAddr('/ip4/127.0.0.1/udp/0/udx')],
          metricsObserver: metricsObserver,
          enableRelay: true);
      print('Dart host: ${dartHost!.addrs.first} (${dartPeerId.toBase58()})');

      // 3. Dart connects to Go and bootstraps DHT in SERVER mode
      //    Server mode means Go's RT refresh will try querying us
      await dartHost!.connect(AddrInfo(goPeerId, [goAddr]),
          context: core_context.Context());
      print('Dart connected to Go peer over UDX');

      dartDHT = IpfsDHT(
        host: dartHost!,
        providerStore: MemoryProviderStore(),
        options: DHTOptions(mode: DHTMode.server),
      );
      await dartDHT!.start();
      await dartDHT!.routingTable.tryAddPeer(goPeerId, queryPeer: false);
      print('Dart DHT started in SERVER mode');

      // 4. Baseline: Dart→Go DHT findPeer should succeed
      final baselineResult = await dartDHT!.findPeer(goPeerId);
      expect(baselineResult, isNotNull, reason: 'Baseline findPeer should succeed');
      print('Baseline DHT findPeer (Dart→Go) succeeded');

      // 5. Dart makes relay reservation on Go
      //    This creates a long-lived HOP stream on the Go ↔ Dart yamux session
      //    (matches production: "new relay stream" → "reserving relay slot")
      final relayClient = dartHost!.circuitV2Client;
      expect(relayClient, isNotNull,
          reason: 'CircuitV2Client should be created when relay is enabled');
      final reservation = await relayClient!.reserve(goPeerId);
      print('Relay reservation made, expires: ${reservation.expire}');

      // 6. Wait 15s — production failure window
      //    Go's DHT routing table refresh interval is typically 10s for
      //    the first CPL bucket. During this time:
      //    - The relay reservation HOP stream stays open
      //    - Yamux keepalive pings flow every 3s
      //    - Go's DHT RT refresh will try opening new streams TO Dart
      //    In production, this is where "i/o deadline reached" appears
      print('Waiting 15s for Go DHT RT refresh to attempt streams TO Dart...');
      await Future.delayed(const Duration(seconds: 15));

      // 7. Check Go's stderr for the production failure signature
      final goOutput = goProcess.output;
      final ioDeadlineErrors = goOutput
          .where((line) => line.contains('i/o deadline reached'))
          .toList();
      final contextDeadlineErrors = goOutput
          .where((line) =>
              line.contains('context deadline exceeded') &&
              line.contains('dht'))
          .toList();
      final streamOpenFailures = goOutput
          .where((line) => line.contains('failed to open stream'))
          .toList();

      if (ioDeadlineErrors.isNotEmpty) {
        print('BUG REPRODUCED — Go "i/o deadline reached" errors:');
        for (final line in ioDeadlineErrors) {
          print('  $line');
        }
      }
      if (streamOpenFailures.isNotEmpty) {
        print('Go stream-open failures:');
        for (final line in streamOpenFailures) {
          print('  $line');
        }
      }
      if (contextDeadlineErrors.isNotEmpty) {
        print('Go DHT context deadline errors:');
        for (final line in contextDeadlineErrors) {
          print('  $line');
        }
      }

      // 8. Check Dart-side session errors
      if (metricsObserver.errors.isNotEmpty) {
        print('Dart session errors during idle:');
        for (final err in metricsObserver.errors) {
          print('  - $err');
        }
      }

      // 9. Try Dart→Go DHT query after the idle period
      //    Even if Go→Dart failed, Dart→Go might still work (or vice versa)
      print('Attempting Dart→Go DHT query after idle...');
      try {
        final postIdleResult = await dartDHT!.findPeer(goPeerId);
        print('Post-idle Dart→Go findPeer: ${postIdleResult != null ? "succeeded" : "returned null"}');
      } catch (e) {
        print('Post-idle Dart→Go DHT query failed: $e');
      }

      // 10. Verify echo still works on the direct UDX connection
      try {
        await echoVerify(dartHost!, goPeerId);
        print('Direct echo to Go still works after idle');
      } catch (e) {
        print('Direct echo FAILED after idle: $e');
      }

      // Assert: the production failure should NOT happen (or if it does,
      // we've reproduced the bug and should fail the test)
      expect(ioDeadlineErrors, isEmpty,
          reason: 'Go should not get "i/o deadline reached" opening streams to Dart');
      expect(metricsObserver.errors, isEmpty,
          reason: 'No Dart session errors expected');
      print('Test passed — no i/o deadline errors over UDX');
    }, timeout: Timeout(Duration(seconds: 90)));
  });
}
