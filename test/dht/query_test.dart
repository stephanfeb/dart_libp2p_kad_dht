import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

import 'package:logging/logging.dart';

final _logger = Logger('QueryTest');

void main() async {
  // --- Setup Phase (Illustrative - replace with your actual libp2p setup) ---
  // 1. Initialize Logger (optional)
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.loggerName}: ${record
        .message}');
    if (record.error != null) print(
        'ERROR: ${record.error}, ${record.stackTrace}');
  });

  group('DHT Query Tests', () {
    test('RTEvictionOnFailedQuery - Peers are removed from routing table after failed queries', () async {
      final d1 = await setupDHT(false);
      final d2 = await setupDHT(false);
      
      // Connect and disconnect multiple times to ensure peer is in routing table
      for (var i = 0; i < 10; i++) {
        await connect(d1, d2);
        for (final conn in d1.host().network.connsToPeer(d2.host().id)) {
          await conn.close();
        }
      }
      
      // Peers should be in the RT because of fixLowPeers
      await waitUntil(() async => await checkRoutingTable(d1, d2), timeout: Duration(seconds: 5));
      
      // Make hosts unreachable to each other so query fails
      (d1.host() as MockHost).unregister();
      (d2.host() as MockHost).unregister();
      
      // Peers will still be in the RT because membership is decoupled from connectivity
      await waitUntil(() async => await checkRoutingTable(d1, d2), timeout: Duration(seconds: 5));
      
      // Failed queries should remove the peers from the RT
      try {
        await d1.findPeer(d2.host().id);
      } catch (_) {}
      
      try {
        await d2.findPeer(d1.host().id);
      } catch (_) {}
      
      // Wait for the routing table to update
      await waitUntil(() async => !await checkRoutingTable(d1, d2), timeout: Duration(seconds: 5));
      
      // Cleanup
      await d1.close();
      await d2.close();
    });
    
    test('RTAdditionOnSuccessfulQuery - Peers are added to routing table after successful queries', () async {
      // Create DHT options that disable localhost filtering for testing
      final testOptions = DHTOptions(
        mode: DHTMode.server,
        filterLocalhostInResponses: false, // Disable localhost filtering for tests
      );

      final d1 = await setupDHT(false, options: testOptions);
      final d2 = await setupDHT(false, options: testOptions);
      final d3 = await setupDHT(false, options: testOptions);
      
      // Connect d1->d2->d3
      await connect(d1, d2);
      await connect(d2, d3);
      
      // d1 has d2
      await waitUntil(() async => await checkRoutingTable(d1, d2), timeout: Duration(seconds: 5));
      
      // d2 has d3
      await waitUntil(() async => await checkRoutingTable(d2, d3), timeout: Duration(seconds: 5));
      
      // d1 does not know about d3
      await waitUntil(() async => !await checkRoutingTable(d1, d3), timeout: Duration(seconds: 5));
      
      // Print initial routing table states
      print('=== INITIAL STATE ===');
      print('d1 routing table size: ${await d1.routingTable.size()}');
      print('d2 routing table size: ${await d2.routingTable.size()}');
      print('d3 routing table size: ${await d3.routingTable.size()}');
      
      // Generate a random peer ID and log it
      final randomPeerId = await PeerId.random();
      print('=== STARTING QUERY ===');
      print('d3 is querying for random peer: ${randomPeerId.toBase58().substring(0, 6)}');
      
      // When d3 queries, d1 and d3 discover each other
      try {
        final result = await d3.findPeer(randomPeerId);
        print('=== QUERY COMPLETED ===');
        print('findPeer result: ${result?.id.toBase58().substring(0, 6) ?? 'null'}');
      } catch (e) {
        print('=== QUERY FAILED ===');
        print('findPeer error: $e');
      }
      
      // Print final routing table states
      print('=== FINAL STATE ===');
      print('d1 routing table size: ${await d1.routingTable.size()}');
      print('d2 routing table size: ${await d2.routingTable.size()}');
      print('d3 routing table size: ${await d3.routingTable.size()}');
      
      // Check if d1 has d3 and d3 has d1
      final d1HasD3 = await d1.routingTable.find(d3.host().id) != null;
      final d3HasD1 = await d3.routingTable.find(d1.host().id) != null;
      print('d1 has d3: $d1HasD3');
      print('d3 has d1: $d3HasD1');
      
      // d1 and d3 should now know about each other
      await waitUntil(() async => await checkRoutingTable(d1, d3), timeout: Duration(seconds: 5));
      
      // Cleanup
      await d1.close();
      await d2.close();
      await d3.close();
    });
  });
}

Future<bool> checkRoutingTable(IpfsDHT a, IpfsDHT b) async {
  // Use last 6 characters instead of first 6 to get more unique identifiers
  final aId = a.host().id.toBase58();
  final bId = b.host().id.toBase58();
  final aShort = aId.substring(aId.length - 6);
  final bShort = bId.substring(bId.length - 6);
  
  final aHasB = await a.routingTable.find(b.host().id) != null;
  final bHasA = await b.routingTable.find(a.host().id) != null;
  
  print('[checkRoutingTable] $aShort has $bShort: $aHasB, $bShort has $aShort: $bHasA');
  
  // Add more detailed debugging
  if (!aHasB || !bHasA) {
    print('[checkRoutingTable] DETAILED: A($aShort) looking for B($bShort): ${aHasB ? "FOUND" : "NOT FOUND"}');
    print('[checkRoutingTable] DETAILED: B($bShort) looking for A($aShort): ${bHasA ? "FOUND" : "NOT FOUND"}');
    print('[checkRoutingTable] DETAILED: A full ID: $aId');
    print('[checkRoutingTable] DETAILED: B full ID: $bId');
  }
  
  return aHasB && bHasA;
}
