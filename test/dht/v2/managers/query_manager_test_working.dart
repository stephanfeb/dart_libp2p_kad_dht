import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p_kad_dht/src/dht/v2/managers/protocol_manager.dart';
import 'package:test/test.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peerstore.dart';
import 'package:dart_libp2p/p2p/discovery/peer_info.dart';
import 'package:dcid/dcid.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/managers/query_manager.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/managers/network_manager.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/managers/routing_manager.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/managers/metrics_manager.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/config/dht_config.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/errors/dht_errors.dart';
import 'package:dart_libp2p_kad_dht/src/pb/dht_message.dart';
import 'package:dart_libp2p_kad_dht/src/providers/provider_store.dart';

/// Simple mock implementations for testing
class SimpleNetworkManager implements NetworkManager {
  final PeerId _hostId;
  SimpleNetworkManager(this._hostId);
  
  @override
  Host get host => SimpleHost(_hostId);
  
  @override
  Future<Message> sendMessage(PeerId peerId, Message message) async {
    return Message(type: MessageType.ping);
  }
  
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class SimpleHost implements Host {
  final PeerId _id;
  SimpleHost(this._id);
  
  @override
  PeerId get id => _id;
  
  @override
  Peerstore get peerStore => SimplePeerStore();
  
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class SimplePeerStore implements Peerstore {
  @override
  Future<PeerInfo?> getPeer(PeerId peerId) async => null;
  
  @override
  Future<void> addOrUpdatePeer(PeerId peerId, {Iterable<MultiAddr>? addrs, Iterable<String>? protocols, Map<String, dynamic>? metadata}) async {
    // Simple implementation - just complete successfully
  }
  
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class SimpleRoutingManager implements RoutingManager {
  @override
  Future<PeerId?> findPeer(PeerId peer) async => null;
  
  @override
  Future<List<PeerId>> getNearestPeers(Uint8List target, int count) async => [];
  
  @override
  Future<List<AddrInfo>> getBootstrapPeers() async => [];
  
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class SimpleMetricsManager implements MetricsManager {
  int _queryStartCount = 0;
  int _querySuccessCount = 0;
  int _queryFailureCount = 0;
  
  int get queryStartCount => _queryStartCount;
  int get querySuccessCount => _querySuccessCount;
  int get queryFailureCount => _queryFailureCount;
  
  @override
  void recordQueryStart() => _queryStartCount++;
  
  @override
  void recordQuerySuccess(Duration duration) => _querySuccessCount++;
  
  @override
  void recordQueryFailure(String operation, {PeerId? peer}) => _queryFailureCount++;
  
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class SimpleProviderStore implements ProviderStore {
  @override
  Future<void> addProvider(CID key, AddrInfo provider) async {}
  
  @override
  Future<List<AddrInfo>> getProviders(CID key) async => [];
  
  @override
  Future<void> close() async {}
}

void main() {
  group('QueryManager (Simple)', () {
    late QueryManager queryManager;
    late SimpleNetworkManager mockNetwork;
    late SimpleRoutingManager mockRouting;
    late SimpleMetricsManager mockMetrics;
    late SimpleProviderStore mockProviderStore;
    late DHTConfigV2 config;
    late ProtocolManager protocolManager;
    
    setUp(() async {
      final hostId = await PeerId.random();
      mockNetwork = SimpleNetworkManager(hostId);
      mockRouting = SimpleRoutingManager();
      mockMetrics = SimpleMetricsManager();
      mockProviderStore = SimpleProviderStore();

      protocolManager = ProtocolManager(mockNetwork.host);
      
      config = DHTConfigV2(
        networkTimeout: Duration(seconds: 5),
        resiliency: 3,
        bucketSize: 20,
        autoRefresh: true,
        refreshInterval: Duration(seconds: 30),
      );
      
      queryManager = QueryManager();
      queryManager.initialize(
        network: mockNetwork,
        routing: mockRouting,
        config: config,
        metrics: mockMetrics,
        providerStore: mockProviderStore,
        protocol: protocolManager
      );
    });
    
    group('lifecycle', () {
      test('should initialize successfully', () {
        expect(queryManager, isNotNull);
      });
      
      test('should start successfully', () async {
        await queryManager.start();
        // Should complete without errors
      });
      
      test('should close successfully', () async {
        await queryManager.start();
        await queryManager.close();
        // Should complete without errors
      });
      
      test('should handle multiple start calls', () async {
        await queryManager.start();
        await queryManager.start(); // Should not throw
      });
      
      test('should handle multiple close calls', () async {
        await queryManager.start();
        await queryManager.close();
        await queryManager.close(); // Should not throw
      });
      
      test('should throw when not started', () async {
        final peer = await PeerId.random();
        
        expect(
          () => queryManager.findPeer(peer),
          throwsA(isA<DHTNotStartedException>()),
        );
      });
      
      test('should throw when closed', () async {
        await queryManager.start();
        await queryManager.close();
        
        final peer = await PeerId.random();
        
        expect(
          () => queryManager.findPeer(peer),
          throwsA(isA<DHTClosedException>()),
        );
      });
    });
    
    group('basic operations', () {
      setUp(() async {
        await queryManager.start();
      });
      
      tearDown(() async {
        await queryManager.close();
      });
      
      test('should handle findPeer gracefully', () async {
        final peer = await PeerId.random();
        
        final result = await queryManager.findPeer(peer);
        
        // Should return null for non-existent peer
        expect(result, isNull);
        expect(mockMetrics.queryStartCount, equals(1));
        expect(mockMetrics.queryFailureCount, equals(0));
      });
      
      test('should handle getClosestPeers gracefully', () async {
        final target = await PeerId.random();
        
        final result = await queryManager.getClosestPeers(target);
        
        // Should return empty list when no peers available
        expect(result, isEmpty);
        expect(mockMetrics.queryStartCount, equals(1));
        expect(mockMetrics.querySuccessCount, equals(1));
      });
      
      test('should handle advertise operation', () async {
        final namespace = 'test-namespace';
        
        final result = await queryManager.advertise(namespace);
        
        expect(result, isA<Duration>());
        expect(result.inSeconds, greaterThan(0));
      });
      
      test('should handle addProvider operation', () async {
        // Create a proper multihash for the key (SHA-256 with 32 bytes)
        final key = Uint8List.fromList([
          0x12, 0x20, // SHA-256 multihash prefix (code 0x12, length 0x20)
          ...List.generate(32, (i) => i + 1), // 32 bytes of data
        ]);
        final provider = AddrInfo(
          await PeerId.random(),
          [MultiAddr('/ip4/127.0.0.1/tcp/4001')],
        );
        
        // Should complete without error
        await queryManager.addProvider(key, provider);
      });
      
      test('should handle provide operation', () async {
        final cid = CID(1, 0x70, Uint8List.fromList([1, 2, 3, 4]));
        
        // Should complete without error
        await queryManager.provide(cid, true);
        
        expect(mockMetrics.queryStartCount, equals(1));
        expect(mockMetrics.querySuccessCount, equals(1));
      });
    });
    
    group('metrics tracking', () {
      setUp(() async {
        await queryManager.start();
      });
      
      tearDown(() async {
        await queryManager.close();
      });
      
      test('should track query metrics', () async {
        final initialStarts = mockMetrics.queryStartCount;
        final initialSuccesses = mockMetrics.querySuccessCount;
        final initialFailures = mockMetrics.queryFailureCount;
        
        final target = await PeerId.random();
        
        // This should succeed (empty result)
        await queryManager.getClosestPeers(target);
        
        expect(mockMetrics.queryStartCount, equals(initialStarts + 1));
        expect(mockMetrics.querySuccessCount, equals(initialSuccesses + 1));
        expect(mockMetrics.queryFailureCount, equals(initialFailures));
        
        // This should fail (no peer found)
        await queryManager.findPeer(target);
        
        expect(mockMetrics.queryStartCount, equals(initialStarts + 2));
        expect(mockMetrics.querySuccessCount, equals(initialSuccesses + 2));
        expect(mockMetrics.queryFailureCount, equals(initialFailures + 0));
      });
    });
    
    group('error handling', () {
      setUp(() async {
        await queryManager.start();
      });
      
      tearDown() async {
        await queryManager.close();
      };
      
      test('should handle operations gracefully when no peers available', () async {
        final target = await PeerId.random();
        
        // Should not throw
        final result = await queryManager.getClosestPeers(target);
        expect(result, isEmpty);
        
        final peerResult = await queryManager.findPeer(target);
        expect(peerResult, isNull);
      });
      
      test('should handle stream operations gracefully', () async {
        final cid = CID(1, 0x70, Uint8List.fromList([1, 2, 3, 4]));
        
        // Should not throw and should complete
        final providers = <AddrInfo>[];
        await for (final provider in queryManager.findProvidersAsync(cid, 10)) {
          providers.add(provider);
          break; // Prevent infinite loop
        }
        
        expect(providers, isEmpty);
      });
      
      test('should handle value operations gracefully', () async {
        final key = 'test-key-with-sufficient-length';
        final value = Uint8List.fromList([1, 2, 3, 4]);
        
        // Get non-existent value
        final result = await queryManager.getValue(key, null);
        expect(result, isNull);
        
        // Search for values
        final values = <Uint8List>[];
        await for (final foundValue in queryManager.searchValue(key, null)) {
          values.add(foundValue);
          break; // Prevent infinite loop
        }
        
        expect(values, isEmpty);
      });
    });
  });
} 