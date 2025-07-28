import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:dart_libp2p_kad_dht/src/record/record_signer.dart';
import 'package:dart_multihash/dart_multihash.dart';
import 'package:test/test.dart';
import 'package:dcid/dcid.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/peerstore.dart';
import 'package:dart_libp2p/p2p/discovery/peer_info.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/managers/protocol_manager.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/managers/routing_manager.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/managers/metrics_manager.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/config/dht_config.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/errors/dht_errors.dart';
import 'package:dart_libp2p_kad_dht/src/pb/dht_message.dart';
import 'package:dart_libp2p_kad_dht/src/pb/record.dart';
import 'package:dart_libp2p_kad_dht/src/providers/provider_store.dart';
import 'package:dart_libp2p_kad_dht/src/amino/defaults.dart';

/// Mock implementation of P2PStream for testing
class MockP2PStream implements P2PStream {
  final List<Uint8List> _receivedData = [];
  final List<Uint8List> _dataToReturn = [];
  bool _closed = false;
  final PeerId _remotePeer;
  
  MockP2PStream(this._remotePeer);
  
  void addDataToReturn(Uint8List data) {
    _dataToReturn.add(data);
  }
  
  List<Uint8List> get receivedData => _receivedData;
  
  @override
  Future<void> close() async {
    _closed = true;
  }
  
  @override
  Future<Uint8List> read([int? maxBytes]) async {
    if (_closed) throw StateError('Stream is closed');
    if (_dataToReturn.isEmpty) throw StateError('No data to return');
    return _dataToReturn.removeAt(0);
  }
  
  @override
  Future<void> write(Uint8List data) async {
    if (_closed) throw StateError('Stream is closed');
    _receivedData.add(data);
  }
  
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Mock implementation of PeerStore for testing
class MockPeerStore implements Peerstore {
  final Map<PeerId, PeerInfo> _peers = {};
  
  @override
  Future<void> addOrUpdatePeer(PeerId peerId, {Iterable<MultiAddr>? addrs, Iterable<String>? protocols, Map<String, dynamic>? metadata}) async {
    _peers[peerId] = PeerInfo(
      peerId: peerId,
      addrs: addrs?.toSet() ?? <MultiAddr>{},
      protocols: protocols?.toSet() ?? <String>{},
      metadata: metadata ?? {},
    );
  }
  
  @override
  Future<PeerInfo?> getPeer(PeerId peerId) async {
    return _peers[peerId];
  }
  
  @override
  Future<List<PeerInfo>> getAllPeers() async {
    return _peers.values.toList();
  }
  
  @override
  Future<void> removePeer(PeerId peerId) async {
    _peers.remove(peerId);
  }
  
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Mock implementation of Host for testing
class MockHost implements Host {
  final PeerId _id;
  final MockPeerStore _peerStore;
  final Map<String, Function> _streamHandlers = {};
  final List<MockP2PStream> _incomingStreams = [];
  
  MockHost(this._id) : _peerStore = MockPeerStore();
  
  @override
  PeerId get id => _id;
  
  @override
  Peerstore get peerStore => _peerStore;
  
  @override
  Future<void> setStreamHandler(String protocol, Function handler) async {
    _streamHandlers[protocol] = handler;
  }
  
  void simulateIncomingStream(MockP2PStream stream) {
    _incomingStreams.add(stream);
    final handler = _streamHandlers[AminoConstants.protocolID];
    if (handler != null) {
      handler(stream, stream._remotePeer);
    }
  }
  
  @override
  Future<P2PStream> newStream(PeerId peerId, List<String> protocols, Context context) async {
    return MockP2PStream(peerId);
  }
  
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Mock implementation of RoutingManager for testing
class MockRoutingManager implements RoutingManager {
  final Map<PeerId, bool> _peers = {};
  final List<PeerId> _nearestPeers = [];
  
  void addMockPeer(PeerId peerId) {
    _peers[peerId] = true;
  }
  
  void setNearestPeers(List<PeerId> peers) {
    _nearestPeers.clear();
    _nearestPeers.addAll(peers);
  }
  
  @override
  Future<bool> addPeer(PeerId peerId, {bool queryPeer = false, bool isReplaceable = false}) async {
    _peers[peerId] = true;
    return true;
  }
  
  @override
  Future<List<PeerId>> getNearestPeers(Uint8List keyBytes, int count) async {
    return _nearestPeers.take(count).toList();
  }
  
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Mock implementation of MetricsManager for testing
class MockMetricsManager implements MetricsManager {
  final List<String> _recordedMetrics = [];
  
  List<String> get recordedMetrics => _recordedMetrics;
  
  @override
  void recordQuerySuccess(Duration latency) {
    _recordedMetrics.add('query_success:$latency');
  }
  
  @override
  void recordQueryFailure(String errorType, {PeerId? peer}) {
    _recordedMetrics.add('query_failure:$errorType:${peer?.toBase58() ?? 'unknown'}');
  }
  
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Mock implementation of ProviderStore for testing
class MockProviderStore implements ProviderStore {
  final Map<CID, List<AddrInfo>> _providers = {};
  
  void addMockProvider(CID cid, AddrInfo provider) {
    _providers.putIfAbsent(cid, () => []).add(provider);
  }
  
  @override
  Future<List<AddrInfo>> getProviders(CID cid) async {
    return _providers[cid] ?? [];
  }
  
  @override
  Future<void> addProvider(CID cid, AddrInfo provider) async {
    _providers.putIfAbsent(cid, () => []).add(provider);
  }
  
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('ProtocolManager Tests', () {
    late ProtocolManager protocolManager;
    late MockHost mockHost;
    late MockRoutingManager mockRoutingManager;
    late MockMetricsManager mockMetricsManager;
    late MockProviderStore mockProviderStore;
    late PeerId localPeerId;
    late PeerId remotePeerId;
    late DHTConfigV2 config;
    
    setUp(() async {
      // Create test peer IDs
      localPeerId = await PeerId.random();
      remotePeerId = await PeerId.random();
      
      // Create mock dependencies
      mockHost = MockHost(localPeerId);
      mockRoutingManager = MockRoutingManager();
      mockMetricsManager = MockMetricsManager();
      mockProviderStore = MockProviderStore();
      
      // Create test configuration
      config = DHTConfigV2(
        bucketSize: 20,
        concurrency: 3,
        resiliency: 3,
        queryTimeout: Duration(seconds: 30),
        maxConcurrentQueries: 10,
        refreshInterval: Duration(minutes: 10),
        bootstrapPeers: [],
        enableMetrics: true,
        metricsInterval: Duration(minutes: 5),
      );
      
      // Create protocol manager
      protocolManager = ProtocolManager(mockHost);
    });
    
    tearDown(() async {
      await protocolManager.close();
    });
    
    group('Initialization and Lifecycle', () {
      test('should initialize with default state', () {
        expect(protocolManager.toString(), contains('ProtocolManager'));
      });
      
      test('should initialize and start successfully', () async {
        protocolManager.initialize(
          config: config,
          metrics: mockMetricsManager,
          routing: mockRoutingManager,
          providerStore: mockProviderStore,
        );
        
        await protocolManager.start();
        
        // Verify protocol handler was registered
        expect(mockHost._streamHandlers.containsKey(AminoConstants.protocolID), isTrue);
      });
      
      test('should close successfully', () async {
        protocolManager.initialize(
          config: config,
          metrics: mockMetricsManager,
          routing: mockRoutingManager,
          providerStore: mockProviderStore,
        );
        
        await protocolManager.start();
        await protocolManager.close();
        
        // Should not throw when closed
        expect(() => protocolManager.close(), returnsNormally);
      });
      
      test('should throw DHTNotStartedException when not started', () async {
        expect(
          () => protocolManager.handlePing(remotePeerId, Message(type: MessageType.ping)),
          throwsA(isA<DHTNotStartedException>()),
        );
      });
      
      test('should throw DHTClosedException when closed', () async {
        protocolManager.initialize(
          config: config,
          metrics: mockMetricsManager,
          routing: mockRoutingManager,
          providerStore: mockProviderStore,
        );
        
        await protocolManager.start();
        await protocolManager.close();
        
        expect(
          () => protocolManager.handlePing(remotePeerId, Message(type: MessageType.ping)),
          throwsA(isA<DHTClosedException>()),
        );
      });
    });
    
    group('Message Handling', () {
      setUp(() async {
        protocolManager.initialize(
          config: config,
          metrics: mockMetricsManager,
          routing: mockRoutingManager,
          providerStore: mockProviderStore,
        );
        await protocolManager.start();
      });
      
      test('should handle incoming stream with valid message', () async {
        final stream = MockP2PStream(remotePeerId);
        final message = Message(type: MessageType.ping);
        final messageJson = jsonEncode(message.toJson());
        final messageBytes = utf8.encode(messageJson);
        
        stream.addDataToReturn(messageBytes);
        
        // Simulate incoming stream
        mockHost.simulateIncomingStream(stream);
        
        // Allow async processing
        await Future.delayed(Duration(milliseconds: 10));
        
        // Verify response was sent
        expect(stream.receivedData, isNotEmpty);
        
        // Verify stream was closed
        expect(stream._closed, isTrue);
      });
      
      test('should handle stream with invalid JSON', () async {
        final stream = MockP2PStream(remotePeerId);
        final invalidJson = utf8.encode('invalid json');
        
        stream.addDataToReturn(invalidJson);
        
        // Simulate incoming stream
        mockHost.simulateIncomingStream(stream);
        
        // Allow async processing
        await Future.delayed(Duration(milliseconds: 10));
        
        // Verify stream was closed even with error
        expect(stream._closed, isTrue);
      });
    });
    
    group('Protocol Handlers', () {
      setUp(() async {
        protocolManager.initialize(
          config: config,
          metrics: mockMetricsManager,
          routing: mockRoutingManager,
          providerStore: mockProviderStore,
        );
        await protocolManager.start();
      });
      
      test('should handle PING message', () async {
        final message = Message(type: MessageType.ping);
        
        final response = await protocolManager.handlePing(remotePeerId, message);
        
        expect(response.type, equals(MessageType.ping));
      });
      
      test('should handle FIND_NODE message', () async {
        final keyBytes = Uint8List.fromList([1, 2, 3, 4]);
        final message = Message(
          type: MessageType.findNode,
          key: keyBytes,
        );
        
        // Set up mock nearest peers
        final nearestPeers = [remotePeerId];
        mockRoutingManager.setNearestPeers(nearestPeers);
        
        final response = await protocolManager.handleFindNode(remotePeerId, message);
        
        expect(response.type, equals(MessageType.findNode));
        expect(response.key, equals(keyBytes));
        expect(response.closerPeers, hasLength(1));
        expect(response.closerPeers.first.id, equals(remotePeerId.toBytes()));
      });
      
      test('should handle FIND_NODE message without key', () async {
        final message = Message(type: MessageType.findNode);
        
        expect(
          () => protocolManager.handleFindNode(remotePeerId, message),
          throwsA(isA<DHTProtocolException>()),
        );
      });
      
      test('should handle GET_VALUE message with existing record', () async {

        final keyPair = await generateEd25519KeyPair();
        final privateKey = keyPair.privateKey;
        final peerId = PeerId.fromPublicKey(keyPair.publicKey);

        final keyBytes = Uint8List.fromList([1, 2, 3, 4]);
        final keyString = utf8.decode(keyBytes);
        final record = await RecordSigner.createSignedRecord(
            key: 'this-is-a-key',
            value: Uint8List.fromList([5, 6, 7, 8]),
            privateKey: privateKey,
            peerId: peerId);

        // Store record in datastore
        await protocolManager.putRecordToDatastore(keyString, record);
        
        final message = Message(
          type: MessageType.getValue,
          key: keyBytes,
        );
        
        final response = await protocolManager.handleGetValue(remotePeerId, message);
        
        expect(response.type, equals(MessageType.getValue));
        expect(response.key, equals(keyBytes));
        expect(response.record, isNotNull);
        expect(response.record!.value, equals(record.value));
        expect(response.closerPeers, isNotNull);
      });
      
      test('should handle GET_VALUE message without existing record', () async {
        final keyBytes = Uint8List.fromList([1, 2, 3, 4]);
        final message = Message(
          type: MessageType.getValue,
          key: keyBytes,
        );
        
        // Set up mock nearest peers
        final nearestPeers = [remotePeerId];
        mockRoutingManager.setNearestPeers(nearestPeers);
        
        final response = await protocolManager.handleGetValue(remotePeerId, message);
        
        expect(response.type, equals(MessageType.getValue));
        expect(response.key, equals(keyBytes));
        expect(response.record, isNull);
        expect(response.closerPeers, hasLength(1));
      });
      
      test('should handle GET_VALUE message without key', () async {
        final message = Message(type: MessageType.getValue);
        
        expect(
          () => protocolManager.handleGetValue(remotePeerId, message),
          throwsA(isA<DHTProtocolException>()),
        );
      });
      
      test('should handle GET_PROVIDERS message', () async {

        final digest = sha256.convert("random-bit-of-text".codeUnits);
        final mh = Multihash.encode('sha2-256', Uint8List.fromList(digest.bytes));
        final cid = CID.create(CID.V1, 'sha2-256', mh.toBytes());

        final keyBytes = cid.toBytes();
        final provider = AddrInfo(
          remotePeerId,
          [MultiAddr('/ip4/127.0.0.1/tcp/4001')],
        );
        
        // Add mock provider
        mockProviderStore.addMockProvider(cid, provider);
        
        final message = Message(
          type: MessageType.getProviders,
          key: keyBytes,
        );
        
        final response = await protocolManager.handleGetProviders(remotePeerId, message);
        
        expect(response.type, equals(MessageType.getProviders));
        expect(response.key, equals(keyBytes));
        expect(response.providerPeers, hasLength(1));
        expect(response.providerPeers.first.id, equals(remotePeerId.toBytes()));
      });
      
      test('should handle GET_PROVIDERS message without key', () async {
        final message = Message(type: MessageType.getProviders);
        
        expect(
          () => protocolManager.handleGetProviders(remotePeerId, message),
          throwsA(isA<DHTProtocolException>()),
        );
      });
      
      test('should handle ADD_PROVIDER message', () async {
        final peerId = await PeerId.random();
        final cid = CID.create(CID.V1, 'sha2-256', peerId.toBytes());
        final keyBytes = cid.toBytes();
        final provider = Peer(
          id: remotePeerId.toBytes(),
          addrs: [MultiAddr('/ip4/127.0.0.1/tcp/4001').toBytes()],
          connection: ConnectionType.connected,
        );
        
        final message = Message(
          type: MessageType.addProvider,
          key: keyBytes,
          providerPeers: [provider],
        );
        
        final response = await protocolManager.handleAddProvider(remotePeerId, message);
        
        expect(response.type, equals(MessageType.addProvider));
        expect(response.key, equals(keyBytes));
      });
      
      test('should handle ADD_PROVIDER message without key', () async {
        final provider = Peer(
          id: remotePeerId.toBytes(),
          addrs: [MultiAddr('/ip4/127.0.0.1/tcp/4001').toBytes()],
          connection: ConnectionType.connected,
        );
        
        final message = Message(
          type: MessageType.addProvider,
          providerPeers: [provider],
        );
        
        expect(
          () => protocolManager.handleAddProvider(remotePeerId, message),
          throwsA(isA<DHTProtocolException>()),
        );
      });
      
      test('should handle ADD_PROVIDER message without providers', () async {
        final keyBytes = Uint8List.fromList([1, 2, 3, 4]);
        final message = Message(
          type: MessageType.addProvider,
          key: keyBytes,
        );
        
        expect(
          () => protocolManager.handleAddProvider(remotePeerId, message),
          throwsA(isA<DHTProtocolException>()),
        );
      });
    });
    
    group('Datastore Operations', () {
      setUp(() async {
        protocolManager.initialize(
          config: config,
          metrics: mockMetricsManager,
          routing: mockRoutingManager,
          providerStore: mockProviderStore,
        );
        await protocolManager.start();
      });
      
      test('should store and retrieve record', () async {
        final keyPair = await generateEd25519KeyPair();
        final privateKey = keyPair.privateKey;
        final peerId = PeerId.fromPublicKey(keyPair.publicKey);

        final keyBytes = Uint8List.fromList([1, 2, 3, 4]);
        final keyString = utf8.decode(keyBytes);
        final record = await RecordSigner.createSignedRecord(
            key: 'test-key',
            value: Uint8List.fromList([5, 6, 7, 8]),
            privateKey: privateKey,
            peerId: peerId);

        await protocolManager.putRecordToDatastore(keyString, record);
        
        final retrievedRecord = await protocolManager.getRecordFromDatastore(keyString);
        
        expect(retrievedRecord, isNotNull);
        expect(retrievedRecord!.value, equals(record.value));
        expect(retrievedRecord.timeReceived, equals(record.timeReceived));
      });
      
      test('should retrieve record using byte key', () async {
        final keyPair = await generateEd25519KeyPair();
        final privateKey = keyPair.privateKey;
        final peerId = PeerId.fromPublicKey(keyPair.publicKey);

        final keyBytes = Uint8List.fromList([1, 2, 3, 4]);
        final keyString = utf8.decode(keyBytes);
        final record = await RecordSigner.createSignedRecord(
            key: 'test-key',
            value: Uint8List.fromList([5, 6, 7, 8]),
            privateKey: privateKey,
            peerId: peerId);

        await protocolManager.putRecordToDatastore(keyString, record);
        
        final retrievedRecord = await protocolManager.getRecordFromDatastoreBytes(keyBytes);
        
        expect(retrievedRecord, isNotNull);
        expect(retrievedRecord!.value, equals(record.value));
      });
      
      test('should return null for non-existent record', () async {
        final retrievedRecord = await protocolManager.getRecordFromDatastore('non-existent');
        
        expect(retrievedRecord, isNull);
      });
      
      test('should check if record exists', () async {
        final keyPair = await generateEd25519KeyPair();
        final privateKey = keyPair.privateKey;
        final peerId = PeerId.fromPublicKey(keyPair.publicKey);

        final keyBytes = Uint8List.fromList([1, 2, 3, 4]);
        final keyString = utf8.decode(keyBytes);
        final record = await RecordSigner.createSignedRecord(
            key: 'this-is-a-key',
            value: Uint8List.fromList([5, 6, 7, 8]),
            privateKey: privateKey,
            peerId: peerId);

        expect(await protocolManager.hasRecordInDatastore(keyString), isFalse);
        
        await protocolManager.putRecordToDatastore(keyString, record);
        
        expect(await protocolManager.hasRecordInDatastore(keyString), isTrue);
      });
      
      test('should remove record from datastore', () async {
        final keyPair = await generateEd25519KeyPair();
        final privateKey = keyPair.privateKey;
        final peerId = PeerId.fromPublicKey(keyPair.publicKey);

        final keyBytes = Uint8List.fromList([1, 2, 3, 4]);
        final keyString = utf8.decode(keyBytes);
        final record = await RecordSigner.createSignedRecord(
            key: 'this-is-a-key',
            value: Uint8List.fromList([5, 6, 7, 8]),
            privateKey: privateKey,
            peerId: peerId);


        await protocolManager.putRecordToDatastore(keyString, record);
        expect(await protocolManager.hasRecordInDatastore(keyString), isTrue);
        
        await protocolManager.removeRecordFromDatastore(keyString);
        expect(await protocolManager.hasRecordInDatastore(keyString), isFalse);
      });
      
      test('should handle removing non-existent record', () async {
        // Should not throw
        await protocolManager.removeRecordFromDatastore('non-existent');
      });
      
      test('should get all keys from datastore', () async {
        final keys = ['key1', 'key2', 'key3'];
        final keyPair = await generateEd25519KeyPair();
        final privateKey = keyPair.privateKey;
        final peerId = PeerId.fromPublicKey(keyPair.publicKey);

        for (final key in keys) {
          final record = await RecordSigner.createSignedRecord(
              key: key,
              value: Uint8List.fromList([5, 6, 7, 8]),
              privateKey: privateKey,
              peerId: peerId);

          await protocolManager.putRecordToDatastore(key, record);
        }
        
        final datastoreKeys = <String>[];
        await for (final key in protocolManager.getKeysFromDatastore()) {
          datastoreKeys.add(key);
        }
        
        expect(datastoreKeys, hasLength(3));
        expect(datastoreKeys, containsAll(keys));
      });
      
      test('should get datastore size', () async {
        expect(await protocolManager.getDatastoreSize(), equals(0));
        
        final keyPair = await generateEd25519KeyPair();
        final privateKey = keyPair.privateKey;
        final peerId = PeerId.fromPublicKey(keyPair.publicKey);

        final keyBytes = Uint8List.fromList([1, 2, 3, 4]);
        final keyString = utf8.decode(keyBytes);
        final record = await RecordSigner.createSignedRecord(
            key: 'this-is-a-key',
            value: Uint8List.fromList([5, 6, 7, 8]),
            privateKey: privateKey,
            peerId: peerId);

        await protocolManager.putRecordToDatastore('test-key', record);
        
        expect(await protocolManager.getDatastoreSize(), equals(1));
      });
      
      test('should clear datastore', () async {

        final keyPair = await generateEd25519KeyPair();
        final privateKey = keyPair.privateKey;
        final peerId = PeerId.fromPublicKey(keyPair.publicKey);

        final record = await RecordSigner.createSignedRecord(
            key: 'test-key',
            value: Uint8List.fromList([5, 6, 7, 8]),
            privateKey: privateKey,
            peerId: peerId);

        await protocolManager.putRecordToDatastore('test-key', record);
        
        expect(await protocolManager.getDatastoreSize(), equals(1));
        
        await protocolManager.clearDatastore();
        
        expect(await protocolManager.getDatastoreSize(), equals(0));
      });
      
      test('should get datastore statistics', () async {

        final keyPair = await generateEd25519KeyPair();
        final privateKey = keyPair.privateKey;
        final peerId = PeerId.fromPublicKey(keyPair.publicKey);

        final record1 = await RecordSigner.createSignedRecord(
            key: 'key1',
            value: Uint8List.fromList([5, 6, 7, 8]),
            privateKey: privateKey,
            peerId: peerId);

        final record2 = await RecordSigner.createSignedRecord(
            key: 'key2',
            value: Uint8List.fromList([5, 6, 7, 8]),
            privateKey: privateKey,
            peerId: peerId);

        await protocolManager.putRecordToDatastore('key1', record1);
        await protocolManager.putRecordToDatastore('key2', record2);
        
        final stats = await protocolManager.getDatastoreStatistics();
        
        expect(stats['total_records'], equals(2));
        expect(stats['total_size_bytes'], equals(8)); // 4 + 4 bytes
        expect(stats['oldest_record_timestamp'], equals(record1.timeReceived));
        expect(stats['newest_record_timestamp'], equals(record2.timeReceived));
      });
      
      test('should reject older records', () async {
        final keyString = 'test-key';
        final currentTime = DateTime.now().millisecondsSinceEpoch;

        final keyPair = await generateEd25519KeyPair();
        final privateKey = keyPair.privateKey;
        final peerId = PeerId.fromPublicKey(keyPair.publicKey);

        final olderRecord = await RecordSigner.createSignedRecord(
            key: keyString,
            value: Uint8List.fromList([5, 6, 7, 8]),
            privateKey: privateKey,
            peerId: peerId);

        final newerRecord = await RecordSigner.createSignedRecord(
            key: keyString,
            value: Uint8List.fromList([5, 6, 7, 8]),
            privateKey: privateKey,
            peerId: peerId);
        

        // Store newer record first
        await protocolManager.putRecordToDatastore(keyString, newerRecord);
        
        // Try to store older record
        await protocolManager.putRecordToDatastore(keyString, olderRecord);
        
        // Should still have the newer record
        final retrievedRecord = await protocolManager.getRecordFromDatastore(keyString);
        expect(retrievedRecord!.value, equals(newerRecord.value));
        expect(retrievedRecord.timeReceived, equals(newerRecord.timeReceived));
      });
    });
    
    group('Integration with Other Managers', () {
      setUp(() async {
        protocolManager.initialize(
          config: config,
          metrics: mockMetricsManager,
          routing: mockRoutingManager,
          providerStore: mockProviderStore,
        );
        await protocolManager.start();
      });
      
      test('should add peers to routing manager during message handling', () async {
        final message = Message(type: MessageType.ping);
        
        await protocolManager.handlePing(remotePeerId, message);
        
        // Verify peer was added to routing manager
        expect(mockRoutingManager._peers.containsKey(remotePeerId), isTrue);
      });
      
      test('should record metrics during datastore operations', () async {
        final keyPair = await generateEd25519KeyPair();
        final privateKey = keyPair.privateKey;
        final peerId = PeerId.fromPublicKey(keyPair.publicKey);

        final keyString = 'test-key';
        final record= await RecordSigner.createSignedRecord(
            key: keyString,
            value: Uint8List.fromList([5, 6, 7, 8]),
            privateKey: privateKey,
            peerId: peerId);

        await protocolManager.putRecordToDatastore(keyString, record);
        await protocolManager.getRecordFromDatastore(keyString);
        await protocolManager.removeRecordFromDatastore(keyString);
        
        // Verify metrics were recorded
        expect(mockMetricsManager.recordedMetrics, hasLength(3));
        expect(mockMetricsManager.recordedMetrics, everyElement(contains('query_success')));
      });
      
      test('should interact with provider store during provider operations', () async {

        final digest = sha256.convert("random-bit-of-text".codeUnits);
        final mh = Multihash.encode('sha2-256', Uint8List.fromList(digest.bytes));
        final cid = CID.create(CID.V1, 'sha2-256', mh.toBytes());
        final keyBytes = cid.toBytes();
        final provider = AddrInfo(
          remotePeerId,
          [MultiAddr('/ip4/127.0.0.1/tcp/4001')],
        );
        
        // Add provider to mock store
        mockProviderStore.addMockProvider(cid, provider);
        
        final message = Message(
          type: MessageType.getProviders,
          key: keyBytes,
        );
        
        final response = await protocolManager.handleGetProviders(remotePeerId, message);
        
        // Verify provider was retrieved from store
        expect(response.providerPeers, hasLength(1));
        expect(response.providerPeers.first.id, equals(remotePeerId.toBytes()));
      });
    });
  });
} 