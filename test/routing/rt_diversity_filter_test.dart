import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:dart_libp2p_kad_dht/src/kbucket/bucket/bucket.dart'; // Keep if PeerInfo from bucket is used elsewhere, or remove
// Use specific imports to manage potential name clashes if user fixed duplicates.
// Assuming PeerGroupInfo from routing/rt_diversity_filter.dart is the one to use.
import 'package:dart_libp2p_kad_dht/src/routing/rt_diversity_filter.dart';
// Keep kbucket filter if the other tests need the generic Filter
import 'package:dart_libp2p_kad_dht/src/kbucket/peerdiversity/filter.dart' ;
import 'package:dart_libp2p_kad_dht/src/kbucket/keyspace/keyspace.dart' ;
import 'package:dart_libp2p_kad_dht/src/kbucket/keyspace/kad_id.dart' ;

import 'package:test/test.dart';

import '../test_utils.dart';

// Adapter might still be needed if generic Filter is used by RoutingTable and RtPeerIPGroupFilter.allow is async
// For now, the first test will directly test RtPeerIPGroupFilter.
// If kbucket.PeerIPGroupFilter.allow is indeed sync, this adapter needs a proper solution for async call.
/*
class AdapterPeerIPGroupFilter implements KBucketPeerIPGroupFilter {
  final RtPeerIPGroupFilter actualFilter;

  AdapterPeerIPGroupFilter(this.actualFilter);

  @override
  bool allow(kbucket_filter_PeerGroupInfo info) { // Assuming kbucket_filter_PeerGroupInfo is the type from kbucket
    final rtInfo = PeerGroupInfo(id: info.id, cpl: info.cpl, ipGroupKey: info.ipGroupKey);
    // HACK: This is problematic due to sync/async mismatch.
    // This needs a proper solution if kbucket.Filter expects sync `allow`.
    Future<bool> asyncResult = actualFilter.allow(rtInfo); 
    // This is not a robust way to bridge async to sync.
    // For testing, one might need to refactor the test or the interface.
    // Let's assume for now the test structure will be changed or this won't be used directly.
    return true; // Placeholder, real bridging is complex
  }

  @override
  void increment(kbucket_filter_PeerGroupInfo info) {
    final rtInfo = PeerGroupInfo(id: info.id, cpl: info.cpl, ipGroupKey: info.ipGroupKey);
    actualFilter.increment(rtInfo);
  }

  @override
  void decrement(kbucket_filter_PeerGroupInfo info) {
    final rtInfo = PeerGroupInfo(id: info.id, cpl: info.cpl, ipGroupKey: info.ipGroupKey);
    actualFilter.decrement(rtInfo);
  }
  
  @override
  List<MultiAddr> peerAddresses(PeerId peerId) {
    return actualFilter.peerAddresses(peerId);
  }
}
*/

void main() {
  group('RT Diversity Filter Tests', () {
    test('RtPeerIPGroupFilter logic - Limits peers per CPL and per prefix', () async {
      final host = await createMockHost();
      final dummyPeerId = await PeerId.random(); 

      // Test RtPeerIPGroupFilter directly
      final pgm = RtPeerIPGroupFilter(host: host, maxPerCpl: 2, maxForTable: 3);
      
      // Table should only have 2 for each prefix per CPL
      final key = 'key';
      
      // Use PeerGroupInfo from src/routing/rt_diversity_filter.dart
      expect(await pgm.allow(PeerGroupInfo(id: dummyPeerId, cpl: 1, ipGroupKey: key)), isTrue);
      await pgm.increment(PeerGroupInfo(id: dummyPeerId, cpl: 1, ipGroupKey: key));
      
      expect(await pgm.allow(PeerGroupInfo(id: dummyPeerId, cpl: 1, ipGroupKey: key)), isTrue);
      await pgm.increment(PeerGroupInfo(id: dummyPeerId, cpl: 1, ipGroupKey: key));
      
      // Now cplIpGroupCount[1][key] should be 2. maxPerCpl is 2. So next should be false.
      expect(await pgm.allow(PeerGroupInfo(id: dummyPeerId, cpl: 1, ipGroupKey: key)), isFalse);
      
      // Table should ONLY have 3 for a Prefix (ipGroupKey) across all CPLs
      final key2 = 'random';
      var g2Info = PeerGroupInfo(id: dummyPeerId, cpl: 2, ipGroupKey: key2);
      
      expect(await pgm.allow(g2Info), isTrue); // tableIpGroupCount[key2] = 0, cplIpGroupCount[2][key2] = 0. OK.
      await pgm.increment(g2Info);          // tableIpGroupCount[key2] = 1, cplIpGroupCount[2][key2] = 1.
      
      // Use a different peer ID for the next increments to simulate different peers in the same group
      final dummyPeerId2 = await PeerId.random();
      g2Info = PeerGroupInfo(id: dummyPeerId2, cpl: 3, ipGroupKey: key2); 
      expect(await pgm.allow(g2Info), isTrue); // tableIpGroupCount[key2] = 1, cplIpGroupCount[3][key2] = 0. OK.
      await pgm.increment(g2Info);          // tableIpGroupCount[key2] = 2, cplIpGroupCount[3][key2] = 1.

      final dummyPeerId3 = await PeerId.random();
      g2Info = PeerGroupInfo(id: dummyPeerId3, cpl: 4, ipGroupKey: key2); 
      expect(await pgm.allow(g2Info), isTrue); // tableIpGroupCount[key2] = 2, cplIpGroupCount[4][key2] = 0. OK.
      await pgm.increment(g2Info);          // tableIpGroupCount[key2] = 3, cplIpGroupCount[4][key2] = 1.
      
      // Now tableIpGroupCount[key2] is 3. maxForTable is 3. Next should be false.
      final dummyPeerId4 = await PeerId.random();
      g2Info = PeerGroupInfo(id: dummyPeerId4, cpl: 5, ipGroupKey: key2);
      expect(await pgm.allow(g2Info), isFalse); 
      
      // Remove one peer from the group key2
      // Decrement needs one of the specific PeerGroupInfo objects that was incremented.
      await pgm.decrement(PeerGroupInfo(id: dummyPeerId3, cpl: 4, ipGroupKey: key2)); // tableIpGroupCount[key2] becomes 2
      
      // Now adding dummyPeerId4 should be allowed
      expect(await pgm.allow(PeerGroupInfo(id: dummyPeerId4, cpl: 5, ipGroupKey: key2)), isTrue);
      await pgm.increment(PeerGroupInfo(id: dummyPeerId4, cpl: 5, ipGroupKey: key2)); // tableIpGroupCount[key2] becomes 3
      
      // And then it doesn't work again for a new peer in the same group
      final dummyPeerId5 = await PeerId.random();
      expect(await pgm.allow(PeerGroupInfo(id: dummyPeerId5, cpl: 6, ipGroupKey: key2)), isFalse);
    });
    
    test('RoutingTableEndToEndMaxPerCpl - Limits peers per CPL', () async {
      final host = await createMockHost();
      final filterInstance = RtPeerIPGroupFilter(host: host, maxPerCpl: 1, maxForTable: 2);
      
      final d = await createDHT(host, [
        'testPrefix',
        'disableAutoRefresh',
        'modeServer',
        'rtPeerDiversityFilter', // This string tells createDHT to use a diversity filter
        filterInstance          // This is the filter instance
      ]);
      
      // Create two DHTs with CPL of 1 to d
      final d2 = await setupDHTWithCPL(d, 1);
      final d3 = await setupDHTWithCPL(d, 1);
      
      // d2 will be allowed in the Routing table but d3 will not be
      await connect(d, d2);
      await waitUntil(() => d.routingTable.find(d2.host().id) != null);
      
      await connect(d, d3);
      await Future.delayed(Duration(seconds: 1));
      expect((await d.routingTable.listPeers()).length, equals(1));
      expect(d.routingTable.find(d3.host().id), isNull);
      
      // It works after removing d2
      d.routingTable.removePeer(d2.host().id);
      final added = await d.routingTable.tryAddPeer(d3.host().id, queryPeer: true, isReplaceable: false);
      expect(added, isTrue);
      expect((await d.routingTable.listPeers()).length, equals(1));
      expect(d.routingTable.find(d3.host().id), isNotNull);
      
      // Cleanup
      await d.close();
      await d2.close();
      await d3.close();
    });

    test('RoutingTableEndToEndMaxPerTable - Limits peers per table', () async {
      final host = await createMockHost();
      final filterInstance = RtPeerIPGroupFilter(host: host, maxPerCpl: 100, maxForTable: 3);
      
      final d = await createDHT(host, [
        'testPrefix',
        'disableAutoRefresh',
        'modeServer',
        'rtPeerDiversityFilter',
        filterInstance
      ]);
      
      // Create 4 DHTs with the same prefix
      final peers = <IpfsDHT>[];
      for (var i = 0; i < 4; i++) {
        final peer = await setupDHT(false);
        peers.add(peer);
        
        // Set the same address prefix for all peers
        final addr = MultiAddr('/ip4/192.168.0.1/tcp/${2000 + i}');
        peer.host().peerStore.addrBook.addAddrs(peer.host().id, [addr], Duration(hours: 1));
      }
      
      // Connect to the first 3 peers
      for (var i = 0; i < 3; i++) {
        await connect(d, peers[i]);
      }
      
      // Wait for the routing table to update
      await waitUntil(() async => (await d.routingTable.listPeers()).length == 3);
      
      // Connect to the 4th peer
      await connect(d, peers[3]);
      
      // The 4th peer should not be added because we've reached the limit for the prefix
      await Future.delayed(Duration(seconds: 1));
      expect((await d.routingTable.listPeers()).length, equals(3));
      expect(d.routingTable.find(peers[3].host().id), isNull);
      
      // Cleanup
      await d.close();
      for (final peer in peers) {
        await peer.close();
      }
    });
  });
}
