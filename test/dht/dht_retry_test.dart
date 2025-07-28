import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/network/common.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart'; // Contains PeerInfo
import 'package:dart_libp2p/core/peerstore.dart'; // Added for Peerstore
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/routing/options.dart';
import 'package:dart_libp2p/core/event/bus.dart'; // Added for EventBus (even if just for type)
import 'package:dart_libp2p/p2p/discovery/peer_info.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:dart_libp2p_kad_dht/src/amino/defaults.dart';
import 'package:dart_libp2p_kad_dht/src/dht/dht.dart';
import 'package:dart_libp2p_kad_dht/src/pb/dht_message.dart' as dht_pb_msg;
import 'package:dart_libp2p_kad_dht/src/pb/record.dart' as dht_pb_rec;
import 'package:dart_libp2p_kad_dht/src/providers/provider_store.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';

import 'dht_retry_test.mocks.dart';

            // Mock classes
            @GenerateMocks([Host, P2PStream, ProviderStore, Peerstore, EventBus, Subscription]) // Added EventBus
            void main() {
              Logger.root.level = Level.ALL; // Adjust log level for tests to see all logs
              Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
    if (record.error != null) {
      print('ERROR: ${record.error}');
    }
    if (record.stackTrace != null) {
      print('STACKTRACE: ${record.stackTrace}');
    }
  });

  late MockHost mockHostA;
  late PeerId hostBId;
  late MockProviderStore mockProviderStore;
  late MockPeerstore mockPeerstoreHostA;
  late MockEventBus mockEventBus;
  late MockSubscription mockSubscription;
  late IpfsDHT dhtA;

  setUp(() async { // Added async back
    mockHostA = MockHost();
    hostBId = await PeerId.random(); // Added await
    mockProviderStore = MockProviderStore();
    mockPeerstoreHostA = MockPeerstore();
    mockEventBus = MockEventBus(); // Initialize MockEventBus
    mockSubscription = MockSubscription();

    when(mockSubscription.stream).thenAnswer((_) => StreamController.broadcast().stream); // Corrected for Stream
    // Setup Host A
    final hostAId = await PeerId.random(); // Pre-calculate PeerId
    when(mockHostA.id).thenReturn(hostAId); // Use the concrete PeerId
    when(mockHostA.peerStore).thenReturn(mockPeerstoreHostA);
    when(mockHostA.eventBus).thenReturn(mockEventBus); // Use MockEventBus
    when(mockEventBus.subscribe(any)).thenAnswer((_) => mockSubscription); // Basic mock for subscribe
    
    // Default connect behavior (can be overridden per test)
    when(mockHostA.connect(any)).thenAnswer((_) async => {}); 
  });

  tearDown(() async {
    try {
      await dhtA.close();
    } catch (e) {
      // Catch LateInitializationError if dhtA was not initialized,
      // or any other error during close.
      print('Error in tearDown while closing dhtA: $e');
    }
  });

  group('DHT Message Retry Logic', () {
    test('Successful retry after initial connection error', () async {
      final targetPeerId = hostBId; // Use the top-level ID
      final targetKey = '/v/testKey'; // Use /v/ namespace for GenericValidator
      final targetValue = Uint8List.fromList(utf8.encode('testValue'));

      // Configure DHT A with retry options
      dhtA = IpfsDHT(
        host: mockHostA,
        providerStore: mockProviderStore,
        options: DHTOptions(
          maxRetryAttempts: 3,
          retryInitialBackoff: Duration(milliseconds: 10), // Short backoff for tests
        ),
      );
      await dhtA.start();

      // --- Pre-configure the stream for the successful (second) attempt ---
       final successStream = MockP2PStream<Uint8List>(); // Specify type argument
       when(successStream.id()).thenReturn('mockStreamId-2'); // For the expected second attempt
       // Adjusting stubs for getters that return functions
       // when(successStream.protocol).thenReturn(() => AminoConstants.protocolID); // Commenting out to isolate
       // when(successStream.stat).thenReturn(() => StreamStats(direction: Direction.outbound, opened: DateTime.now())); // Commenting out as well
       when(successStream.write(any)).thenAnswer((_) async => {});
      
      final dht_pb_rec.Record responseRecord = dht_pb_rec.Record(
        key: Uint8List.fromList(utf8.encode(targetKey)),
        value: targetValue,
        author: targetPeerId.toBytes(),
        timeReceived: DateTime.now().millisecondsSinceEpoch,
        signature: Uint8List(0),
      );
      final dht_pb_msg.Message responseMessage = dht_pb_msg.Message(
        type: dht_pb_msg.MessageType.getValue,
        key: Uint8List.fromList(utf8.encode(targetKey)),
        record: responseRecord,
      );
      final responseBytes = utf8.encode(jsonEncode(responseMessage.toJson()));
      when(successStream.read()).thenAnswer((_) => Future.value(responseBytes));
      when(successStream.close()).thenAnswer((_) async => {});

      // --- Configure mockHostA.newStream to use a counter ---
      int newStreamAttemptCounter = 0;
      when(mockHostA.newStream(targetPeerId, any, any)).thenAnswer((_) async {
        newStreamAttemptCounter++;
        if (newStreamAttemptCounter == 1) {
          print('Test: mockHostA.newStream - Attempt 1: Simulating "Connection is closed"');
          throw Exception('Connection is closed');
        } else if (newStreamAttemptCounter == 2) {
          print('Test: mockHostA.newStream - Attempt 2: Returning pre-configured successStream');
          return successStream;
        } else {
          // Should not happen in this test if maxRetryAttempts for DHT is 3 and first retry succeeds
          print('Test: mockHostA.newStream - Attempt $newStreamAttemptCounter: Unexpected call');
          throw StateError('mockHostA.newStream called too many times ($newStreamAttemptCounter)');
        }
      });

      // Mock peerstore for dialPeer to find the target AND for adding to routing table
      final addrInfoB = AddrInfo(targetPeerId, [MultiAddr('/ip4/127.0.0.1/tcp/10001')]);
      // Use the mockPeerstoreHostA instance for when()
      when(mockPeerstoreHostA.getPeer(targetPeerId)).thenAnswer((_) async => PeerInfo(peerId: targetPeerId, addrs: addrInfoB.addrs.toSet()));

      // Add targetPeerId to routing table so a query attempt is made
      await dhtA.routingTable.tryAddPeer(targetPeerId, queryPeer: true);
      print('Test 1: Added $targetPeerId to routing table. Size: ${await dhtA.routingTable.size()}');


      // Removed: when(dhtA.findLocalPeer(targetPeerId)).thenAnswer((_) async => null); 
      // This was a mock on the object under test, which is generally not recommended.
      // The goal is for checkLocalDatastore to return null, which might be the default
      // or requires mocking the actual datastore if IpfsDHT was configured with one.
      // Since it's configured with mockProviderStore, checkLocalDatastore's behavior
      // depends on how DatastoreAdapter(mockProviderStore) implements .get().
      // We are hoping it effectively results in 'not found' for this test's purpose.
      // The test should rely on the natural flow or mock dependencies of findLocalPeer if needed.

      final result = await dhtA.getValue(targetKey, RoutingOptions());

      expect(result, equals(targetValue));
      // expect(newStreamAttempt, equals(2), reason: 'Expected newStream to be called twice (1 fail, 1 success)'); // Replaced by verify below
      verify(mockHostA.newStream(targetPeerId, argThat(isA<List<String>>()), argThat(anything))).called(2);
      
      verify(mockHostA.connect(argThat(predicate<AddrInfo>((info) => info.id == targetPeerId)))).called(greaterThanOrEqualTo(1));
    });

    test('Retry exhaustion leads to MaxRetriesExceededException', () async {
      final targetPeerId = hostBId;
      final targetKey = 'testKeyRetryExhaust';
      const maxRetries = 2;

      dhtA = IpfsDHT(
        host: mockHostA,
        providerStore: mockProviderStore,
        options: DHTOptions(
          maxRetryAttempts: maxRetries,
          retryInitialBackoff: Duration(milliseconds: 5), // Short backoff
        ),
      );
      await dhtA.start();

      // Ensure targetPeerId is in the routing table so a query attempt is made
      // This requires targetPeerId to have known addresses in the peerstore.
      // Note: The getPeer mock for targetPeerId might be overridden by the later one specific to this test's AddrInfo.
      // This is okay as long as one of them provides addresses for tryAddPeer.
      final addrInfoForTable = AddrInfo(targetPeerId, [MultiAddr('/ip4/127.0.0.1/tcp/9999')]); // Dummy addr for RT
      when(mockPeerstoreHostA.getPeer(targetPeerId)).thenAnswer((_) async => PeerInfo(peerId: targetPeerId, addrs: addrInfoForTable.addrs.toSet()));
      await dhtA.routingTable.tryAddPeer(targetPeerId, queryPeer: true);

      int newStreamAttempt = 0;
      when(mockHostA.newStream(targetPeerId, any, any)).thenAnswer((_) async {
        newStreamAttempt++;
        print('Test: Simulating "Connection reset by peer" on newStream attempt $newStreamAttempt');
        throw Exception('Connection reset by peer'); // Always fails
      });

      // Mock peerstore for dialPeer
      final addrInfoB = AddrInfo(targetPeerId, [MultiAddr('/ip4/127.0.0.1/tcp/10002')]);
      when(mockPeerstoreHostA.getPeer(targetPeerId)).thenAnswer((_) async => PeerInfo(peerId: targetPeerId, addrs: addrInfoB.addrs.toSet()));
      when(mockHostA.connect(any)).thenAnswer((_) async => {});

      // Removed: when(dhtA.findLocalPeer(targetPeerId)).thenAnswer((_) async => null);
      // See comment in the test above regarding checkLocalDatastore.

      try {
        await dhtA.getValue(targetKey, RoutingOptions());
        fail('Expected MaxRetriesExceededException to be thrown');
      } catch (e) {
        expect(e, isA<MaxRetriesExceededException>());
        if (e is MaxRetriesExceededException) {
          // Match the actual message format from _sendMessage
          // Note: _sendMessage uses the short peer ID in its log, but the exception message uses the full one.
          // The message.type is MessageType.getValue.
          expect(e.message, contains('Failed to send MessageType.getValue to ${targetPeerId.toBase58()} after $maxRetries attempts'));
          expect(e.lastError.toString(), contains('Connection reset by peer'));
        }
      }

      expect(newStreamAttempt, equals(maxRetries), reason: 'Expected newStream to be called $maxRetries times');
      verify(mockHostA.connect(argThat(predicate<AddrInfo>((info) => info.id == targetPeerId)))).called(maxRetries);
    });
  });
}

// MockPeerstore is now generated by build_runner, so this manual class is not needed.
// We will use the generated MockPeerstore.
// The setup for mockPeerstoreHostA.getPeer is done within the test case.
