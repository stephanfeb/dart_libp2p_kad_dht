import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_mgr;
import 'package:dart_libp2p_kad_dht/src/dht/dht_options.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/dht_v2.dart';
import 'package:dart_libp2p_kad_dht/src/providers/provider_store.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:test/test.dart';

import 'real_net_stack.dart';

/// A client-mode DHT peer has no /ipfs/kad/1.0.0 handler, so it cannot
/// answer queries. A server must not put it in its routing table, or it
/// hands the client out as a closer peer and queries it itself.
void main() {
  group('Routing table admits only DHT servers', () {
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
        userAgentPrefix: 'dht-rt-server-only-test',
      );
      hosts.add(details.host);
      final dht = IpfsDHTv2(
        host: details.host,
        providerStore: MemoryProviderStore(),
        options: DHTOptions(
          mode: mode,
          bootstrapPeers: bootstrapPeers,
          autoRefresh: false,
          bucketSize: 20,
          concurrency: 3,
          resiliency: 3,
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

    test('a client that queries a server stays out of its table; a server gets in', () async {
      final server = await node(DHTMode.server, []);
      final serverAddr = addrOf(hosts[0]);

      final client = await node(DHTMode.client, [serverAddr]);
      final clientId = hosts[1].id;
      await client.bootstrap();

      final otherServer = await node(DHTMode.server, [serverAddr]);
      final otherServerId = hosts[2].id;
      await otherServer.bootstrap();

      // Both send the server requests: lookups for their own IDs.
      await client.findPeer(clientId).catchError((_) => null);
      await otherServer.findPeer(otherServerId).catchError((_) => null);
      // Routing-table insertion for inbound requests is deferred.
      await Future<void>.delayed(const Duration(seconds: 2));

      final table = await server.routingTable.listPeers();
      final ids = table.map((p) => p.id).toSet();
      expect(ids, isNot(contains(clientId)),
          reason: 'a client-mode peer must not enter a routing table');
      expect(ids, contains(otherServerId),
          reason: 'a server-mode peer that queried us should enter the table');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
