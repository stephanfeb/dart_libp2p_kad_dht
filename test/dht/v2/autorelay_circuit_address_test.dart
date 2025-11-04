import 'dart:async';

import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/network/network.dart';
import 'package:dart_libp2p/core/peer/pb/peer_record.pb.dart' as pb;
import 'package:dart_libp2p/core/peer/record.dart';
import 'package:dart_libp2p/core/record/record_registry.dart';
import 'package:dart_libp2p/p2p/host/autorelay/autorelay.dart';
import 'package:dart_libp2p/p2p/host/autonat/ambient_config.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/transport_conn.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_eventbus;
import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/basic_upgrader.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/session.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/multiplexer.dart';
import 'package:dart_libp2p/config/stream_muxer.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_transport;
import 'package:dart_libp2p/p2p/network/swarm/swarm.dart';
import 'package:dart_libp2p/p2p/host/basic/basic_host.dart';
import 'package:dart_libp2p/p2p/host/peerstore/pstoremem.dart';
import 'package:dart_libp2p/core/event/bus.dart' as core_event_bus;
import 'package:dart_libp2p_kad_dht/src/dht/v2/dht_v2.dart';
import 'package:dart_libp2p_kad_dht/src/dht/dht_options.dart';
import 'package:dart_libp2p_kad_dht/src/providers/provider_store.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

// Custom AddrsFactory for testing that doesn't filter loopback
List<MultiAddr> passThroughAddrsFactory(List<MultiAddr> addrs) {
  return addrs;
}

// Helper class for providing YamuxMuxer to the config
class _TestYamuxMuxerProvider extends StreamMuxer {
  final MultiplexerConfig yamuxConfig;

  _TestYamuxMuxerProvider({required this.yamuxConfig})
      : super(
          id: YamuxConstants.protocolId,
          muxerFactory: (Conn secureConn, bool isClient) {
            if (secureConn is! TransportConn) {
              throw ArgumentError(
                  'YamuxMuxer factory expects a TransportConn, got ${secureConn.runtimeType}');
            }
            return YamuxSession(secureConn, yamuxConfig, isClient);
          },
        );
}

// Record type for returning node details
typedef Libp2pNode = ({
  BasicHost host,
  PeerId peerId,
  List<MultiAddr> listenAddrs,
  KeyPair keyPair
});

Future<Libp2pNode> createLibp2pNode({
  required UDX udxInstance,
  required ResourceManager resourceManager,
  required p2p_transport.ConnectionManager connManager,
  required core_event_bus.EventBus hostEventBus,
  KeyPair? keyPair,
  List<MultiAddr>? listenAddrsOverride,
  String? userAgentPrefix,
  bool enableRelay = false,
  bool enableAutoRelay = false,
  bool enablePing = false,
  Reachability? forceReachability,
  AmbientAutoNATv2Config? ambientAutoNATConfig,
  List<String>? relayServers,
}) async {
  final kp = keyPair ?? await crypto_ed25519.generateEd25519KeyPair();
  final peerId = await PeerId.fromPublicKey(kp.publicKey);

  final yamuxMultiplexerConfig = MultiplexerConfig(
    keepAliveInterval: Duration(seconds: 15),
    maxStreamWindowSize: 1024 * 1024,
    initialStreamWindowSize: 256 * 1024,
    streamWriteTimeout: Duration(seconds: 10),
    maxStreams: 256,
  );
  final muxerDefs = [_TestYamuxMuxerProvider(yamuxConfig: yamuxMultiplexerConfig)];
  final securityProtocols = [await NoiseSecurity.create(kp)];
  final peerstore = MemoryPeerstore();

  peerstore.keyBook.addPrivKey(peerId, kp.privateKey);
  peerstore.keyBook.addPubKey(peerId, kp.publicKey);

  final transport = UDXTransport(connManager: connManager, udxInstance: udxInstance);
  final upgrader = BasicUpgrader(resourceManager: resourceManager);

  final defaultListenAddrs = [MultiAddr('/ip4/0.0.0.0/udp/0/udx')];
  final currentListenAddrs = listenAddrsOverride ?? defaultListenAddrs;

  // Swarm Config
  final swarmConfig = p2p_config.Config()
    ..peerKey = kp
    ..enableAutoNAT = false
    ..enableHolePunching = false
    ..enableRelay = enableRelay
    ..connManager = connManager
    ..eventBus = p2p_eventbus.BasicBus()
    ..addrsFactory = passThroughAddrsFactory
    ..securityProtocols = securityProtocols
    ..muxers = muxerDefs;
  
  if (listenAddrsOverride == null || listenAddrsOverride.isNotEmpty) {
    swarmConfig.listenAddrs = currentListenAddrs;
  }

  final network = Swarm(
    localPeer: peerId,
    peerstore: peerstore,
    upgrader: upgrader,
    config: swarmConfig,
    transports: [transport],
    resourceManager: resourceManager,
    host: null,
  );

  // BasicHost Config
  final hostConfig = p2p_config.Config()
    ..peerKey = kp
    ..eventBus = hostEventBus
    ..connManager = connManager
    ..enableAutoNAT = true
    ..enableHolePunching = false
    ..enableRelay = enableRelay
    ..enableAutoRelay = enableAutoRelay
    ..enablePing = enablePing
    ..forceReachability = forceReachability
    ..ambientAutoNATConfig = ambientAutoNATConfig
    ..relayServers = relayServers ?? []
    ..disableSignedPeerRecord = false
    ..addrsFactory = passThroughAddrsFactory
    ..negotiationTimeout = Duration(seconds: 20)
    ..identifyUserAgent = "${userAgentPrefix ?? 'dart-libp2p-node'}/${peerId.toBase58().substring(0,6)}";
  
  if (listenAddrsOverride == null || listenAddrsOverride.isNotEmpty) {
     hostConfig.listenAddrs = currentListenAddrs;
  }

  final host = await BasicHost.create(
    network: network,
    config: hostConfig,
  );
  network.setHost(host);

  RecordRegistry.register<pb.PeerRecord>(
      String.fromCharCodes(PeerRecordEnvelopePayloadType),
      pb.PeerRecord.fromBuffer
  );

  await host.start();

  List<MultiAddr> actualListenAddrs = [];
  if (listenAddrsOverride == null || listenAddrsOverride.isNotEmpty) {
    try {
      await network.listen(currentListenAddrs);
      actualListenAddrs = host.addrs;
    } catch (e) {
      print('Error making host ${peerId.toBase58()} listen on $currentListenAddrs: $e');
    }
  }

  return (
    host: host,
    peerId: peerId,
    listenAddrs: actualListenAddrs,
    keyPair: kp
  );
}

void main() {
  Logger.root.level = Level.FINE;
  Logger.root.onRecord.listen((record) {
    if (record.loggerName.contains('AutoRelay') || 
        record.loggerName.contains('RelayFinder') || 
        record.loggerName.contains('BasicHost') ||
        record.loggerName.contains('RelayManager') ||
        record.loggerName.contains('ambient_autonat_v2') ||
        record.loggerName.contains('autonatv2') ||
        record.loggerName.contains('DHT')) {
      print('${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
    }
  });

  group('DHT v2 Circuit Relay Address Integration', () {
    late Libp2pNode relayNode;
    late Libp2pNode peerANode;
    late Libp2pNode peerBNode;
    late Host relayHost;
    late Host peerAHost;
    late Host peerBHost;
    late PeerId relayPeerId;
    late PeerId peerAPeerId;
    late PeerId peerBPeerId;
    late UDX udx;
    late IpfsDHTv2 relayDHT;
    late IpfsDHTv2 peerADHT;
    late IpfsDHTv2 peerBDHT;
    StreamSubscription? autoRelaySubA;
    StreamSubscription? autoRelaySubB;

    setUp(() async {
      udx = UDX();
      final resourceManager = NullResourceManager();
      final connManager = p2p_transport.ConnectionManager();

      print('\n=== Setting up DHT v2 Circuit Relay test nodes ===');

      // Create relay server with forced public reachability
      print('Creating relay server...');
      final relayEventBus = p2p_eventbus.BasicBus();
      relayNode = await createLibp2pNode(
        udxInstance: udx,
        resourceManager: resourceManager,
        connManager: connManager,
        hostEventBus: relayEventBus,
        enableRelay: true,
        enablePing: true,
        userAgentPrefix: 'relay-server',
        forceReachability: Reachability.public,
      );
      relayHost = relayNode.host;
      relayPeerId = relayNode.peerId;
      print('Relay server created: ${relayPeerId.toBase58()}');
      print('Relay addresses: ${relayHost.addrs}');
      
      await Future.delayed(Duration(milliseconds: 500));
      print('Relay service should now be active (via forceReachability)');

      // Build relay server addresses for auto-connect configuration
      final relayDirectAddrs = relayHost.addrs
          .where((addr) => !addr.toString().contains('/p2p-circuit'))
          .toList();
      
      final relayServerAddrs = relayDirectAddrs.map((addr) {
        return '${addr.toString()}/p2p/${relayPeerId.toBase58()}';
      }).toList();
      
      print('Relay server addresses for auto-connect: $relayServerAddrs');

      // Create peer A with AutoRelay and fast AutoNAT config
      print('\nCreating peer A...');
      final peerAEventBus = p2p_eventbus.BasicBus();
      final autoNATConfig = AmbientAutoNATv2Config(
        bootDelay: Duration(milliseconds: 500),
        retryInterval: Duration(seconds: 1),
        refreshInterval: Duration(seconds: 5),
      );
      peerANode = await createLibp2pNode(
        udxInstance: udx,
        resourceManager: resourceManager,
        connManager: connManager,
        hostEventBus: peerAEventBus,
        enableAutoRelay: true,
        enablePing: true,
        userAgentPrefix: 'peer-a',
        ambientAutoNATConfig: autoNATConfig,
        relayServers: relayServerAddrs,
      );
      peerAHost = peerANode.host;
      peerAPeerId = peerANode.peerId;
      print('Peer A created: ${peerAPeerId.toBase58()}');
      print('Peer A addresses: ${peerAHost.addrs}');
      print('✅ Peer A configured to auto-connect to ${relayServerAddrs.length} relay servers');

      // Create peer B with AutoRelay and fast AutoNAT config
      print('\nCreating peer B...');
      final peerBEventBus = p2p_eventbus.BasicBus();
      peerBNode = await createLibp2pNode(
        udxInstance: udx,
        resourceManager: resourceManager,
        connManager: connManager,
        hostEventBus: peerBEventBus,
        enableAutoRelay: true,
        enablePing: true,
        userAgentPrefix: 'peer-b',
        ambientAutoNATConfig: autoNATConfig,
        relayServers: relayServerAddrs,
      );
      peerBHost = peerBNode.host;
      peerBPeerId = peerBNode.peerId;
      print('Peer B created: ${peerBPeerId.toBase58()}');
      print('Peer B addresses: ${peerBHost.addrs}');
      print('✅ Peer B configured to auto-connect to ${relayServerAddrs.length} relay servers');

      print('\n=== Test: DHT v2 Circuit Relay Address Discovery ===');

      // Subscribe to AutoRelay events for debugging
      final autoRelaySubASub = peerAHost.eventBus.subscribe(EvtAutoRelayAddrsUpdated);
      autoRelaySubA = autoRelaySubASub.stream.listen((event) {
        if (event is EvtAutoRelayAddrsUpdated) {
          print('🔄 Peer A AutoRelay addresses updated (${event.advertisableAddrs.length}):');
          for (var addr in event.advertisableAddrs) {
            print('   - $addr');
            print('     Is circuit: ${addr.toString().contains('/p2p-circuit')}');
          }
        }
      });

      final autoRelaySubBSub = peerBHost.eventBus.subscribe(EvtAutoRelayAddrsUpdated);
      autoRelaySubB = autoRelaySubBSub.stream.listen((event) {
        if (event is EvtAutoRelayAddrsUpdated) {
          print('🔄 Peer B AutoRelay addresses updated (${event.advertisableAddrs.length}):');
          for (var addr in event.advertisableAddrs) {
            print('   - $addr');
            print('     Is circuit: ${addr.toString().contains('/p2p-circuit')}');
          }
        }
      });

      // Create DHT v2 instances for all three hosts
      print('\n=== Creating DHT v2 instances ===');
      
      final relayProviderStore = MemoryProviderStore();
      relayDHT = IpfsDHTv2(
        host: relayHost,
        providerStore: relayProviderStore,
        options: DHTOptions(
          mode: DHTMode.server,
          bucketSize: 20,
        ),
      );
      
      final peerAProviderStore = MemoryProviderStore();
      peerADHT = IpfsDHTv2(
        host: peerAHost,
        providerStore: peerAProviderStore,
        options: DHTOptions(
          mode: DHTMode.server,
          bucketSize: 20,
        ),
      );
      
      final peerBProviderStore = MemoryProviderStore();
      peerBDHT = IpfsDHTv2(
        host: peerBHost,
        providerStore: peerBProviderStore,
        options: DHTOptions(
          mode: DHTMode.server,
          bucketSize: 20,
        ),
      );
      
      print('✅ DHT v2 instances created for all nodes');
    });

    tearDown(() async {
      print('\n=== Tearing down test nodes ===');
      await autoRelaySubA?.cancel();
      await autoRelaySubB?.cancel();
      
      print('Closing DHTs...');
      try {
        await relayDHT.close();
        await peerADHT.close();
        await peerBDHT.close();
      } catch (e) {
        print('Error closing DHTs: $e');
      }
      
      print('Closing hosts...');
      // Hosts will be closed but commented out to prevent issues
      // await peerAHost.close();
      // await peerBHost.close();
      // await relayHost.close();

      await Future.delayed(Duration(milliseconds: 500));
      print('✅ Teardown complete');
    });

    test('DHT findPeer returns circuit relay addresses for AutoRelay peers', () async {
      // Step 1: Verify auto-connection to relay server
      print('\n📡 Step 1: Verifying auto-connection to relay server...');
      
      expect(peerAHost.network.connectedness(relayPeerId).name, equals('connected'));
      expect(peerBHost.network.connectedness(relayPeerId).name, equals('connected'));
      print('✅ Both peers automatically connected to relay server via Config.relayServers');
      
      // Step 2: Wait for AutoNAT to detect reachability and trigger AutoRelay
      print('\n🔧 Waiting for AutoNAT to detect reachability and trigger AutoRelay...');
      await Future.delayed(Duration(seconds: 2));
      print('✅ AutoNAT should have detected reachability by now');
      
      // Step 3: Wait for AutoRelay to discover relay and reserve slot
      print('\n⏳ Step 2: Waiting for AutoRelay to discover relay (bootDelay=5s + processing)...');
      await Future.delayed(Duration(seconds: 12));
      
      // Step 4: Verify peers advertise circuit addresses
      print('\n🔍 Step 3: Verifying circuit relay addresses...');
      final peerAAddrs = peerAHost.addrs;
      final peerBAddrs = peerBHost.addrs;
      
      print('Peer A addresses: $peerAAddrs');
      print('Peer B addresses: $peerBAddrs');
      
      // Check for circuit addresses containing relay peer ID
      final peerACircuitAddrs = peerAAddrs.where((addr) {
        final addrStr = addr.toString();
        return addrStr.contains('/p2p-circuit') && addrStr.contains(relayPeerId.toBase58());
      }).toList();
      
      final peerBCircuitAddrs = peerBAddrs.where((addr) {
        final addrStr = addr.toString();
        return addrStr.contains('/p2p-circuit') && addrStr.contains(relayPeerId.toBase58());
      }).toList();
      
      print('Peer A circuit addresses: $peerACircuitAddrs');
      print('Peer B circuit addresses: $peerBCircuitAddrs');
      
      expect(peerACircuitAddrs, isNotEmpty, 
        reason: 'Peer A should advertise at least one circuit relay address through relay ${relayPeerId.toBase58()}');
      expect(peerBCircuitAddrs, isNotEmpty,
        reason: 'Peer B should advertise at least one circuit relay address through relay ${relayPeerId.toBase58()}');
      
      print('✅ Both peers advertise circuit relay addresses');

      // Step 5: Start DHT instances and establish routing table connections
      print('\n🚀 Step 4: Starting DHT instances...');
      await relayDHT.start();
      await peerADHT.start();
      await peerBDHT.start();
      print('✅ All DHT instances started');
      
      // Manually add peers to each other's routing tables to simulate discovery
      print('\n🔗 Step 5: Establishing DHT routing table connections...');
      await peerADHT.updatePeerInRoutingTable(relayPeerId);
      await peerADHT.updatePeerInRoutingTable(peerBPeerId);
      await peerBDHT.updatePeerInRoutingTable(relayPeerId);
      await peerBDHT.updatePeerInRoutingTable(peerAPeerId);
      await relayDHT.updatePeerInRoutingTable(peerAPeerId);
      await relayDHT.updatePeerInRoutingTable(peerBPeerId);
      
      // Verify routing table sizes
      final peerARTSize = await peerADHT.getRoutingTableSize();
      final peerBRTSize = await peerBDHT.getRoutingTableSize();
      print('Peer A routing table size: $peerARTSize');
      print('Peer B routing table size: $peerBRTSize');
      print('✅ DHT routing tables established');

      // Step 6: Use DHT findPeer to look up peer B from peer A
      print('\n🔍 Step 6: Using DHT v2 findPeer to look up peer B from peer A...');
      final findPeerResult = await peerADHT.findPeer(peerBPeerId);
      
      print('findPeer result: $findPeerResult');
      expect(findPeerResult, isNotNull, 
        reason: 'DHT findPeer should return AddrInfo for peer B');
      
      if (findPeerResult != null) {
        print('Peer B addresses from DHT findPeer: ${findPeerResult.addrs}');
        print('Number of addresses: ${findPeerResult.addrs.length}');
        
        // Step 7: Verify circuit addresses are included
        print('\n✅ Step 7: Verifying circuit relay addresses in DHT findPeer result...');
        final circuitAddrsInResult = findPeerResult.addrs.where((addr) {
          final addrStr = addr.toString();
          return addrStr.contains('/p2p-circuit') && addrStr.contains(relayPeerId.toBase58());
        }).toList();
        
        print('Circuit addresses in DHT findPeer result: $circuitAddrsInResult');
        print('Number of circuit addresses: ${circuitAddrsInResult.length}');
        
        expect(circuitAddrsInResult, isNotEmpty,
          reason: 'DHT findPeer MUST return circuit relay addresses for peer B. '
                  'Expected addresses containing /p2p-circuit and relay peer ID ${relayPeerId.toBase58()}. '
                  'Got addresses: ${findPeerResult.addrs}');
        
        // Verify circuit addresses reference the relay peer ID
        for (final circuitAddr in circuitAddrsInResult) {
          final addrStr = circuitAddr.toString();
          expect(addrStr, contains('/p2p-circuit'),
            reason: 'Circuit address must contain /p2p-circuit protocol');
          expect(addrStr, contains(relayPeerId.toBase58()),
            reason: 'Circuit address must reference relay peer ID');
        }
        
        print('✅ Verified: DHT findPeer returns circuit relay addresses');
        print('✅ Circuit addresses contain /p2p-circuit protocol');
        print('✅ Circuit addresses reference relay peer ID');
      }
      
      print('\n✅ Test completed successfully!');
    }, timeout: Timeout(Duration(seconds: 60)));
  });
}

