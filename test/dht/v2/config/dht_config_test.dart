import 'package:test/test.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_kad_dht/src/dht/dht_options.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/config/dht_config.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/config/bootstrap_config.dart';
import 'package:dart_libp2p_kad_dht/src/amino/defaults.dart';

void main() {
  group('DHTConfigV2', () {
    group('constructor', () {
      test('should create config with default values', () {
        final config = DHTConfigV2();
        
        expect(config.mode, equals(DHTMode.auto));
        expect(config.bucketSize, equals(AminoConstants.defaultBucketSize));
        expect(config.concurrency, equals(AminoConstants.defaultConcurrency));
        expect(config.resiliency, equals(AminoConstants.defaultResiliency));
        expect(config.provideValidity, equals(AminoConstants.defaultProvideValidity));
        expect(config.providerAddrTTL, equals(AminoConstants.defaultProviderAddrTTL));
        expect(config.autoRefresh, isTrue);
        expect(config.bootstrapPeers, isNull);
        expect(config.maxRetryAttempts, equals(3));
        expect(config.retryInitialBackoff, equals(const Duration(milliseconds: 500)));
        expect(config.retryMaxBackoff, equals(const Duration(seconds: 30)));
        expect(config.retryBackoffFactor, equals(2.0));
        expect(config.filterLocalhostInResponses, isTrue);
        expect(config.networkTimeout, equals(const Duration(seconds: 30)));
        expect(config.refreshInterval, equals(const Duration(minutes: 15)));
        expect(config.maxLatency, equals(AminoConstants.defaultMaxLatency));
        expect(config.maxPeersPerBucket, equals(20));
        expect(config.maxRoutingTableSize, equals(1000));
        expect(config.queryTimeout, equals(const Duration(seconds: 60)));
        expect(config.maxConcurrentQueries, equals(10));
        expect(config.optimisticProvide, isFalse);
        expect(config.enableMetrics, isTrue);
        expect(config.metricsInterval, equals(const Duration(minutes: 1)));
      });
      
      test('should create config with custom values', () {
        final bootstrapPeers = [
          MultiAddr('/ip4/127.0.0.1/tcp/4001/p2p/QmTest'),
        ];
        
        final config = DHTConfigV2(
          mode: DHTMode.server,
          bucketSize: 30,
          concurrency: 15,
          resiliency: 5,
          provideValidity: const Duration(hours: 2),
          providerAddrTTL: const Duration(minutes: 30),
          autoRefresh: false,
          bootstrapPeers: bootstrapPeers,
          maxRetryAttempts: 5,
          retryInitialBackoff: const Duration(seconds: 1),
          retryMaxBackoff: const Duration(minutes: 5),
          retryBackoffFactor: 1.5,
          filterLocalhostInResponses: false,
          networkTimeout: const Duration(minutes: 2),
          refreshInterval: const Duration(minutes: 30),
          maxPeersPerBucket: 50,
          maxRoutingTableSize: 2000,
          queryTimeout: const Duration(minutes: 2),
          maxConcurrentQueries: 20,
          optimisticProvide: true,
          enableMetrics: false,
          metricsInterval: const Duration(minutes: 5),
        );
        
        expect(config.mode, equals(DHTMode.server));
        expect(config.bucketSize, equals(30));
        expect(config.concurrency, equals(15));
        expect(config.resiliency, equals(5));
        expect(config.provideValidity, equals(const Duration(hours: 2)));
        expect(config.providerAddrTTL, equals(const Duration(minutes: 30)));
        expect(config.autoRefresh, isFalse);
        expect(config.bootstrapPeers, equals(bootstrapPeers));
        expect(config.maxRetryAttempts, equals(5));
        expect(config.retryInitialBackoff, equals(const Duration(seconds: 1)));
        expect(config.retryMaxBackoff, equals(const Duration(minutes: 5)));
        expect(config.retryBackoffFactor, equals(1.5));
        expect(config.filterLocalhostInResponses, isFalse);
        expect(config.networkTimeout, equals(const Duration(minutes: 2)));
        expect(config.refreshInterval, equals(const Duration(minutes: 30)));
        expect(config.maxPeersPerBucket, equals(50));
        expect(config.maxRoutingTableSize, equals(2000));
        expect(config.queryTimeout, equals(const Duration(minutes: 2)));
        expect(config.maxConcurrentQueries, equals(20));
        expect(config.optimisticProvide, isTrue);
        expect(config.enableMetrics, isFalse);
        expect(config.metricsInterval, equals(const Duration(minutes: 5)));
      });
    });
    
    group('fromOptions', () {
      test('should create config from DHTOptions', () {
        final options = DHTOptions(
          mode: DHTMode.client,
          bucketSize: 25,
          concurrency: 12,
          resiliency: 4,
          provideValidity: const Duration(hours: 1),
          providerAddrTTL: const Duration(minutes: 20),
          autoRefresh: false,
          bootstrapPeers: [MultiAddr('/ip4/127.0.0.1/tcp/4001/p2p/QmTest')],
          maxRetryAttempts: 4,
          retryInitialBackoff: const Duration(seconds: 2),
          retryMaxBackoff: const Duration(minutes: 2),
          retryBackoffFactor: 1.8,
          filterLocalhostInResponses: false,
        );
        
        final config = DHTConfigV2.fromOptions(options);
        
        expect(config.mode, equals(DHTMode.client));
        expect(config.bucketSize, equals(25));
        expect(config.concurrency, equals(12));
        expect(config.resiliency, equals(4));
        expect(config.provideValidity, equals(const Duration(hours: 1)));
        expect(config.providerAddrTTL, equals(const Duration(minutes: 20)));
        expect(config.autoRefresh, isFalse);
        expect(config.bootstrapPeers, equals(options.bootstrapPeers));
        expect(config.maxRetryAttempts, equals(4));
        expect(config.retryInitialBackoff, equals(const Duration(seconds: 2)));
        expect(config.retryMaxBackoff, equals(const Duration(minutes: 2)));
        expect(config.retryBackoffFactor, equals(1.8));
        expect(config.filterLocalhostInResponses, isFalse);
      });
    });
    
    group('toOptions', () {
      test('should convert config to DHTOptions', () {
        final config = DHTConfigV2(
          mode: DHTMode.server,
          bucketSize: 35,
          concurrency: 18,
          resiliency: 6,
          provideValidity: const Duration(hours: 3),
          providerAddrTTL: const Duration(minutes: 45),
          autoRefresh: true,
          bootstrapPeers: [MultiAddr('/ip4/127.0.0.1/tcp/4001/p2p/QmTest')],
          maxRetryAttempts: 6,
          retryInitialBackoff: const Duration(seconds: 3),
          retryMaxBackoff: const Duration(minutes: 10),
          retryBackoffFactor: 2.5,
          filterLocalhostInResponses: true,
        );
        
        final options = config.toOptions();
        
        expect(options.mode, equals(DHTMode.server));
        expect(options.bucketSize, equals(35));
        expect(options.concurrency, equals(18));
        expect(options.resiliency, equals(6));
        expect(options.provideValidity, equals(const Duration(hours: 3)));
        expect(options.providerAddrTTL, equals(const Duration(minutes: 45)));
        expect(options.autoRefresh, isTrue);
        expect(options.bootstrapPeers, equals(config.bootstrapPeers));
        expect(options.maxRetryAttempts, equals(6));
        expect(options.retryInitialBackoff, equals(const Duration(seconds: 3)));
        expect(options.retryMaxBackoff, equals(const Duration(minutes: 10)));
        expect(options.retryBackoffFactor, equals(2.5));
        expect(options.filterLocalhostInResponses, isTrue);
      });
    });
    
    group('copyWith', () {
      test('should create new config with updated values', () {
        final original = DHTConfigV2(
          mode: DHTMode.auto,
          bucketSize: 20,
          concurrency: 10,
          enableMetrics: true,
        );
        
        final updated = original.copyWith(
          mode: DHTMode.server,
          bucketSize: 30,
          enableMetrics: false,
        );
        
        expect(updated.mode, equals(DHTMode.server));
        expect(updated.bucketSize, equals(30));
        expect(updated.concurrency, equals(10)); // unchanged
        expect(updated.enableMetrics, isFalse);
      });
      
      test('should preserve original values when no updates provided', () {
        final original = DHTConfigV2(
          mode: DHTMode.client,
          bucketSize: 25,
          concurrency: 15,
          enableMetrics: false,
        );
        
        final copied = original.copyWith();
        
        expect(copied.mode, equals(original.mode));
        expect(copied.bucketSize, equals(original.bucketSize));
        expect(copied.concurrency, equals(original.concurrency));
        expect(copied.enableMetrics, equals(original.enableMetrics));
      });
    });
    
    group('toString', () {
      test('should return formatted string representation', () {
        final config = DHTConfigV2(
          mode: DHTMode.server,
          bucketSize: 25,
          concurrency: 12,
        );
        
        final str = config.toString();
        
        expect(str, contains('DHTConfigV2'));
        expect(str, contains('mode: DHTMode.server'));
        expect(str, contains('bucketSize: 25'));
        expect(str, contains('concurrency: 12'));
      });
    });
  });
  
  group('DHTConfigBuilder', () {
    test('should build config with default values', () {
      final config = DHTConfigBuilder().build();
      
      expect(config.mode, equals(DHTMode.auto));
      expect(config.bucketSize, equals(AminoConstants.defaultBucketSize));
      expect(config.concurrency, equals(AminoConstants.defaultConcurrency));
      expect(config.enableMetrics, isTrue);
      expect(config.optimisticProvide, isFalse);
    });
    
    test('should build config with custom values using fluent API', () {
      final bootstrapPeers = [
        MultiAddr('/ip4/127.0.0.1/tcp/4001/p2p/QmTest'),
      ];
      
      final config = DHTConfigBuilder()
          .mode(DHTMode.server)
          .bucketSize(30)
          .concurrency(15)
          .resiliency(5)
          .filterLocalhost(false)
          .bootstrapPeers(bootstrapPeers)
          .networkTimeout(const Duration(minutes: 2))
          .queryTimeout(const Duration(minutes: 3))
          .enableMetrics(false)
          .optimisticProvide(true)
          .build();
      
      expect(config.mode, equals(DHTMode.server));
      expect(config.bucketSize, equals(30));
      expect(config.concurrency, equals(15));
      expect(config.resiliency, equals(5));
      expect(config.filterLocalhostInResponses, isFalse);
      expect(config.bootstrapPeers, equals(bootstrapPeers));
      expect(config.networkTimeout, equals(const Duration(minutes: 2)));
      expect(config.queryTimeout, equals(const Duration(minutes: 3)));
      expect(config.enableMetrics, isFalse);
      expect(config.optimisticProvide, isTrue);
    });
    
    test('should support method chaining', () {
      final builder = DHTConfigBuilder();
      
      final result1 = builder.mode(DHTMode.server);
      final result2 = result1.bucketSize(30);
      final result3 = result2.concurrency(15);
      
      expect(result1, same(builder));
      expect(result2, same(builder));
      expect(result3, same(builder));
    });
    
    test('should build different configs from same builder', () {
      final builder = DHTConfigBuilder()
          .mode(DHTMode.server)
          .bucketSize(30);
      
      final config1 = builder.build();
      final config2 = builder.concurrency(20).build();
      
      expect(config1.mode, equals(DHTMode.server));
      expect(config1.bucketSize, equals(30));
      expect(config1.concurrency, equals(AminoConstants.defaultConcurrency));
      
      expect(config2.mode, equals(DHTMode.server));
      expect(config2.bucketSize, equals(30));
      expect(config2.concurrency, equals(20));
    });
  });
  
  group('BootstrapConfig', () {
    // group('defaultBootstrapPeers', () {
    //   test('should contain expected bootstrap peers', () {
    //     expect(BootstrapConfig.defaultBootstrapPeers, isNotEmpty);
    //     expect(BootstrapConfig.defaultBootstrapPeers.length, equals(5));
    //
    //     for (final peer in BootstrapConfig.defaultBootstrapPeers) {
    //       expect(peer, contains('/p2p/'));
    //       expect(peer, anyOf(contains('/dnsaddr/'), contains('/ip4/')));
    //     }
    //   });
    // });
    
    group('getDefaultBootstrapPeers', () {
      // test('should return valid MultiAddr objects', () {
      //   final peers = BootstrapConfig.getDefaultBootstrapPeers();
      //
      //   expect(peers, isNotEmpty);
      //   expect(peers.length, lessThanOrEqualTo(BootstrapConfig.defaultBootstrapPeers.length));
      //
      //   for (final peer in peers) {
      //     expect(peer, isA<MultiAddr>());
      //     expect(peer.toString(), contains('/p2p/'));
      //   }
      // });
      
      test('should handle invalid addresses gracefully', () {
        // This test assumes that invalid addresses in the default list would be skipped
        // and not cause the method to throw
        expect(() => BootstrapConfig.getDefaultBootstrapPeers(), returnsNormally);
      });
    });
    
    group('getDefaultBootstrapPeerAddrInfos', () {
      test('should return valid AddrInfo objects', () {
        final addrInfos = BootstrapConfig.getDefaultBootstrapPeerAddrInfos();
        
        expect(addrInfos, isNotEmpty);
        
        for (final addrInfo in addrInfos) {
          expect(addrInfo.id, isNotNull);
          expect(addrInfo.addrs, isNotEmpty);
        }
      });
      
      test('should handle conversion errors gracefully', () {
        expect(() => BootstrapConfig.getDefaultBootstrapPeerAddrInfos(), returnsNormally);
      });
    });
    
    group('extractPeerIdFromMultiaddr', () {
      test('should extract peer ID from valid multiaddr', () async {
        final randomPid= await PeerId.random();
        final addr = MultiAddr('/ip4/127.0.0.1/tcp/4001/p2p/${randomPid.toString()}');
        final peerId = BootstrapConfig.extractPeerIdFromMultiaddr(addr);
        
        expect(peerId, isNotNull);
        expect(peerId.toString(), equals(randomPid.toString()));
      });
      
      test('should return null for multiaddr without peer ID', () {
        final addr = MultiAddr('/ip4/127.0.0.1/tcp/4001');
        final peerId = BootstrapConfig.extractPeerIdFromMultiaddr(addr);
        
        expect(peerId, isNull);
      });
      
      test('should handle invalid multiaddr gracefully', () {
        final addr = MultiAddr('/ip4/127.0.0.1/tcp/4001/p2p/invalid');
        
        expect(() => BootstrapConfig.extractPeerIdFromMultiaddr(addr), returnsNormally);
      });
    });
    
    group('validateBootstrapPeers', () {
      test('should return true for valid peers', () async {
        final p1 = await PeerId.random();
        final p2 = await PeerId.random();
        final peers = [
          MultiAddr('/ip4/127.0.0.1/tcp/4001/p2p/${p1.toString()}'),
          MultiAddr('/ip4/127.0.0.2/tcp/4001/p2p/${p2.toString()}'),
        ];
        
        final result = BootstrapConfig.validateBootstrapPeers(peers);
        
        expect(result, isTrue);
      });
      
      test('should return false for empty peer list', () {
        final result = BootstrapConfig.validateBootstrapPeers([]);
        
        expect(result, isFalse);
      });
      
      test('should return false for peers without peer IDs', () {
        final peers = [
          MultiAddr('/ip4/127.0.0.1/tcp/4001/p2p/QmTest1'),
          MultiAddr('/ip4/127.0.0.2/tcp/4001'), // missing peer ID
        ];
        
        final result = BootstrapConfig.validateBootstrapPeers(peers);
        
        expect(result, isFalse);
      });
    });
  });
  
  group('Integration', () {
    test('should work together - config from builder with bootstrap peers', () {
      final bootstrapPeers = BootstrapConfig.getDefaultBootstrapPeers();
      
      final config = DHTConfigBuilder()
          .mode(DHTMode.server)
          .bootstrapPeers(bootstrapPeers)
          .build();
      
      expect(config.mode, equals(DHTMode.server));
      expect(config.bootstrapPeers, equals(bootstrapPeers));
      expect(BootstrapConfig.validateBootstrapPeers(bootstrapPeers), isTrue);
    });
    
    test('should maintain backward compatibility with DHTOptions', () {
      final options = DHTOptions(
        mode: DHTMode.client,
        bucketSize: 25,
        concurrency: 12,
      );
      
      final config = DHTConfigV2.fromOptions(options);
      final convertedOptions = config.toOptions();
      
      expect(convertedOptions.mode, equals(options.mode));
      expect(convertedOptions.bucketSize, equals(options.bucketSize));
      expect(convertedOptions.concurrency, equals(options.concurrency));
    });
  });
} 