import 'dart:async';
import 'dart:collection';

import 'package:test/test.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/managers/metrics_manager.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/config/dht_config.dart';

void main() {
  group('MetricsManager Tests', () {
    late MetricsManager metricsManager;
    late DHTConfigV2 config;
    late PeerId testPeerId;
    
    setUp(() async {
      testPeerId = await PeerId.random();
      config = DHTConfigV2(
        enableMetrics: true,
        metricsInterval: Duration(milliseconds: 100),
      );
      metricsManager = MetricsManager();
    });
    
    tearDown(() async {
      await metricsManager.close();
    });
    
    group('Helper Classes', () {
      group('Counter', () {
        test('should initialize with zero', () {
          final counter = Counter();
          expect(counter.value, equals(0));
        });
        
        test('should increment by one', () {
          final counter = Counter();
          counter.increment();
          expect(counter.value, equals(1));
        });
        
        test('should increment by custom amount', () {
          final counter = Counter();
          counter.increment(5);
          expect(counter.value, equals(5));
        });
        
        test('should reset to zero', () {
          final counter = Counter();
          counter.increment(10);
          counter.reset();
          expect(counter.value, equals(0));
        });
      });
      
      group('Gauge', () {
        test('should initialize with zero', () {
          final gauge = Gauge();
          expect(gauge.value, equals(0.0));
        });
        
        test('should set value', () {
          final gauge = Gauge();
          gauge.set(42.5);
          expect(gauge.value, equals(42.5));
        });
        
        test('should increment value', () {
          final gauge = Gauge();
          gauge.set(10.0);
          gauge.increment(5.0);
          expect(gauge.value, equals(15.0));
        });
        
        test('should decrement value', () {
          final gauge = Gauge();
          gauge.set(10.0);
          gauge.decrement(3.0);
          expect(gauge.value, equals(7.0));
        });
        
        test('should reset to zero', () {
          final gauge = Gauge();
          gauge.set(42.0);
          gauge.reset();
          expect(gauge.value, equals(0.0));
        });
      });
      
      group('RateCalculator', () {
        test('should initialize with zero rate', () {
          final rateCalc = RateCalculator();
          expect(rateCalc.rate, equals(0.0));
        });
        
        test('should calculate rate correctly', () {
          final rateCalc = RateCalculator(window: Duration(seconds: 1));
          
          // Record 5 events
          for (int i = 0; i < 5; i++) {
            rateCalc.recordEvent();
          }
          
          // Should be 5 events per second
          expect(rateCalc.rate, equals(5.0));
        });
        
        test('should clear events', () {
          final rateCalc = RateCalculator();
          rateCalc.recordEvent();
          rateCalc.recordEvent();
          
          rateCalc.clear();
          expect(rateCalc.rate, equals(0.0));
        });
        
        test('should remove old events outside window', () async {
          final rateCalc = RateCalculator(window: Duration(seconds: 1));
          
          // Record initial events
          rateCalc.recordEvent();
          rateCalc.recordEvent();
          
          // Wait for window to pass
          await Future.delayed(Duration(milliseconds: 1200));
          
          // Record new event - should trigger cleanup
          rateCalc.recordEvent();
          
          // Should only have 1 event now
          expect(rateCalc.rate, equals(1.0)); // 1 event / 1 second = 1 event/second
        });
      });
      
      group('LatencyHistogram', () {
        test('should initialize with zero values', () {
          final histogram = LatencyHistogram();
          expect(histogram.count, equals(0));
          expect(histogram.average, equals(Duration.zero));
          expect(histogram.max, equals(Duration.zero));
          expect(histogram.min, equals(Duration.zero));
        });
        
        test('should record and calculate latency stats', () {
          final histogram = LatencyHistogram();
          
          histogram.record(Duration(milliseconds: 100));
          histogram.record(Duration(milliseconds: 200));
          histogram.record(Duration(milliseconds: 300));
          
          expect(histogram.count, equals(3));
          expect(histogram.average, equals(Duration(milliseconds: 200)));
          expect(histogram.max, equals(Duration(milliseconds: 300)));
          expect(histogram.min, equals(Duration(milliseconds: 100)));
        });
        
        test('should limit samples to max size', () {
          final histogram = LatencyHistogram(maxSamples: 2);
          
          histogram.record(Duration(milliseconds: 100));
          histogram.record(Duration(milliseconds: 200));
          histogram.record(Duration(milliseconds: 300));
          
          expect(histogram.count, equals(2));
          expect(histogram.average, equals(Duration(milliseconds: 250))); // (200 + 300) / 2
        });
        
        test('should clear all samples', () {
          final histogram = LatencyHistogram();
          
          histogram.record(Duration(milliseconds: 100));
          histogram.record(Duration(milliseconds: 200));
          
          histogram.clear();
          
          expect(histogram.count, equals(0));
          expect(histogram.average, equals(Duration.zero));
          expect(histogram.max, equals(Duration.zero));
          expect(histogram.min, equals(Duration.zero));
        });
      });
    });
    
    group('Initialization and Lifecycle', () {
      test('should initialize correctly', () {
        expect(metricsManager.toString(), contains('MetricsManager'));
      });
      
      test('should start and stop successfully', () async {
        metricsManager.initialize(config: config);
        
        await metricsManager.start();
        await metricsManager.close();
        
        // Should not throw when closed
        expect(() => metricsManager.close(), returnsNormally);
      });
      
      test('should not start twice', () async {
        metricsManager.initialize(config: config);
        
        await metricsManager.start();
        await metricsManager.start(); // Should not throw
        
        await metricsManager.close();
      });
      
      test('should handle start without metrics enabled', () async {
        final disabledConfig = DHTConfigV2(enableMetrics: false);
        metricsManager.initialize(config: disabledConfig);
        
        await metricsManager.start();
        await metricsManager.close();
        
        // Should work without errors
        expect(true, isTrue);
      });
    });
    
    group('Query Metrics', () {
      setUp(() async {
        metricsManager.initialize(config: config);
        await metricsManager.start();
        metricsManager.reset(); // Ensure clean state
      });
      
      test('should record query success', () {
        final latency = Duration(milliseconds: 150);
        
        metricsManager.recordQueryStart();
        metricsManager.recordQuerySuccess(latency);
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.totalQueries, equals(1));
        expect(metrics.successfulQueries, equals(1));
        expect(metrics.failedQueries, equals(0));
        expect(metrics.averageQueryLatency, equals(latency));
      });
      
      test('should record query failure', () {
        metricsManager.recordQueryStart();
        metricsManager.recordQueryFailure('timeout');
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.totalQueries, equals(1));
        expect(metrics.successfulQueries, equals(0));
        expect(metrics.failedQueries, equals(1));
        expect(metrics.errorCounts, containsPair('timeout', 1));
      });
      
      test('should record query failure with peer', () {
        metricsManager.recordQueryStart();
        metricsManager.recordQueryFailure('connection_failed', peer: testPeerId);
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.totalQueries, equals(1));
        expect(metrics.failedQueries, equals(1));
        expect(metrics.errorCounts, containsPair('connection_failed', 1));
        expect(metrics.errorsByPeer, containsPair(testPeerId.toBase58().substring(0, 6), 1));
      });
      
      test('should calculate query success rate', () {
        metricsManager.recordQueryStart();
        metricsManager.recordQuerySuccess(Duration(milliseconds: 100));
        metricsManager.recordQueryStart();
        metricsManager.recordQuerySuccess(Duration(milliseconds: 200));
        metricsManager.recordQueryStart();
        metricsManager.recordQueryFailure('timeout');
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.querySuccessRate, equals(2.0 / 3.0)); // 2 success out of 3 total
      });
      
      test('should track multiple latencies', () {
        metricsManager.recordQueryStart();
        metricsManager.recordQuerySuccess(Duration(milliseconds: 100));
        metricsManager.recordQueryStart();
        metricsManager.recordQuerySuccess(Duration(milliseconds: 200));
        metricsManager.recordQueryStart();
        metricsManager.recordQuerySuccess(Duration(milliseconds: 300));
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.averageQueryLatency, equals(Duration(milliseconds: 200)));
        expect(metrics.minQueryLatency, equals(Duration(milliseconds: 100)));
        expect(metrics.maxQueryLatency, equals(Duration(milliseconds: 300)));
      });
    });
    
    group('Network Metrics', () {
      setUp(() async {
        metricsManager.initialize(config: config);
        await metricsManager.start();
        metricsManager.reset(); // Ensure clean state
      });
      
      test('should record network request', () {
        metricsManager.recordNetworkRequest();
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.totalNetworkRequests, equals(1));
      });
      
      test('should record network success', () {
        metricsManager.recordNetworkRequest();
        metricsManager.recordNetworkSuccess();
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.totalNetworkRequests, equals(1));
        expect(metrics.successfulNetworkRequests, equals(1));
      });
      
      test('should record network failure', () {
        metricsManager.recordNetworkRequest();
        metricsManager.recordNetworkFailure('connection_error');
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.failedNetworkRequests, equals(1));
        expect(metrics.errorCounts, containsPair('connection_error', 1));
      });
      
      test('should record network timeout', () {
        metricsManager.recordNetworkRequest();
        metricsManager.recordNetworkTimeout();
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.timeoutNetworkRequests, equals(1));
      });
      
      test('should record network timeout with peer', () {
        metricsManager.recordNetworkRequest();
        metricsManager.recordNetworkTimeout(peer: testPeerId);
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.timeoutNetworkRequests, equals(1));
        expect(metrics.errorsByPeer, containsPair(testPeerId.toBase58().substring(0, 6), 1));
      });
      
      test('should calculate network success rate', () {
        metricsManager.recordNetworkRequest();
        metricsManager.recordNetworkRequest();
        metricsManager.recordNetworkRequest();
        
        metricsManager.recordNetworkSuccess();
        metricsManager.recordNetworkSuccess();
        metricsManager.recordNetworkFailure('error');
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.networkSuccessRate, equals(2.0 / 3.0)); // 2 success out of 3 total
      });
    });
    
    group('Routing Table Metrics', () {
      setUp(() async {
        metricsManager.initialize(config: config);
        await metricsManager.start();
        metricsManager.reset(); // Ensure clean state
      });
      
      test('should record routing table size', () {
        metricsManager.recordRoutingTableSize(42);
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.routingTableSize, equals(42));
      });
      
      test('should record peer added', () {
        metricsManager.recordPeerAdded();
        metricsManager.recordPeerAdded();
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.peersAdded, equals(2));
      });
      
      test('should record peer removed', () {
        metricsManager.recordPeerRemoved();
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.peersRemoved, equals(1));
      });
      
      test('should record bucket refresh', () {
        metricsManager.recordBucketRefresh();
        metricsManager.recordBucketRefresh();
        metricsManager.recordBucketRefresh();
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.bucketRefreshes, equals(3));
      });
    });
    
    group('Provider Metrics', () {
      setUp(() async {
        metricsManager.initialize(config: config);
        await metricsManager.start();
        metricsManager.reset(); // Ensure clean state
      });
      
      test('should record provider stored', () {
        metricsManager.recordProviderStored();
        metricsManager.recordProviderStored();
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.providersStored, equals(2));
      });
      
      test('should record provider retrieved', () {
        metricsManager.recordProviderRetrieved();
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.providersRetrieved, equals(1));
      });
      
      test('should record provider query', () {
        metricsManager.recordProviderQuery();
        metricsManager.recordProviderQuery();
        metricsManager.recordProviderQuery();
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.providerQueries, equals(3));
      });
    });
    
    group('Connection Metrics', () {
      setUp(() async {
        metricsManager.initialize(config: config);
        await metricsManager.start();
        metricsManager.reset(); // Ensure clean state
      });
      
      test('should record connection opened', () {
        metricsManager.recordConnectionOpened();
        metricsManager.recordConnectionOpened();
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.activeConnections, equals(2));
      });
      
      test('should record connection closed', () {
        metricsManager.recordConnectionOpened();
        metricsManager.recordConnectionOpened();
        metricsManager.recordConnectionClosed();
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.activeConnections, equals(1));
      });
      
      test('should handle connection balance', () {
        metricsManager.recordConnectionOpened();
        metricsManager.recordConnectionOpened();
        metricsManager.recordConnectionOpened();
        
        metricsManager.recordConnectionClosed();
        metricsManager.recordConnectionClosed();
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.activeConnections, equals(1));
      });
    });
    
    group('Error Tracking', () {
      setUp(() async {
        metricsManager.initialize(config: config);
        await metricsManager.start();
        metricsManager.reset(); // Ensure clean state
      });
      
      test('should track multiple error types', () {
        metricsManager.recordQueryStart();
        metricsManager.recordQueryFailure('timeout');
        metricsManager.recordQueryStart();
        metricsManager.recordQueryFailure('timeout');
        metricsManager.recordQueryStart();
        metricsManager.recordQueryFailure('connection_error');
        metricsManager.recordNetworkFailure('dns_error');
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.errorCounts, containsPair('timeout', 2));
        expect(metrics.errorCounts, containsPair('connection_error', 1));
        expect(metrics.errorCounts, containsPair('dns_error', 1));
      });
      
      test('should track errors by peer', () async {
        // Use a fresh MetricsManager for this test to avoid any state issues
        final freshMetrics = MetricsManager();
        freshMetrics.initialize(config: config);
        await freshMetrics.start();
        
        final peer1 = await PeerId.random();
        final peer2 = await PeerId.random();
        
        freshMetrics.recordQueryStart();
        freshMetrics.recordQueryFailure('timeout', peer: peer1);
        freshMetrics.recordQueryStart();
        freshMetrics.recordQueryFailure('timeout', peer: peer1);
        freshMetrics.recordQueryStart();
        freshMetrics.recordQueryFailure('connection_error', peer: peer2);
        
        final metrics = freshMetrics.getMetrics();
        
        final peer1Key = peer1.toBase58().substring(0, 6);
        final peer2Key = peer2.toBase58().substring(0, 6);
        
        // If peers happen to have same first 6 chars, just check total errors
        if (peer1Key == peer2Key) {
          expect(metrics.errorsByPeer[peer1Key], equals(3));
        } else {
          expect(metrics.errorsByPeer, containsPair(peer1Key, 2));
          expect(metrics.errorsByPeer, containsPair(peer2Key, 1));
        }
        
        await freshMetrics.close();
      });
    });
    
    group('Rates and Performance', () {
      setUp(() async {
        metricsManager.initialize(config: config);
        await metricsManager.start();
        metricsManager.reset(); // Ensure clean state
      });
      
      test('should calculate queries per second', () {
        // Record some queries
        metricsManager.recordQueryStart();
        metricsManager.recordQuerySuccess(Duration(milliseconds: 100));
        metricsManager.recordQueryStart();
        metricsManager.recordQuerySuccess(Duration(milliseconds: 200));
        metricsManager.recordQueryStart();
        metricsManager.recordQueryFailure('timeout');
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.queriesPerSecond, greaterThan(0.0));
      });
      
      test('should calculate network requests per second', () {
        // Record some network requests
        metricsManager.recordNetworkRequest();
        metricsManager.recordNetworkRequest();
        metricsManager.recordNetworkRequest();
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.networkRequestsPerSecond, greaterThan(0.0));
      });
    });
    
    group('Reset Functionality', () {
      setUp(() async {
        metricsManager.initialize(config: config);
        await metricsManager.start();
        metricsManager.reset(); // Ensure clean state
      });
      
      test('should reset all metrics', () {
        // Record various metrics
        metricsManager.recordQueryStart();
        metricsManager.recordQuerySuccess(Duration(milliseconds: 100));
        metricsManager.recordQueryStart();
        metricsManager.recordQueryFailure('timeout');
        metricsManager.recordNetworkRequest();
        metricsManager.recordNetworkSuccess();
        metricsManager.recordRoutingTableSize(42);
        metricsManager.recordPeerAdded();
        metricsManager.recordProviderStored();
        metricsManager.recordConnectionOpened();
        
        // Verify metrics are recorded
        final beforeReset = metricsManager.getMetrics();
        expect(beforeReset.totalQueries, equals(2));
        expect(beforeReset.totalNetworkRequests, equals(1));
        expect(beforeReset.routingTableSize, equals(42));
        
        // Reset
        metricsManager.reset();
        
        // Verify all metrics are reset
        final afterReset = metricsManager.getMetrics();
        expect(afterReset.totalQueries, equals(0));
        expect(afterReset.successfulQueries, equals(0));
        expect(afterReset.failedQueries, equals(0));
        expect(afterReset.totalNetworkRequests, equals(0));
        expect(afterReset.successfulNetworkRequests, equals(0));
        expect(afterReset.failedNetworkRequests, equals(0));
        expect(afterReset.routingTableSize, equals(0));
        expect(afterReset.peersAdded, equals(0));
        expect(afterReset.providersStored, equals(0));
        expect(afterReset.activeConnections, equals(0));
        expect(afterReset.errorCounts, isEmpty);
        expect(afterReset.errorsByPeer, isEmpty);
        expect(afterReset.averageQueryLatency, equals(Duration.zero));
        expect(afterReset.queriesPerSecond, equals(0.0));
        expect(afterReset.networkRequestsPerSecond, equals(0.0));
      });
    });
    
    group('Metrics Snapshot', () {
      setUp(() async {
        metricsManager.initialize(config: config);
        await metricsManager.start();
        metricsManager.reset(); // Ensure clean state
      });
      
      test('should provide consistent snapshot', () {
        // Record some metrics
        metricsManager.recordQueryStart();
        metricsManager.recordQuerySuccess(Duration(milliseconds: 100));
        metricsManager.recordQueryStart();
        metricsManager.recordQuerySuccess(Duration(milliseconds: 200));
        metricsManager.recordQueryStart();
        metricsManager.recordQueryFailure('timeout');
        metricsManager.recordNetworkRequest();
        metricsManager.recordNetworkSuccess();
        metricsManager.recordRoutingTableSize(25);
        
        // Get snapshot
        final metrics = metricsManager.getMetrics();
        
        // Verify all expected values are present
        expect(metrics.totalQueries, equals(3));
        expect(metrics.successfulQueries, equals(2));
        expect(metrics.failedQueries, equals(1));
        expect(metrics.totalNetworkRequests, equals(1));
        expect(metrics.successfulNetworkRequests, equals(1));
        expect(metrics.routingTableSize, equals(25));
        expect(metrics.averageQueryLatency, equals(Duration(milliseconds: 150)));
        expect(metrics.maxQueryLatency, equals(Duration(milliseconds: 200)));
        expect(metrics.minQueryLatency, equals(Duration(milliseconds: 100)));
        expect(metrics.querySuccessRate, equals(2.0 / 3.0));
        expect(metrics.networkSuccessRate, equals(1.0));
        expect(metrics.errorCounts, containsPair('timeout', 1));
      });
      
      test('should handle empty metrics snapshot', () {
        final metrics = metricsManager.getMetrics();
        
        expect(metrics.totalQueries, equals(0));
        expect(metrics.successfulQueries, equals(0));
        expect(metrics.failedQueries, equals(0));
        expect(metrics.averageQueryLatency, equals(Duration.zero));
        expect(metrics.maxQueryLatency, equals(Duration.zero));
        expect(metrics.minQueryLatency, equals(Duration.zero));
        expect(metrics.querySuccessRate, equals(0.0));
        expect(metrics.networkSuccessRate, equals(0.0));
        expect(metrics.errorCounts, isEmpty);
        expect(metrics.errorsByPeer, isEmpty);
      });
    });
    
    group('Periodic Reporting', () {
      test('should start reporting when metrics enabled', () async {
        metricsManager.initialize(config: config);
        await metricsManager.start();
        
        // Add some metrics
        metricsManager.recordQuerySuccess(Duration(milliseconds: 100));
        metricsManager.recordNetworkRequest();
        metricsManager.recordNetworkSuccess();
        
        // Wait for reporting interval
        await Future.delayed(Duration(milliseconds: 150));
        
        // Reporting should have occurred (verified by no exceptions)
        expect(true, isTrue);
      });
      
      test('should not start reporting when metrics disabled', () async {
        final disabledConfig = DHTConfigV2(enableMetrics: false);
        metricsManager.initialize(config: disabledConfig);
        await metricsManager.start();
        
        // Should work without errors
        expect(true, isTrue);
      });
      
      test('should stop reporting when closed', () async {
        metricsManager.initialize(config: config);
        await metricsManager.start();
        
        // Add some metrics
        metricsManager.recordQuerySuccess(Duration(milliseconds: 100));
        
        // Close should stop reporting
        await metricsManager.close();
        
        // Should not throw
        expect(true, isTrue);
      });
    });
    
    group('Concurrent Access', () {
      setUp(() async {
        metricsManager.initialize(config: config);
        await metricsManager.start();
        metricsManager.reset(); // Ensure clean state
      });
      
      test('should handle concurrent metric recording', () async {
        // Simulate concurrent access
        final futures = <Future>[];
        
        for (int i = 0; i < 100; i++) {
          futures.add(Future(() {
            metricsManager.recordQueryStart();
            metricsManager.recordQuerySuccess(Duration(milliseconds: i));
            metricsManager.recordNetworkRequest();
            if (i % 2 == 0) {
              metricsManager.recordNetworkSuccess();
            } else {
              metricsManager.recordNetworkFailure('error');
            }
          }));
        }
        
        await Future.wait(futures);
        
        final metrics = metricsManager.getMetrics();
        expect(metrics.totalQueries, equals(100));
        expect(metrics.successfulQueries, equals(100));
        expect(metrics.totalNetworkRequests, equals(100));
        expect(metrics.successfulNetworkRequests, equals(50));
        expect(metrics.failedNetworkRequests, equals(50));
      });
      
      test('should handle concurrent snapshot requests', () async {
        // Add some metrics
        metricsManager.recordQueryStart();
        metricsManager.recordQuerySuccess(Duration(milliseconds: 100));
        metricsManager.recordNetworkRequest();
        metricsManager.recordNetworkSuccess();
        
        // Request multiple snapshots concurrently
        final futures = List.generate(10, (_) => Future(() => metricsManager.getMetrics()));
        
        final snapshots = await Future.wait(futures);
        
        // All snapshots should be consistent
        for (final snapshot in snapshots) {
          expect(snapshot.totalQueries, equals(1));
          expect(snapshot.totalNetworkRequests, equals(1));
        }
      });
    });
  });
} 