import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:test/test.dart';
import 'package:dart_libp2p/core/event/addrs.dart';

import '../test_utils.dart';
import 'package:logging/logging.dart'; // Added for verbose logging

void main() {

  // Configure logging (ensure it's set up once, e.g. at the top or in a global setup)
  Logger.root.level = Level.ALL; // Set to ALL for maximum verbosity during debugging
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
    if (record.error != null) {
      print('ERROR: ${record.error}');
    }
    if (record.stackTrace != null) {
      print('STACKTRACE: ${record.stackTrace}');
    }
  });

  group('DHT Bootstrap Tests', () {
    test('SelfWalkOnAddressChange - DHT refreshes routing table on address change', () async {
      // Create three DHT instances with auto refresh disabled and explicitly in server mode
      final dhtOptions = DHTOptions(autoRefresh: false, mode: DHTMode.server);
      final d1 = await setupDHT(false, options: dhtOptions);
      final d2 = await setupDHT(false, options: dhtOptions);
      final d3 = await setupDHT(false, options: dhtOptions);

      // Connect d1 to either d2 or d3 based on XOR distance
      final connectedTo = await connectToFurthest(d1, [d2, d3]);

      // Connect d2 and d3
      await connect(d2, d3);

      // d1 should have ONLY 1 peer in its routing table
      await waitForWellFormedTables([d1], 1, 1, Duration(seconds: 2));
      var rtPeers = await d1.routingTable.listPeers();
      expect(rtPeers.map((p) => p.id).toList(), equals([connectedTo.host().id]));

      // Emit address change event
      final updates = d1.host().addrs.map((addr) => UpdatedAddress(address: addr, action: AddrAction.added)).toList();
      final event = EvtLocalAddressesUpdated(current: updates, diffs: true);
      final emitter = await d1.host().eventBus.emitter(event);
      await emitter.emit(event);
      // d1 should now have both peers in its routing table
      await waitForWellFormedTables([d1], 2, 2, Duration(seconds: 30)); // Further Increased timeout
      rtPeers = await d1.routingTable.listPeers();
      final rtPeerIds = rtPeers.map((p) => p.id).toList();
      expect(rtPeerIds.contains(d2.host().id), isTrue);
      expect(rtPeerIds.contains(d3.host().id), isTrue);

      // Cleanup
      await d1.close();
      await d2.close();
      await d3.close();
    });

    test('DefaultBootstrappers - Check default bootstrap peers', () {
      final bootstrapPeers = getDefaultBootstrapPeerAddrInfos();
      expect(bootstrapPeers, isNotEmpty);
      expect(bootstrapPeers.length, equals(defaultBootstrapPeers.length));

      // Create a map of default bootstrap peers
      final peerMap = <PeerId, AddrInfo>{};
      for (final addr in defaultBootstrapPeers) {
        final info = AddrInfo.fromMultiaddr(addr);
        peerMap[info.id] = info;
      }

      // Verify all bootstrap peers are in the map
      for (final peer in bootstrapPeers) {
        expect(peerMap.containsKey(peer.id), isTrue);
        expect(peer.addrs, equals(peerMap[peer.id]!.addrs));
      }
    });

    test('BootstrappersReplacable - Peers in routing table can be replaced', () async {
      // Set a short RT freeze timeout for testing
      final rtFreezeTimeout = Duration(milliseconds: 100);

      // Create a DHT with small bucket size
      final d = await setupDHT(false, options: DHTOptions(bucketSize: 2));

      // Create two DHTs with CPL of 0 to d
      final d1 = await setupDHTWithCPL(d, 0);
      final d2 = await setupDHTWithCPL(d, 0);

      // Connect d to d1 and d2, marking them as replaceable
      await connect(d, d1, isReplaceable: true);
      await connect(d, d2, isReplaceable: true);

      final peerList = await d.routingTable.listPeers();
      // d should have 2 peers in its routing table
      expect(peerList.length, equals(2));

      // Create two more DHTs with CPL of 0 to d
      final d3 = await setupDHTWithCPL(d, 0);
      final d4 = await setupDHTWithCPL(d, 0);

      // Connect d to d3 and d4 (these will be non-replaceable by default)
      await connect(d, d3);
      await connect(d, d4);

      // Wait for the routing table to update
      await Future.delayed(rtFreezeTimeout * 2);

      // d should still have 2 peers, but they should be d3 and d4
      final peerInfoList = await d.routingTable.listPeers();
      expect(peerInfoList.length, equals(2));
      final peerIdsInTable = peerInfoList.map((pInfo) => pInfo.id).toList();
      expect(peerIdsInTable.contains(d3.host().id), isTrue, reason: "d3 should be in the table after replacements");
      expect(peerIdsInTable.contains(d4.host().id), isTrue, reason: "d4 should be in the table after replacements");

      // Cleanup
      await d.close();
      await d1.close();
      await d2.close();
      await d3.close();
      await d4.close();
    });

    test('quickConnectOnly bootstrap with explicit peers populates routing table', () async {
      final log = Logger('QuickConnectExplicitBootstrapTest');

      // 1. Create Node B (Bootstrap Peer)
      final nodeB = await setupDHT(false, options: DHTOptions(mode: DHTMode.server, autoRefresh: false));
      log.info('Node B (${nodeB.host().id.toBase58().substring(0,6)}) created.');
      // Construct full multiaddresses for Node B
      final List<MultiAddr> fullMultiAddrsNodeB = [];
      final peerIdNodeBStr = nodeB.host().id.toBase58();
      for (final addr in nodeB.host().addrs) {
        try {
          fullMultiAddrsNodeB.add(addr.encapsulate('p2p', peerIdNodeBStr));
        } catch (e) {
          log.warning("Failed to encapsulate address $addr for Node B: $e");
        }
      }
      expect(fullMultiAddrsNodeB, isNotEmpty, reason: "Node B should have constructable full multiaddresses.");
      log.info('Node B Full MultiAddrs: ${fullMultiAddrsNodeB.map((m) => m.toString()).join(', ')}');

      // 2. Create Node A (Test Target) manually to precisely control its bootstrap sequence.
      final hostA = await createMockHost(); // From test_utils.dart, creates a MockHost
      final providerStoreA = MemoryProviderStore();
      final dhtOptionsA = DHTOptions(
        mode: DHTMode.server, 
        autoRefresh: false,
        bootstrapPeers: fullMultiAddrsNodeB, // Use Node B's full multiaddresses
      );
      final nodeA = IpfsDHT(host: hostA, providerStore: providerStoreA, options: dhtOptionsA);
      await nodeA.start(); // Start Node A's DHT services
      log.info('Node A (${nodeA.host().id.toBase58().substring(0,6)}) created and started. Configured with Node B as an explicit bootstrap peer in its options.');

      // Verify Node A's routing table is empty before the targeted bootstrap call.
      // Since nodeA was created manually and only start() was called, no bootstrap has occurred yet.
      var rtPeersBeforeBootstrap = await nodeA.routingTable.listPeers();
      log.info('Node A RT before explicit bootstrap: ${rtPeersBeforeBootstrap.map((p)=>p.id.toBase58().substring(0,6)).join(",")} (Size: ${rtPeersBeforeBootstrap.length})');
      expect(rtPeersBeforeBootstrap, isEmpty, reason: "Node A's routing table should be empty before its explicit bootstrap call.");

      // 3. Call bootstrap on Node A with quickConnectOnly: true
      //    This call will use the bootstrapPeers configured in dhtOptionsA.
      log.info('Calling nodeA.bootstrap(quickConnectOnly: true)...');
      await nodeA.bootstrap(quickConnectOnly: true);
      log.info('nodeA.bootstrap(quickConnectOnly: true) completed.');

      // 4. Inspect Node A's Routing Table
      final rtPeersNodeA = await nodeA.routingTable.listPeers();
      final rtPeerIdsNodeA = rtPeersNodeA.map((p) => p.id).toList();
      log.info('Node A routing table after quickConnectOnly bootstrap: ${rtPeerIdsNodeA.map((id) => id.toBase58().substring(0,6)).join(', ')} (Size: ${rtPeersNodeA.length})');

      // 5. Assertions
      expect(rtPeersNodeA, isNotEmpty, reason: "Node A's routing table should not be empty after quickConnectOnly bootstrap with an explicit, live peer.");
      expect(rtPeerIdsNodeA.contains(nodeB.host().id), isTrue, reason: "Node A's routing table should contain Node B's PeerId.");
      
      // With one explicit bootstrap peer (Node B) and quickConnectOnly: true,
      // and a clean initial state for Node A's RT, we expect Node A's RT to contain only Node B.
      // The MockHost environment is controlled, so side effects are minimal.
      expect(rtPeersNodeA.length, equals(1), reason: "Node A's routing table should contain exactly one peer (Node B).");
      expect(rtPeerIdsNodeA.first, equals(nodeB.host().id), reason: "The only peer in Node A's routing table should be Node B.");

      // Further verification: try to find Node B in the table.
      final foundNodeBInTable = await nodeA.routingTable.find(nodeB.host().id);
      expect(foundNodeBInTable, isNotNull, reason: "Node B should be findable in Node A's routing table using routingTable.find().");
      expect(foundNodeBInTable, equals(nodeB.host().id), reason: "The peer ID found by routingTable.find() should match Node B's ID.");

      log.info('Test assertions passed for quickConnectOnly bootstrap with explicit peers.');

      // Cleanup
      await nodeA.close();
      await nodeB.close();
      log.info('Nodes closed.');
    });

    test('quickConnectOnly bootstrap populates routing table with bootstrap peer', () async {
      final log = Logger('QuickConnectBootstrapTest');
      // 1. Node B (Bootstrap Peer) - this will be our "live" bootstrap peer
      final nodeB = await setupDHT(false, options: DHTOptions(mode: DHTMode.server, autoRefresh: false));
      log.info('Node B (${nodeB.host().id.toBase58().substring(0,6)}) created. RT size: ${await nodeB.routingTable.size()}');
      // Construct full multiaddresses for Node B
      final List<MultiAddr> fullMultiAddrsNodeBForOpts = [];
      final peerIdNodeBStrForOpts = nodeB.host().id.toBase58();
       for (final addr in nodeB.host().addrs) {
        try {
          fullMultiAddrsNodeBForOpts.add(addr.encapsulate('p2p', peerIdNodeBStrForOpts));
        } catch (e) {
          log.warning("Failed to encapsulate address $addr for Node B (for opts): $e");
        }
      }
      expect(fullMultiAddrsNodeBForOpts, isNotEmpty, reason: "Node B should have constructable full multiaddresses for DHTOptions.");


      // 2. Node A (Test Target) - its RT should be initially empty or near empty
      //    Pass Node B's full multiaddresses as bootstrapPeers in DHTOptions for Node A.
      final nodeAOptions = DHTOptions(
        mode: DHTMode.server, 
        autoRefresh: false, 
        bootstrapPeers: fullMultiAddrsNodeBForOpts // Configure Node B as bootstrap peer for Node A
      );
      final nodeA = await setupDHT(false, options: nodeAOptions);
      log.info('Node A (${nodeA.host().id.toBase58().substring(0,6)}) created with Node B as bootstrap peer. Initial RT size: ${await nodeA.routingTable.size()}');
      
      // Since setupDHT calls bootstrap internally, Node A might already have Node B.
      // For this test, we want to ensure our *specific* call to bootstrap(quickConnectOnly: true) works.
      // To get a cleaner state for *this specific call*, we could clear Node A's RT,
      // but that might be too invasive. Let's proceed and verify the presence of Node B.
      // The key is that the *next* bootstrap call uses quickConnectOnly.

      // 3. Bootstrap Node A with quickConnectOnly: true.
      //    It will use the bootstrapPeers (Node B's multiAddrs) configured in its DHTOptions.
      log.info('Calling nodeA.bootstrap(quickConnectOnly: true)...');
      await nodeA.bootstrap(quickConnectOnly: true); // No bootstrapPeers parameter here
      log.info('Bootstrap call completed.');

      // 5. Inspect Node A's Routing Table
      final rtPeersNodeA = await nodeA.routingTable.listPeers();
      final rtPeerIdsNodeA = rtPeersNodeA.map((p) => p.id).toList();
      log.info('Node A routing table after quickConnectOnly bootstrap: ${rtPeerIdsNodeA.map((id) => id.toBase58().substring(0,6)).join(', ')} (Size: ${rtPeersNodeA.length})');

      // 6. Assertions
      expect(rtPeersNodeA, isNotEmpty, reason: "Node A's routing table should not be empty after quickConnectOnly bootstrap with a live peer.");
      expect(rtPeerIdsNodeA.contains(nodeB.host().id), isTrue, reason: "Node A's routing table should contain Node B's PeerId.");
      // Depending on the exact behavior of quickConnectOnly and mock environment,
      // we might expect the size to be exactly 1 if no other peers were discovered.
      // If setupDHT's initial bootstrap could have added other (unreachable) default peers, this might be > 1.
      // The critical part is that Node B *is* present.
      expect(rtPeersNodeA.length, greaterThanOrEqualTo(1), reason: "Node A's routing table should contain at least Node B.");


      // Check if Node B is actually in the table by trying to find it.
      final foundNodeBInTable = await nodeA.routingTable.find(nodeB.host().id);
      expect(foundNodeBInTable, isNotNull, reason: "Node B should be findable in Node A's routing table.");
      expect(foundNodeBInTable, equals(nodeB.host().id), reason: "The found peer ID should match Node B's ID.");


      log.info('Test assertions passed.');

      // Cleanup
      await nodeA.close();
      await nodeB.close();
      log.info('Nodes closed.');
    });
  });
}
