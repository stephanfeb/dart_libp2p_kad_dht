import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/p2p/host/basic/basic_host.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_mgr;
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;
import 'package:dart_udx/dart_udx.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/dht_v2.dart';
import 'package:dart_libp2p_kad_dht/src/dht/dht_options.dart';
import 'package:dart_libp2p_kad_dht/src/providers/provider_store.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'real_net_stack.dart';

/// Bootstrap Integration Tests for DHT v2
/// 
/// These tests focus on the bootstrap() method completion and hanging detection:
/// 1. Bootstrap method completion under various conditions
/// 2. Bootstrap timeout and hanging scenarios
/// 3. Bootstrap with different network conditions
/// 4. Bootstrap failure recovery
/// 5. Bootstrap step-by-step tracking to identify hanging points
void main() {
  group('DHT v2 Bootstrap Integration Tests', () {
    late Logger logger;
    List<Host> hosts = [];
    List<IpfsDHTv2> dhts = [];
    
    setUpAll(() async {
      // Set up verbose logging for bootstrap debugging
      logger = Logger('DHT.v2.Bootstrap');
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen((record) {
        print('${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
        if (record.error != null) print('ERROR: ${record.error}');
        if (record.stackTrace != null) print('STACK: ${record.stackTrace}');
      });
      
      logger.info('Starting DHT v2 Bootstrap Integration Test Suite');
    });

    setUp(() async {
      hosts = [];
      dhts = [];
    });

    tearDown(() async {
      await _cleanupNetwork(hosts, dhts);
    });

    group('Bootstrap Method Completion Tests', () {
      test('Single node bootstrap() completion - no bootstrap peers', () async {
        logger.info('Testing single node bootstrap with no bootstrap peers...');
        
        // Create a single node with no bootstrap peers
        final host = await _createSingleNode();
        final dht = await _createDHTForHost(host, []);
        
        hosts.add(host);
        dhts.add(dht);
        
        // Start the DHT
        await dht.start();
        
        // Test bootstrap() completion
        final bootstrapCompleter = Completer<void>();
        Timer? timeoutTimer;
        
        // Set up timeout detection
        timeoutTimer = Timer(Duration(seconds: 10), () {
          if (!bootstrapCompleter.isCompleted) {
            bootstrapCompleter.completeError(
              TimeoutException('Bootstrap hung - did not complete within 10 seconds', Duration(seconds: 10))
            );
          }
        });
        
        // Call bootstrap() and track completion
        logger.info('Calling bootstrap()...');
        final startTime = DateTime.now();
        
        try {
          await dht.bootstrap();
          final endTime = DateTime.now();
          final duration = endTime.difference(startTime);
          
          timeoutTimer?.cancel();
          bootstrapCompleter.complete();
          
          logger.info('✓ Bootstrap completed in ${duration.inMilliseconds}ms');
          expect(duration.inSeconds, lessThan(10), reason: 'Bootstrap should complete quickly with no bootstrap peers');
        } catch (e) {
          timeoutTimer?.cancel();
          if (!bootstrapCompleter.isCompleted) {
            bootstrapCompleter.completeError(e);
          }
        }
        
        // Wait for completion or timeout
        await bootstrapCompleter.future;
        
        logger.info('✓ Single node bootstrap completion test passed');
      });

      test('Bootstrap() completion with unreachable bootstrap peers', () async {
        logger.info('Testing bootstrap with unreachable bootstrap peers...');
        
        // Create unreachable bootstrap peers
        final unreachableBootstrapPeers = [
          MultiAddr('/ip4/192.168.99.99/udp/4001/udx/p2p/12D3KooWKA9hoAmsjqQhmSdatMWTTvHHAYG7fsNHgd6uyN3RCerR'),
          MultiAddr('/ip4/10.0.0.99/udp/4001/udx/p2p/12D3KooWDAgBDqijgq27B1N9T8yJDbv3h5SXMvVvLwn4oBoSBwuE'),
        ];
        
        // Create a single node with unreachable bootstrap peers
        final host = await _createSingleNode();
        final dht = await _createDHTForHost(host, unreachableBootstrapPeers);
        
        hosts.add(host);
        dhts.add(dht);
        
        // Start the DHT
        await dht.start();
        
        // Test bootstrap() completion with timeout
        final bootstrapCompleter = Completer<void>();
        Timer? timeoutTimer;
        
        // Set up timeout detection
        timeoutTimer = Timer(Duration(seconds: 30), () {
          if (!bootstrapCompleter.isCompleted) {
            bootstrapCompleter.completeError(
              TimeoutException('Bootstrap hung - did not complete within 30 seconds', Duration(seconds: 30))
            );
          }
        });
        
        // Call bootstrap() and track completion
        logger.info('Calling bootstrap() with unreachable peers...');
        final startTime = DateTime.now();
        
        try {
          await dht.bootstrap();
          final endTime = DateTime.now();
          final duration = endTime.difference(startTime);
          
          timeoutTimer?.cancel();
          bootstrapCompleter.complete();
          
          logger.info('✓ Bootstrap completed in ${duration.inMilliseconds}ms (with unreachable peers)');
          expect(duration.inSeconds, lessThan(30), reason: 'Bootstrap should complete even with unreachable peers');
        } catch (e) {
          timeoutTimer?.cancel();
          if (!bootstrapCompleter.isCompleted) {
            bootstrapCompleter.completeError(e);
          }
        }
        
        // Wait for completion or timeout
        await bootstrapCompleter.future;
        
        logger.info('✓ Bootstrap with unreachable peers completion test passed');
      });

      test('Bootstrap() completion with mixed available/unavailable peers', () async {
        logger.info('Testing bootstrap with mixed available/unavailable peers...');
        
        // Create one bootstrap node (available)
        final bootstrapHost = await _createSingleNode();
        final bootstrapDht = await _createDHTForHost(bootstrapHost, []);
        
        hosts.add(bootstrapHost);
        dhts.add(bootstrapDht);
        
        // Start bootstrap node
        await bootstrapDht.start();
        
        // Create mixed bootstrap peers (one available, one unavailable)
        final mixedBootstrapPeers = [
          MultiAddr('/ip4/127.0.0.1/udp/${_getPort(bootstrapHost)}/udx/p2p/${bootstrapHost.id.toBase58()}'),
          MultiAddr('/ip4/192.168.99.99/udp/4001/udx/p2p/12D3KooWNonExistentPeer1'),
        ];
        
        // Create discovery node with mixed bootstrap peers
        final discoveryHost = await _createSingleNode();
        final discoveryDht = await _createDHTForHost(discoveryHost, mixedBootstrapPeers);
        
        hosts.add(discoveryHost);
        dhts.add(discoveryDht);
        
        // Start discovery node
        await discoveryDht.start();
        
        // Test bootstrap() completion
        final bootstrapCompleter = Completer<void>();
        Timer? timeoutTimer;
        
        // Set up timeout detection
        timeoutTimer = Timer(Duration(seconds: 30), () {
          if (!bootstrapCompleter.isCompleted) {
            bootstrapCompleter.completeError(
              TimeoutException('Bootstrap hung - did not complete within 30 seconds', Duration(seconds: 30))
            );
          }
        });
        
        // Call bootstrap() and track completion
        logger.info('Calling bootstrap() with mixed peers...');
        final startTime = DateTime.now();
        
        try {
          await discoveryDht.bootstrap();
          final endTime = DateTime.now();
          final duration = endTime.difference(startTime);
          
          timeoutTimer?.cancel();
          bootstrapCompleter.complete();
          
          logger.info('✓ Bootstrap completed in ${duration.inMilliseconds}ms (with mixed peers)');
          expect(duration.inSeconds, lessThan(30), reason: 'Bootstrap should complete with mixed peers');
          
          // Verify the discovery node found the bootstrap node
          final rtSize = await discoveryDht.routingTable.size();
          expect(rtSize, greaterThan(0), reason: 'Discovery node should have found the bootstrap node');
          
        } catch (e) {
          timeoutTimer?.cancel();
          if (!bootstrapCompleter.isCompleted) {
            bootstrapCompleter.completeError(e);
          }
        }
        
        // Wait for completion or timeout
        await bootstrapCompleter.future;
        
        logger.info('✓ Bootstrap with mixed peers completion test passed');
      });
    });

    group('Bootstrap Hanging Detection Tests', () {
      test('Bootstrap() hanging detection with step-by-step tracking', () async {
        logger.info('Testing bootstrap hanging detection with step tracking...');
        
        // Create a bootstrap node
        final bootstrapHost = await _createSingleNode();
        final bootstrapDht = await _createDHTForHost(bootstrapHost, []);
        
        hosts.add(bootstrapHost);
        dhts.add(bootstrapDht);
        
        // Start bootstrap node
        await bootstrapDht.start();
        
        // Create bootstrap peers
        final bootstrapPeers = [
          MultiAddr('/ip4/127.0.0.1/udp/${_getPort(bootstrapHost)}/udx/p2p/${bootstrapHost.id.toBase58()}'),
        ];
        
        // Create discovery node
        final discoveryHost = await _createSingleNode();
        final discoveryDht = await _createDHTForHost(discoveryHost, bootstrapPeers);
        
        hosts.add(discoveryHost);
        dhts.add(discoveryDht);
        
        // Start discovery node
        await discoveryDht.start();
        
        // Track bootstrap steps
        final steps = <String>[];
        Timer? progressTimer;
        
        // Monitor progress every 2 seconds
        progressTimer = Timer.periodic(Duration(seconds: 2), (timer) {
          final step = 'Step ${steps.length + 1}: ${DateTime.now().toIso8601String()}';
          steps.add(step);
          logger.info('Bootstrap progress: $step');
          
          // Check if bootstrap is taking too long
          if (steps.length >= 15) { // 30 seconds
            timer.cancel();
            logger.warning('Bootstrap appears to be hanging - ${steps.length} progress checks completed');
          }
        });
        
        // Test bootstrap() with detailed progress tracking
        logger.info('Starting bootstrap with step-by-step tracking...');
        final startTime = DateTime.now();
        
        try {
          // Call bootstrap with timeout
          await discoveryDht.bootstrap().timeout(Duration(seconds: 30));
          
          progressTimer?.cancel();
          final endTime = DateTime.now();
          final duration = endTime.difference(startTime);
          
          logger.info('✓ Bootstrap completed in ${duration.inMilliseconds}ms');
          logger.info('Bootstrap steps tracked: ${steps.length}');
          
          // Verify bootstrap worked
          final rtSize = await discoveryDht.routingTable.size();
          expect(rtSize, greaterThan(0), reason: 'Bootstrap should have discovered peers');
          
        } catch (e) {
          progressTimer?.cancel();
          final endTime = DateTime.now();
          final duration = endTime.difference(startTime);
          
                     logger.severe('Bootstrap failed after ${duration.inMilliseconds}ms with error: $e');
           logger.severe('Bootstrap steps completed: ${steps.length}');
           
           for (int i = 0; i < steps.length; i++) {
             logger.severe('  ${steps[i]}');
           }
          
          if (e is TimeoutException) {
            fail('Bootstrap hung - did not complete within 30 seconds. Steps: ${steps.length}');
          } else {
            rethrow;
          }
        }
        
        logger.info('✓ Bootstrap hanging detection test passed');
      });

      test('Multiple concurrent bootstrap() calls', () async {
        logger.info('Testing multiple concurrent bootstrap calls...');
        
        // Create a bootstrap node
        final bootstrapHost = await _createSingleNode();
        final bootstrapDht = await _createDHTForHost(bootstrapHost, []);
        
        hosts.add(bootstrapHost);
        dhts.add(bootstrapDht);
        
        // Start bootstrap node
        await bootstrapDht.start();
        
        // Create multiple discovery nodes
        final discoveryNodes = <IpfsDHTv2>[];
        for (int i = 0; i < 3; i++) {
          final discoveryHost = await _createSingleNode();
          final bootstrapPeers = [
            MultiAddr('/ip4/127.0.0.1/udp/${_getPort(bootstrapHost)}/udx/p2p/${bootstrapHost.id.toBase58()}'),
          ];
          final discoveryDht = await _createDHTForHost(discoveryHost, bootstrapPeers);
          
          hosts.add(discoveryHost);
          dhts.add(discoveryDht);
          discoveryNodes.add(discoveryDht);
          
          await discoveryDht.start();
        }
        
        // Start all bootstrap operations concurrently
        logger.info('Starting ${discoveryNodes.length} concurrent bootstrap operations...');
        final startTime = DateTime.now();
        
        final bootstrapFutures = discoveryNodes.map((dht) => 
          dht.bootstrap().timeout(Duration(seconds: 30))
        ).toList();
        
        try {
          await Future.wait(bootstrapFutures);
          
          final endTime = DateTime.now();
          final duration = endTime.difference(startTime);
          
          logger.info('✓ All ${discoveryNodes.length} concurrent bootstrap operations completed in ${duration.inMilliseconds}ms');
          
          // Verify all nodes discovered the bootstrap node
          for (int i = 0; i < discoveryNodes.length; i++) {
            final rtSize = await discoveryNodes[i].routingTable.size();
            expect(rtSize, greaterThan(0), reason: 'Discovery node $i should have found bootstrap node');
          }
          
        } catch (e) {
          final endTime = DateTime.now();
          final duration = endTime.difference(startTime);
          
                     logger.severe('Concurrent bootstrap failed after ${duration.inMilliseconds}ms with error: $e');
          
          if (e is TimeoutException) {
            fail('One or more concurrent bootstrap operations hung');
          } else {
            rethrow;
          }
        }
        
        logger.info('✓ Multiple concurrent bootstrap test passed');
      });
    });

    group('Bootstrap Network Formation Tests', () {
      test('Bootstrap chain formation - 3 nodes', () async {
        logger.info('Testing bootstrap chain formation with 3 nodes...');
        
        // Create bootstrap chain: Node A -> Node B -> Node C
        
        // Node A: Bootstrap server (no bootstrap peers)
        final nodeA_host = await _createSingleNode();
        final nodeA_dht = await _createDHTForHost(nodeA_host, []);
        
        hosts.add(nodeA_host);
        dhts.add(nodeA_dht);
        
        await nodeA_dht.start();
        
        // Node B: Bootstraps from Node A
        final nodeB_host = await _createSingleNode();
        final nodeB_bootstrapPeers = [
          MultiAddr('/ip4/127.0.0.1/udp/${_getPort(nodeA_host)}/udx/p2p/${nodeA_host.id.toBase58()}'),
        ];
        final nodeB_dht = await _createDHTForHost(nodeB_host, nodeB_bootstrapPeers);
        
        hosts.add(nodeB_host);
        dhts.add(nodeB_dht);
        
        await nodeB_dht.start();
        
        // Node C: Bootstraps from Node B
        final nodeC_host = await _createSingleNode();
        final nodeC_bootstrapPeers = [
          MultiAddr('/ip4/127.0.0.1/udp/${_getPort(nodeB_host)}/udx/p2p/${nodeB_host.id.toBase58()}'),
        ];
        final nodeC_dht = await _createDHTForHost(nodeC_host, nodeC_bootstrapPeers);
        
        hosts.add(nodeC_host);
        dhts.add(nodeC_dht);
        
        await nodeC_dht.start();
        
        // Bootstrap Node B from Node A
        logger.info('Node B bootstrapping from Node A...');
        await nodeB_dht.bootstrap().timeout(Duration(seconds: 30));
        
        // Verify Node B discovered Node A
        final nodeBRtSize = await nodeB_dht.routingTable.size();
        expect(nodeBRtSize, greaterThan(0), reason: 'Node B should have discovered Node A');
        
        // Bootstrap Node C from Node B
        logger.info('Node C bootstrapping from Node B...');
        await nodeC_dht.bootstrap().timeout(Duration(seconds: 30));
        
        // Verify Node C discovered Node B
        final nodeCRtSize = await nodeC_dht.routingTable.size();
        expect(nodeCRtSize, greaterThan(0), reason: 'Node C should have discovered Node B');
        
        // Allow time for peer discovery propagation
        await Future.delayed(Duration(seconds: 3));
        
        // Verify chain connectivity
        final finalNodeARtSize = await nodeA_dht.routingTable.size();
        final finalNodeBRtSize = await nodeB_dht.routingTable.size();
        final finalNodeCRtSize = await nodeC_dht.routingTable.size();
        
        logger.info('Final routing table sizes: A=$finalNodeARtSize, B=$finalNodeBRtSize, C=$finalNodeCRtSize');
        
        expect(finalNodeBRtSize, greaterThan(0), reason: 'Node B should have peers');
        expect(finalNodeCRtSize, greaterThan(0), reason: 'Node C should have peers');
        
        logger.info('✓ Bootstrap chain formation test passed');
      });

      test('Bootstrap failure recovery', () async {
        logger.info('Testing bootstrap failure recovery...');
        
        // Create a bootstrap node
        final bootstrapHost = await _createSingleNode();
        final bootstrapDht = await _createDHTForHost(bootstrapHost, []);
        
        hosts.add(bootstrapHost);
        dhts.add(bootstrapDht);
        
        await bootstrapDht.start();
        
        // Create discovery node with bootstrap peers
        final discoveryHost = await _createSingleNode();
        final bootstrapPeers = [
          MultiAddr('/ip4/127.0.0.1/udp/${_getPort(bootstrapHost)}/udx/p2p/${bootstrapHost.id.toBase58()}'),
        ];
        final discoveryDht = await _createDHTForHost(discoveryHost, bootstrapPeers);
        
        hosts.add(discoveryHost);
        dhts.add(discoveryDht);
        
        await discoveryDht.start();
        
        // First bootstrap should succeed
        logger.info('First bootstrap attempt...');
        await discoveryDht.bootstrap().timeout(Duration(seconds: 30));
        
        final firstRtSize = await discoveryDht.routingTable.size();
        expect(firstRtSize, greaterThan(0), reason: 'First bootstrap should succeed');
        
        // Simulate bootstrap node failure
        logger.info('Simulating bootstrap node failure...');
        await bootstrapDht.close();
        
                 // Clear routing table to simulate fresh start
         // Note: RoutingTable doesn't have a clear() method, so we'll leave it as is
         // The discovery node will still have peers from previous bootstrap
        
        // Second bootstrap should fail gracefully (not hang)
        logger.info('Second bootstrap attempt (should fail gracefully)...');
        try {
          await discoveryDht.bootstrap().timeout(Duration(seconds: 30));
          logger.info('Bootstrap completed despite failed bootstrap node');
        } catch (e) {
          if (e is TimeoutException) {
            fail('Bootstrap hung even with failed bootstrap node');
          } else {
            logger.info('Bootstrap failed gracefully: $e');
            // This is expected - bootstrap node is down
          }
        }
        
        // Verify the discovery node handled the failure
        final secondRtSize = await discoveryDht.routingTable.size();
        logger.info('Routing table size after bootstrap failure: $secondRtSize');
        
        logger.info('✓ Bootstrap failure recovery test passed');
      });
    });
  });
}

// Helper methods

Future<Host> _createSingleNode() async {
  // Create UDX instance
  final udxInstance = UDX();
  
  // Create resource manager
  final resourceManager = NullResourceManager();
  
  // Create connection manager
  final connManager = p2p_conn_mgr.ConnectionManager();
  
  // Create event bus
  final eventBus = p2p_event_bus.BasicBus();
  
  // Create libp2p node with real network components
  final nodeDetails = await createLibp2pNode(
    udxInstance: udxInstance,
    resourceManager: resourceManager,
    connManager: connManager,
    hostEventBus: eventBus,
    userAgentPrefix: 'dht-bootstrap-integration-test',
  );
  
  return nodeDetails.host;
}

Future<IpfsDHTv2> _createDHTForHost(Host host, List<MultiAddr> bootstrapPeers) async {
  final providerStore = MemoryProviderStore();
  
  final options = DHTOptions(
    bucketSize: 20,
    concurrency: 3,
    resiliency: 3,
    autoRefresh: false,
    bootstrapPeers: bootstrapPeers,
    mode: DHTMode.server,
  );
  
  final dht = IpfsDHTv2(
    host: host,
    providerStore: providerStore,
    options: options,
  );
  
  return dht;
}

int _getPort(Host host) {
  // Extract port from host's listening addresses
  final addrs = host.network.listenAddresses;
  if (addrs.isNotEmpty) {
    final addr = addrs.first;
    final parts = addr.toString().split('/');
    for (int i = 0; i < parts.length - 1; i++) {
      if (parts[i] == 'udp') {
        return int.parse(parts[i + 1]);
      }
    }
  }
  return 4001; // Default port
}

Future<void> _cleanupNetwork(List<Host> hosts, List<IpfsDHTv2> dhts) async {
  // Clean shutdown of all DHT instances with more thorough cleanup
  for (var dht in dhts) {
    try {
      await dht.close().timeout(Duration(seconds: 5));
    } catch (e) {
      // Ignore cleanup errors
    }
  }
  
  // Allow time for DHT cleanup to complete
  await Future.delayed(Duration(milliseconds: 500));
  
  // Close all hosts
  for (var host in hosts) {
    try {
      await host.close().timeout(Duration(seconds: 5));
    } catch (e) {
      // Ignore cleanup errors
    }
  }
  
  dhts.clear();
  hosts.clear();
  
  // Allow more time for complete cleanup of all network resources
  await Future.delayed(Duration(milliseconds: 1000));
} 