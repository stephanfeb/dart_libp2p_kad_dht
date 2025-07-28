import 'package:collection/collection.dart';
import 'package:dart_libp2p/dart_libp2p.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
// Import the custom Message class used by IpfsDHT
import 'package:dart_libp2p_kad_dht/src/pb/dht_message.dart' as custom_dht_msg; 
import 'package:dart_libp2p_kad_dht/src/kbucket/bucket/bucket.dart';
// Keep dht_pb for Message_MessageType enum if still needed, or use custom_dht_msg.MessageType
import 'package:dart_libp2p_kad_dht/src/pb/dht.pb.dart' as dht_pb; 
import 'package:test/test.dart';
import 'package:logging/logging.dart';
import 'dart:convert'; // Added for jsonDecode and jsonEncode

import '../test_utils.dart'; // Assuming test_utils.dart contains MockHost, createPeerId, etc.

void main() {
  group('DHT findPeer Address Handling', () {
    late PeerId querierId;
    late PeerId bootstrapId;
    late PeerId targetId;

    late Host querierHost; // Use Host type, will be MockHost instance
    late IpfsDHT querierDht;

    late MockHost bootstrapHostInternal; // Keep as MockHost for direct handler setting
    // We won't initialize a full DHT for bootstrapHost, just mock its responses.

    setUp(() async {
      Logger.root.level = Level.ALL; // Adjust as needed for debugging
      Logger.root.onRecord.listen((record) {
        print('${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
        if (record.error != null) print('  ERROR: ${record.error}');
        if (record.stackTrace != null) print('  STACKTRACE: ${record.stackTrace}');
      });

      // Use createHost from test_utils.dart
      querierHost = await createMockHost();
      querierId = querierHost.id;

      // For bootstrap and target, we primarily need their PeerIds.
      // bootstrapHostInternal will be a MockHost to set handlers on.
      bootstrapHostInternal = await createMockHost() as MockHost;
      bootstrapId = bootstrapHostInternal.id;
      
      targetId = await PeerId.random();


      // Setup Querier
      // For bootstrapPeers in DHTOptions, we need full multiaddrs including the /p2p/ part.
      final bootstrapPeerMultiaddrs = bootstrapHostInternal.addrs.map((ma) {
        return ma.encapsulate('p2p', bootstrapId.toBase58());
      }).toList();

      querierDht = IpfsDHT(
        host: querierHost,
        options: DHTOptions(
          bootstrapPeers: bootstrapPeerMultiaddrs,
          mode: DHTMode.server, 
        ),
        providerStore: MemoryProviderStore(),
      );
      await querierDht.start();

      // Add bootstrapHost to querierHost's peerstore so it can be "dialed"
      // createHost already registers hosts in a static map, so direct dialing should work if IDs match.
      // Explicitly adding to peerstore is also good practice.
      await querierHost.peerStore.addrBook.addAddrs(bootstrapId, bootstrapHostInternal.addrs, Duration(hours: 1));
    });

    tearDown(() async {
      await querierDht.close();
      await querierHost.close();
      await bootstrapHostInternal.close();
    });

    test('findPeer returns no addresses when bootstrap provides target with empty addresses', () async {
      // Mock the bootstrap node's response to FIND_NODE
      bootstrapHostInternal.setStreamHandler('/ipfs/kad/1.0.0', (P2PStream stream, PeerId remotePeerId) async {
        expect(remotePeerId, equals(querierId)); // Ensure querier is calling

        final requestBytes = await stream.read();
        // IpfsDHT sends messages as JSON strings, then UTF8 encodes them.
        final requestJsonString = utf8.decode(requestBytes);
        final requestJson = jsonDecode(requestJsonString); // Decode string to Map
        // Use the custom Message class's fromJson
        final requestMsg = custom_dht_msg.Message.fromJson(requestJson as Map<String, dynamic>);

        expect(requestMsg.type, equals(custom_dht_msg.MessageType.findNode));
        expect(requestMsg.key, equals(targetId.toBytes())); // Use toBytes()

        // Construct the response using the custom Message class
        final responseMsg = custom_dht_msg.Message(
          type: custom_dht_msg.MessageType.findNode,
          closerPeers: [
            custom_dht_msg.Peer(
              id: targetId.toBytes(), // Uint8List
              addrs: [], // Empty list of Uint8List
            ),
          ],
        );
        
        // IpfsDHT expects responses in the same JSON format (from custom Message.toJson)
        final responseJsonMap = responseMsg.toJson();
        final responseJsonString = jsonEncode(responseJsonMap);
        await stream.write(utf8.encode(responseJsonString));
        await stream.close();
      });

      // Action: Querier tries to find the target
      AddrInfo? foundAddrInfo;
      try {
        foundAddrInfo = await querierDht.findPeer(targetId);
      } catch (e) {
        // Depending on implementation, it might throw if no peers are found after exhausting options.
        // For this specific test, we expect it to complete but find no useful info.
        print('findPeer threw an error: $e');
      }
      
      // Verification
      // The exact behavior might be:
      // 1. foundAddrInfo is null (if findPeer returns null when no useful info is found)
      // 2. foundAddrInfo is non-null, but foundAddrInfo.addrs is empty.
      // Let's check for the latter as it's a common way to represent a known peer with unknown addresses.
      // If the library is designed to return null, this test will need adjustment.
      
      expect(foundAddrInfo, isNotNull, reason: 'findPeer should complete, even if no addresses are found.');
      if (foundAddrInfo != null) {
        expect(foundAddrInfo.id, equals(targetId), reason: 'The PeerID in AddrInfo should match the target.');
        expect(foundAddrInfo.addrs, isEmpty, reason: 'Expected no addresses for the target peer.');
      }
      
      // Additionally, check that the target peer is NOT in the querier's routing table
      // with any addresses, or if it is, it has no addresses.
      final rtPeerInfos = await querierDht.routingTable.listPeers(); // Returns List<PeerInfo>
      DhtPeerInfo? targetInRoutingTable;
      try {
        targetInRoutingTable = rtPeerInfos.firstWhereOrNull((pInfo) => pInfo.id == targetId);
      } on StateError { // firstWhere throws StateError if no element is found and orElse is not provided.
        targetInRoutingTable = null;
      }
      
      if (targetInRoutingTable != null) {
        // If the peer is in the routing table, check its addresses in the peerstore.
        // The DhtPeerInfo itself doesn't store MultiAddrs.
        // peerStore.getPeer() returns PeerInfo?, not AddrInfo?
        final PeerInfo? peerFromStore = await querierHost.peerStore.getPeer(targetInRoutingTable.id);
        expect(peerFromStore?.addrs ?? [], isEmpty, reason: "If target is in RT, its addresses in Peerstore should be empty after this interaction.");
      } else {
        // It's also acceptable if the peer isn't added to the RT at all if no addresses were found.
        print('Target peer ${targetId.toBase58().substring(0,6)} was not added to the routing table of querier ${querierId.toBase58().substring(0,6)}, which is acceptable.');
      }
    }, timeout: Timeout(Duration(seconds: 15))); // Increased timeout for DHT operations
  });
}
