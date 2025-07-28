import 'dart:async';

import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:dart_libp2p_kad_dht/src/dht/dht.dart';
import 'package:dart_libp2p_kad_dht/src/providers/provider_store.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import '../real_net_stack.dart';
import '../test_utils.dart';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_mgr;
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;

// Helper class to encapsulate node and DHT creation for tests using real_net_stack
class _NodeWithDHT {
  late Libp2pNode nodeDetails;
  late IpfsDHT dht;
  late Host host;
  late PeerId peerId;
  late UDX _udxInstance;

  static Future<_NodeWithDHT> create() async {
    final helper = _NodeWithDHT();

    helper._udxInstance = UDX();
    final resourceManager = NullResourceManager(); 
    final connManager = p2p_conn_mgr.ConnectionManager();
    final eventBus = p2p_event_bus.BasicBus();

    helper.nodeDetails = await createLibp2pNode(
      udxInstance: helper._udxInstance,
      resourceManager: resourceManager,
      connManager: connManager,
      hostEventBus: eventBus,
    );
    helper.host = helper.nodeDetails.host;
    helper.peerId = helper.nodeDetails.peerId;

    final providerStore = MemoryProviderStore();
    helper.dht = IpfsDHT(
      host: helper.host,
      providerStore: providerStore,
      options: const DHTOptions(mode: DHTMode.server),
    );
    return helper;
  }

  Future<void> stop() async {
    await dht.close();
    await host.close();
  }
}

void main() {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
    if (record.error != null) {
      print('ERROR: ${record.error}');
    }
    if (record.stackTrace != null) {
      print('STACKTRACE: ${record.stackTrace}');
    }
  });

  group('IpfsDHT Eviction Tests', () {
    test('Peer is evicted from routing table after failed query', () async {
      final nodeHelper1 = await _NodeWithDHT.create();
      final dht1 = nodeHelper1.dht;
      await dht1.start();

      final nodeHelper2 = await _NodeWithDHT.create();
      final dht2 = nodeHelper2.dht;
      await dht2.start();

      // Connect nodes and ensure they are in each other's routing tables
      await nodeHelper1.host.connect(AddrInfo(nodeHelper2.peerId, nodeHelper2.host.addrs));
      await dht1.routingTable.tryAddPeer(nodeHelper2.peerId, queryPeer: true);
      await dht2.routingTable.tryAddPeer(nodeHelper1.peerId, queryPeer: true);

      await waitUntil(() async {
        final p1 = await dht1.routingTable.find(nodeHelper2.peerId);
        final p2 = await dht2.routingTable.find(nodeHelper1.peerId);
        return p1 != null && p2 != null;
      }, timeout: Duration(seconds: 10), interval: Duration(seconds: 1));

      // Stop node 2 to make it unreachable
      await nodeHelper2.stop();

      // Query the unreachable peer
      await dht1.findPeer(nodeHelper2.peerId);

      // Wait for the peer to be evicted
      await waitUntil(() async {
        final p = await dht1.routingTable.find(nodeHelper2.peerId);
        return p == null;
      }, timeout: Duration(seconds: 10), interval: Duration(seconds: 1));

      await nodeHelper1.stop();
    }, timeout: Timeout(Duration(seconds: 30)));
  });
}
