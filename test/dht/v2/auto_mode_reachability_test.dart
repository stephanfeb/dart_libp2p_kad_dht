import 'package:dart_libp2p/core/event/reachability.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/network.dart' show Reachability;
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_mgr;
import 'package:dart_libp2p_kad_dht/src/amino/defaults.dart';
import 'package:dart_libp2p_kad_dht/src/dht/dht_options.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/dht_v2.dart';
import 'package:dart_libp2p_kad_dht/src/providers/provider_store.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:test/test.dart';

import 'real_net_stack.dart';

/// In auto mode the DHT serves only while the host's reachability is
/// public (go-libp2p-kad-dht ModeAuto); in autoServer mode it stops serving
/// only while reachability is private.
void main() {
  group('DHT v2 auto mode follows reachability', () {
    final hosts = <Host>[];
    final dhts = <IpfsDHTv2>[];

    tearDown(() async {
      for (final dht in dhts) {
        await dht.close().timeout(const Duration(seconds: 5)).catchError((_) {});
      }
      for (final host in hosts) {
        await host.close().timeout(const Duration(seconds: 5)).catchError((_) {});
      }
      hosts.clear();
      dhts.clear();
    });

    Future<IpfsDHTv2> node(DHTMode mode, List<MultiAddr> bootstrapPeers) async {
      final details = await createLibp2pNode(
        udxInstance: UDX(),
        resourceManager: NullResourceManager(),
        connManager: p2p_conn_mgr.ConnectionManager(),
        hostEventBus: p2p_event_bus.BasicBus(),
        userAgentPrefix: 'dht-auto-mode-test',
      );
      hosts.add(details.host);
      final dht = IpfsDHTv2(
        host: details.host,
        providerStore: MemoryProviderStore(),
        options: DHTOptions(
          mode: mode,
          bootstrapPeers: bootstrapPeers,
          autoRefresh: false,
        ),
      );
      dhts.add(dht);
      await dht.start();
      return dht;
    }

    MultiAddr addrOf(Host host) {
      final udx = host.addrs.firstWhere((a) => a.hasProtocol('udx'));
      return MultiAddr('$udx/p2p/${host.id.toBase58()}');
    }

    Future<void> emit(Host host, Reachability reachability) async {
      final emitter = await host.eventBus.emitter(EvtLocalReachabilityChanged);
      await emitter.emit(EvtLocalReachabilityChanged(reachability: reachability));
      await emitter.close();
    }

    Future<void> waitFor(Future<bool> Function() condition, String what) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!await condition()) {
        if (DateTime.now().isAfter(deadline)) fail('timed out waiting for: $what');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    test('auto: client until public, server while public, client again on private', () async {
      final server = await node(DHTMode.server, []);
      final serverHost = hosts[0];
      final auto = await node(DHTMode.auto, [addrOf(serverHost)]);
      final autoHost = hosts[1];
      await auto.bootstrap();

      Future<bool> serverSeesKad() async => (await serverHost.peerStore.protoBook
              .supportsProtocols(autoHost.id, [AminoConstants.protocolID]))
          .isNotEmpty;
      Future<bool> inServerTable() async =>
          (await server.routingTable.listPeers()).any((p) => p.id == autoHost.id);

      expect(auto.isServer, isFalse, reason: 'auto mode starts as a client');
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(await serverSeesKad(), isFalse);
      expect(await inServerTable(), isFalse);

      await emit(autoHost, Reachability.public);
      await waitFor(() async => auto.isServer, 'auto node to serve');
      // Identify pushes the new protocol list; the server adds the peer.
      await waitFor(serverSeesKad, 'server to learn the auto node speaks kad');
      await waitFor(inServerTable, 'auto node in the server routing table');

      await emit(autoHost, Reachability.private);
      await waitFor(() async => !auto.isServer, 'auto node to stop serving');
      await waitFor(() async => !await serverSeesKad(), 'server to learn kad was removed');
      await waitFor(() async => !await inServerTable(), 'auto node out of the server table');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('auto: unknown reachability means client', () async {
      final auto = await node(DHTMode.auto, []);
      final host = hosts[0];
      await emit(host, Reachability.public);
      await waitFor(() async => auto.isServer, 'serve on public');
      await emit(host, Reachability.unknown);
      await waitFor(() async => !auto.isServer, 'client on unknown');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('autoServer: server unless private', () async {
      final dht = await node(DHTMode.autoServer, []);
      final host = hosts[0];
      expect(dht.isServer, isTrue);
      await emit(host, Reachability.private);
      await waitFor(() async => !dht.isServer, 'client on private');
      await emit(host, Reachability.unknown);
      await waitFor(() async => dht.isServer, 'server on unknown');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('server and client modes ignore reachability', () async {
      final server = await node(DHTMode.server, []);
      final client = await node(DHTMode.client, []);
      await emit(hosts[0], Reachability.private);
      await emit(hosts[1], Reachability.public);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(server.isServer, isTrue);
      expect(client.isServer, isFalse);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('close stops following reachability', () async {
      final auto = await node(DHTMode.auto, []);
      final host = hosts[0];
      await auto.close();
      await emit(host, Reachability.public);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(auto.isServer, isFalse);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
