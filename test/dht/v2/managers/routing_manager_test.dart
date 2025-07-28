import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/peerstore.dart';
import 'package:dart_libp2p/p2p/discovery/peer_info.dart';
import 'package:test/test.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/managers/routing_manager.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/managers/metrics_manager.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/managers/network_manager.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/config/dht_config.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/errors/dht_errors.dart';
import 'package:dart_libp2p_kad_dht/src/dht/dht_options.dart';
import 'package:dart_libp2p_kad_dht/src/pb/dht_message.dart';
import 'package:dart_libp2p_kad_dht/src/amino/defaults.dart';
import 'package:dart_libp2p_kad_dht/src/kbucket/table/table.dart';

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
  final Map<PeerId, Exception?> _connectErrors = {};
  final Map<PeerId, bool> _connectivity = {};
  
  MockHost(this._id) : _peerStore = MockPeerStore();
  
  void setConnectError(PeerId peerId, Exception? error) {
    _connectErrors[peerId] = error;
  }
  
  void setConnectivity(PeerId peerId, bool connected) {
    _connectivity[peerId] = connected;
  }
  
  @override
  PeerId get id => _id;
  
  @override
  Peerstore get peerStore => _peerStore;
  
  @override
  Future<P2PStream> newStream(PeerId peerId, List<String> protocols, Context context) async {
    final error = _connectErrors[peerId];
    if (error != null) {
      throw error;
    }
    
    final connected = _connectivity[peerId] ?? true;
    if (!connected) {
      throw Exception('Connection failed');
    }
    
    return MockP2PStream(peerId);
  }
  
  /// Mock connect method for testing
  @override
  Future<void> connect(AddrInfo addrInfo, {Context? context}) async {
    final error = _connectErrors[addrInfo.id];
    if (error != null) {
      throw error;
    }
    
    final connected = _connectivity[addrInfo.id] ?? true;
    if (!connected) {
      throw Exception('Connection failed');
    }
    
    // Mock successful connection
  }
  
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Mock implementation of P2PStream for testing
class MockP2PStream implements P2PStream {
  final PeerId _remotePeer;
  bool _closed = false;
  
  MockP2PStream(this._remotePeer);
  
  @override
  Future<void> close() async {
    _closed = true;
  }
  
  @override
  Future<Uint8List> read([int? maxBytes]) async {
    if (_closed) throw StateError('Stream is closed');
    return Uint8List(0);
  }
  
  @override
  Future<void> write(Uint8List data) async {
    if (_closed) throw StateError('Stream is closed');
  }
  
  @override
  String protocol() => AminoConstants.protocolID;
  
  PeerId get remotePeer => _remotePeer;
  
  @override
  bool get isClosed => _closed;
  
  @override
  String id() => _remotePeer.toBase58();
  
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Mock implementation of NetworkManager for testing
class MockNetworkManager extends NetworkManager {
  final Map<PeerId, Message?> _responseMap = {};
  final Map<PeerId, Exception?> _errorMap = {};
  final Map<PeerId, Duration?> _delayMap = {};
  bool _started = false;
  
  MockNetworkManager(Host host) : super(host);
  
  void setResponse(PeerId peerId, Message? response) {
    _responseMap[peerId] = response;
  }
  
  void setError(PeerId peerId, Exception? error) {
    _errorMap[peerId] = error;
  }
  
  void setDelay(PeerId peerId, Duration delay) {
    _delayMap[peerId] = delay;
  }
  
  @override
  Future<void> start() async {
    _started = true;
  }
  
  @override
  Future<void> close() async {
    _started = false;
  }
  
  @override
  Future<Message> sendMessage(PeerId peerId, Message message) async {
    final delay = _delayMap[peerId];
    if (delay != null) {
      await Future.delayed(delay);
    }
    
    final error = _errorMap[peerId];
    if (error != null) {
      throw error;
    }
    
    return _responseMap[peerId] ?? Message(type: MessageType.ping);
  }
  
  Future<void> sendMessageAsync(PeerId peerId, Message message) async {
    final delay = _delayMap[peerId];
    if (delay != null) {
      await Future.delayed(delay);
    }
    
    final error = _errorMap[peerId];
    if (error != null) {
      throw error;
    }
  }
  
  @override
  bool get isStarted => _started;
}

void main() {
  group('RoutingManager', () {
    late RoutingManager routingManager;
    late MockHost mockHost;
    late MockNetworkManager mockNetwork;
    late MetricsManager metrics;
    late PeerId hostId;
    late DHTConfigV2 config;
    late DHTOptions options;
    
    setUp(() async {
      hostId = await PeerId.random();
      mockHost = MockHost(hostId);
      mockNetwork = MockNetworkManager(mockHost);
      metrics = MetricsManager();
      
      options = DHTOptions(
        mode: DHTMode.server,
        bucketSize: 20,
      );
      
      config = DHTConfigV2(
        autoRefresh: true,
        refreshInterval: Duration(seconds: 30),
        networkTimeout: Duration(seconds: 5),
        resiliency: 3,
        bootstrapPeers: [],
      );
      
      routingManager = RoutingManager(mockHost, options);
      
      await metrics.start();
      await mockNetwork.start();
      
      routingManager.initialize(
        config: config,
        metrics: metrics,
        network: mockNetwork,
      );
    });
    
    tearDown(() async {
      await routingManager.close();
      await mockNetwork.close();
      await metrics.close();
    });
    
    group('initialization', () {
      test('should initialize with correct configuration', () {
        expect(routingManager.routingTable, isNotNull);
        expect(routingManager.toString(), contains(hostId.toBase58().substring(0, 6)));
      });
      
      test('should have empty routing table initially', () async {
        await routingManager.start();
        final size = await routingManager.getSize();
        expect(size, equals(0));
      });
      
      test('should start and close properly', () async {
        await routingManager.start();
        await routingManager.close();
        // Should not throw
      });
    });
    
    group('lifecycle management', () {
      test('should throw when operating on closed manager', () async {
        await routingManager.start();
        await routingManager.close();
        
        expect(() => routingManager.addPeer(hostId), throwsA(isA<DHTClosedException>()));
      });
      
      test('should throw when operating on non-started manager', () async {
        expect(() => routingManager.addPeer(hostId), throwsA(isA<DHTNotStartedException>()));
      });
      
      test('should handle multiple start calls gracefully', () async {
        await routingManager.start();
        await routingManager.start(); // Should not throw
        await routingManager.close();
      });
      
      test('should handle multiple close calls gracefully', () async {
        await routingManager.start();
        await routingManager.close();
        await routingManager.close(); // Should not throw
      });
    });
    
    group('peer management', () {
      setUp(() async {
        await routingManager.start();
      });
      
      test('should add peer successfully', () async {
        final peerId = await PeerId.random();
        final result = await routingManager.addPeer(peerId);
        
        expect(result, isTrue);
        final size = await routingManager.getSize();
        expect(size, equals(1));
      });
      
      test('should add multiple peers', () async {
        final peerIds = <PeerId>[];
        for (int i = 0; i < 5; i++) {
          peerIds.add(await PeerId.random());
        }
        
        for (final peerId in peerIds) {
          await routingManager.addPeer(peerId);
        }
        
        final size = await routingManager.getSize();
        expect(size, equals(5));
      });
      
      test('should remove peer successfully', () async {
        final peerId = await PeerId.random();
        await routingManager.addPeer(peerId);
        
        final result = await routingManager.removePeer(peerId);
        
        expect(result, isTrue);
        final size = await routingManager.getSize();
        expect(size, equals(0));
      });
      
      test('should find existing peer', () async {
        final peerId = await PeerId.random();
        await routingManager.addPeer(peerId);
        
        final found = await routingManager.findPeer(peerId);
        expect(found, equals(peerId));
      });
      
      test('should return null for non-existent peer', () async {
        final peerId = await PeerId.random();
        final found = await routingManager.findPeer(peerId);
        expect(found, isNull);
      });
      
      test('should get all peers', () async {
        final peerIds = <PeerId>[];
        for (int i = 0; i < 3; i++) {
          peerIds.add(await PeerId.random());
        }
        
        for (final peerId in peerIds) {
          await routingManager.addPeer(peerId);
        }
        
        final allPeers = await routingManager.getAllPeers();
        expect(allPeers.length, equals(3));
        
        final returnedIds = allPeers.map((p) => p.id).toSet();
        final originalIds = peerIds.toSet();
        expect(returnedIds, equals(originalIds));
      });
      
      test('should get nearest peers', () async {
        final peerIds = <PeerId>[];
        for (int i = 0; i < 5; i++) {
          peerIds.add(await PeerId.random());
        }
        
        for (final peerId in peerIds) {
          await routingManager.addPeer(peerId);
        }
        
        final targetKey = Uint8List.fromList(List.generate(32, (i) => i));
        final nearest = await routingManager.getNearestPeers(targetKey, 3);
        
        expect(nearest.length, lessThanOrEqualTo(3));
      });
      
      test('should handle adding same peer multiple times', () async {
        final peerId = await PeerId.random();
        
        await routingManager.addPeer(peerId);
        await routingManager.addPeer(peerId); // Should not throw
        
        final size = await routingManager.getSize();
        expect(size, equals(1));
      });
    });
    
    group('bootstrap operations', () {
      setUp(() async {
        await routingManager.start();
      });
      
      test('should bootstrap with no peers configured', () async {
        await routingManager.bootstrap();
        // Should complete without error
      });
      
      test('should bootstrap with configured peers', () async {
        final bootstrapPeer = await PeerId.random();
        final bootstrapAddr = MultiAddr('/ip4/127.0.0.1/tcp/4001/p2p/${bootstrapPeer.toBase58()}');
        
        final configWithBootstrap = DHTConfigV2(
          autoRefresh: true,
          refreshInterval: Duration(seconds: 30),
          networkTimeout: Duration(seconds: 5),
          resiliency: 3,
          bootstrapPeers: [bootstrapAddr],
        );
        
        final newManager = RoutingManager(mockHost, options);
        newManager.initialize(
          config: configWithBootstrap,
          metrics: metrics,
          network: mockNetwork,
        );
        
        await newManager.start();
        
        // Mock successful ping response
        mockNetwork.setResponse(
          bootstrapPeer,
          Message(type: MessageType.ping),
        );
        
        await newManager.bootstrap();
        await newManager.close();
      });
      
      test('should handle bootstrap failure gracefully', () async {
        final bootstrapPeer = await PeerId.random();
        final bootstrapAddr = MultiAddr('/ip4/127.0.0.1/tcp/4001/p2p/${bootstrapPeer.toBase58()}');
        
        final configWithBootstrap = DHTConfigV2(
          autoRefresh: true,
          refreshInterval: Duration(seconds: 30),
          networkTimeout: Duration(seconds: 5),
          resiliency: 3,
          bootstrapPeers: [bootstrapAddr],
        );
        
        final newManager = RoutingManager(mockHost, options);
        newManager.initialize(
          config: configWithBootstrap,
          metrics: metrics,
          network: mockNetwork,
        );
        
        await newManager.start();
        
        // Mock network error for the bootstrap peer
        mockNetwork.setError(bootstrapPeer, Exception('Network error'));
        
        // Bootstrap should succeed despite the failed peer (resilient behavior)
        await newManager.bootstrap();
        
        // Verify the failed peer was removed from routing table during verification
        final found = await newManager.findPeer(bootstrapPeer);
        expect(found, isNull);
        
        // Verify routing table is still functional
        final size = await newManager.getSize();
        expect(size, greaterThanOrEqualTo(0));
        
        await newManager.close();
      });
    });
    
    group('health monitoring', () {
      setUp(() async {
        await routingManager.start();
      });
      
      test('should be unhealthy with no peers', () async {
        final healthy = await routingManager.isHealthy();
        expect(healthy, isFalse);
      });
      
      test('should be healthy with sufficient peers', () async {
        // Add more peers than the resiliency requirement
        for (int i = 0; i < 5; i++) {
          await routingManager.addPeer(await PeerId.random());
        }
        
        final healthy = await routingManager.isHealthy();
        expect(healthy, isTrue);
      });
      
      test('should provide statistics', () async {
        // Add some peers
        for (int i = 0; i < 3; i++) {
          await routingManager.addPeer(await PeerId.random());
        }
        
        final stats = await routingManager.getStatistics();
        
        expect(stats['size'], equals(3));
        expect(stats['peers'], equals(3));
        expect(stats['healthy'], isA<bool>());
      });
    });
    
    group('bootstrap peer operations', () {
      setUp(() async {
        await routingManager.start();
      });
      
      test('should get bootstrap peers', () async {
        final peerIds = <PeerId>[];
        for (int i = 0; i < 3; i++) {
          peerIds.add(await PeerId.random());
        }
        
        // Add peers to routing table and peerstore
        for (final peerId in peerIds) {
          await routingManager.addPeer(peerId);
          await mockHost.peerStore.addOrUpdatePeer(
            peerId,
            addrs: [MultiAddr('/ip4/127.0.0.1/tcp/4001')],
          );
        }
        
        final bootstrapPeers = await routingManager.getBootstrapPeers();
        expect(bootstrapPeers.length, equals(3));
        
        for (final peer in bootstrapPeers) {
          expect(peer.addrs.isNotEmpty, isTrue);
        }
      });
      
      test('should handle peers without addresses', () async {
        final peerId = await PeerId.random();
        await routingManager.addPeer(peerId);
        // Don't add to peerstore with addresses
        
        final bootstrapPeers = await routingManager.getBootstrapPeers();
        expect(bootstrapPeers.length, equals(0));
      });
    });
    
    group('error handling', () {
      setUp(() async {
        await routingManager.start();
      });
      
      test('should handle routing table errors gracefully', () async {
        // Test with invalid peer ID operations
        final invalidPeerId = await PeerId.random();
        
        // These should complete without throwing
        final removed = await routingManager.removePeer(invalidPeerId);
        expect(removed, isFalse); // Returns false when peer is not found
        
        final found = await routingManager.findPeer(invalidPeerId);
        expect(found, isNull);
      });
      
      test('should handle network errors during bootstrap', () async {
        final peerId = await PeerId.random();
        mockNetwork.setError(peerId, Exception('Network timeout'));
        
        // Should handle gracefully without throwing
        await routingManager.bootstrap();
      });
      
      test('should handle metrics errors gracefully', () async {
        // Close metrics to simulate error
        await metrics.close();
        
        // Operations should still work
        await routingManager.addPeer(await PeerId.random());
        final size = await routingManager.getSize();
        expect(size, equals(1));
      });
    });
    
    group('periodic refresh', () {
      test('should handle periodic refresh when enabled', () async {
        final shortConfig = DHTConfigV2(
          autoRefresh: true,
          refreshInterval: Duration(milliseconds: 100),
          networkTimeout: Duration(seconds: 5),
          resiliency: 3,
          bootstrapPeers: [],
        );
        
        final refreshManager = RoutingManager(mockHost, options);
        refreshManager.initialize(
          config: shortConfig,
          metrics: metrics,
          network: mockNetwork,
        );
        
        await refreshManager.start();
        
        // Wait for at least one refresh cycle
        await Future.delayed(Duration(milliseconds: 200));
        
        await refreshManager.close();
        // Should complete without error
      });
      
      test('should not start refresh when disabled', () async {
        final noRefreshConfig = DHTConfigV2(
          autoRefresh: false,
          refreshInterval: Duration(seconds: 30),
          networkTimeout: Duration(seconds: 5),
          resiliency: 3,
          bootstrapPeers: [],
        );
        
        final noRefreshManager = RoutingManager(mockHost, options);
        noRefreshManager.initialize(
          config: noRefreshConfig,
          metrics: metrics,
          network: mockNetwork,
        );
        
        await noRefreshManager.start();
        await noRefreshManager.close();
        // Should complete without error
      });
    });
    
    group('integration scenarios', () {
      setUp(() async {
        await routingManager.start();
      });
      
      test('should handle full peer lifecycle', () async {
        final peerId = await PeerId.random();
        
        // Add peer
        final added = await routingManager.addPeer(peerId);
        expect(added, isTrue);
        
        // Verify peer exists
        final found = await routingManager.findPeer(peerId);
        expect(found, equals(peerId));
        
        // Check statistics
        final stats = await routingManager.getStatistics();
        expect(stats['size'], equals(1));
        
        // Remove peer
        final removed = await routingManager.removePeer(peerId);
        expect(removed, isTrue);
        
        // Verify peer is gone
        final notFound = await routingManager.findPeer(peerId);
        expect(notFound, isNull);
      });
      
      test('should handle concurrent peer operations', () async {
        final futures = <Future>[];
        
        // Add peers concurrently
        for (int i = 0; i < 10; i++) {
          futures.add(routingManager.addPeer(await PeerId.random()));
        }
        
        await Future.wait(futures);
        
        final size = await routingManager.getSize();
        expect(size, equals(10));
      });
      
      test('should maintain routing table consistency', () async {
        final peerIds = <PeerId>[];
        for (int i = 0; i < 5; i++) {
          peerIds.add(await PeerId.random());
        }
        
        // Add all peers
        for (final peerId in peerIds) {
          await routingManager.addPeer(peerId);
        }
        
        // Verify all peers exist
        final allPeers = await routingManager.getAllPeers();
        expect(allPeers.length, equals(5));
        
        // Remove some peers
        for (int i = 0; i < 2; i++) {
          await routingManager.removePeer(peerIds[i]);
        }
        
        // Verify correct count
        final remainingPeers = await routingManager.getAllPeers();
        expect(remainingPeers.length, equals(3));
      });
    });
  });
} 