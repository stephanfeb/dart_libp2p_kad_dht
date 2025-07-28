import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:logging/logging.dart';

import '../dht_options.dart';
import '../../providers/provider_store.dart';
import 'dht_v2.dart';
import 'config/dht_config.dart';
import 'config/bootstrap_config.dart';

/// Example demonstrating enhanced bootstrap functionality in DHT v2
/// 
/// This example shows:
/// - Basic bootstrap with default peers
/// - Advanced bootstrap with custom peers
/// - Bootstrap with connectivity verification
/// - Bootstrap monitoring and health checks
void main() async {
  // Setup logging
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  print('=== DHT v2 Enhanced Bootstrap Examples ===\n');

  // Example 1: Basic Bootstrap with Default Peers
  await _basicBootstrapExample();
  
  // Example 2: Advanced Bootstrap with Custom Configuration
  await _advancedBootstrapExample();
  
  // Example 3: Bootstrap with Health Monitoring
  await _bootstrapHealthMonitoringExample();
  
  // Example 4: Bootstrap Connectivity Verification
  await _bootstrapConnectivityExample();
}

/// Example 1: Basic Bootstrap with Default Peers
Future<void> _basicBootstrapExample() async {
  print('Example 1: Basic Bootstrap with Default Peers');
  print('-----------------------------------------------');
  
  try {
    // Create a mock host (in real usage, this would be your libp2p host)
    final host = await _createMockHost();
    final providerStore = MemoryProviderStore();
    
    // Create DHT with default bootstrap configuration
    final dht = IpfsDHTv2(
      host: host,
      providerStore: providerStore,
      options: DHTOptions(
        mode: DHTMode.server,
        bucketSize: 20,
        filterLocalhostInResponses: false,
        // No explicit bootstrap peers - will use defaults
      ),
    );
    
    // Start the DHT
    await dht.start();
    print('✓ DHT started successfully');
    
    // Bootstrap with default peers
    await dht.bootstrap();
    print('✓ Bootstrap completed with default peers');
    
    // Check bootstrap results
    final routingTableSize = await dht.getRoutingTableSize();
    print('✓ Routing table size after bootstrap: $routingTableSize');
    
    // Check health
    final isHealthy = await dht.isRoutingTableHealthy();
    print('✓ Network health: ${isHealthy ? "Healthy" : "Unhealthy"}');
    
    await dht.close();
    print('✓ DHT closed successfully\n');
    
  } catch (e) {
    print('✗ Error: $e\n');
  }
}

/// Example 2: Advanced Bootstrap with Custom Configuration
Future<void> _advancedBootstrapExample() async {
  print('Example 2: Advanced Bootstrap with Custom Configuration');
  print('-----------------------------------------------------');
  
  try {
    final host = await _createMockHost();
    final providerStore = MemoryProviderStore();
    
    // Create custom bootstrap configuration
    final customBootstrapPeers = [
      // Add custom bootstrap peers
      MultiAddr('/ip4/127.0.0.1/tcp/4001/p2p/QmCustomPeer1'),
      MultiAddr('/ip4/127.0.0.1/tcp/4002/p2p/QmCustomPeer2'),
      // Plus default peers
      ...BootstrapConfig.getDefaultBootstrapPeers(),
    ];
    
    // Create DHT with advanced configuration
    final config = DHTConfigBuilder()
      .mode(DHTMode.server)
      .bucketSize(25)
      .filterLocalhost(false)
      .networkTimeout(Duration(seconds: 30))
      .queryTimeout(Duration(seconds: 60))
      .bootstrapPeers(customBootstrapPeers)
      .build();
    
    final dht = IpfsDHTv2(
      host: host,
      providerStore: providerStore,
      options: config.toOptions(),
    );
    
    await dht.start();
    print('✓ DHT started with custom configuration');
    
    // Bootstrap with custom peers
    await dht.bootstrap();
    print('✓ Bootstrap completed with custom bootstrap peers');
    
    // Monitor bootstrap results
    final routingTableSize = await dht.getRoutingTableSize();
    final metrics = dht.metrics;
    
    print('✓ Routing table size: $routingTableSize');
    print('✓ Bootstrap metrics: ${metrics.toString()}');
    
    await dht.close();
    print('✓ DHT closed successfully\n');
    
  } catch (e) {
    print('✗ Error: $e\n');
  }
}

/// Example 3: Bootstrap with Health Monitoring
Future<void> _bootstrapHealthMonitoringExample() async {
  print('Example 3: Bootstrap with Health Monitoring');
  print('------------------------------------------');
  
  try {
    final host = await _createMockHost();
    final providerStore = MemoryProviderStore();
    
    final dht = IpfsDHTv2(
      host: host,
      providerStore: providerStore,
      options: DHTOptions(
        mode: DHTMode.server,
        bucketSize: 20,
        autoRefresh: true, // Enable automatic refresh
      ),
    );
    
    await dht.start();
    print('✓ DHT started with health monitoring enabled');
    
    // Bootstrap with periodic health checks
    await dht.bootstrap(periodicRefreshInterval: Duration(minutes: 5));
    print('✓ Bootstrap completed with periodic refresh enabled');
    
    // Monitor health over time
    for (int i = 0; i < 3; i++) {
      await Future.delayed(Duration(seconds: 2));
      
      final routingTableSize = await dht.getRoutingTableSize();
      final isHealthy = await dht.isRoutingTableHealthy();
      final stats = await dht.getRoutingTableStatistics();
      
      print('✓ Health check ${i + 1}:');
      print('  - Routing table size: $routingTableSize');
      print('  - Network health: ${isHealthy ? "Healthy" : "Unhealthy"}');
      print('  - Statistics: ${stats.toString()}');
    }
    
    await dht.close();
    print('✓ DHT closed successfully\n');
    
  } catch (e) {
    print('✗ Error: $e\n');
  }
}

/// Example 4: Bootstrap Connectivity Verification
Future<void> _bootstrapConnectivityExample() async {
  print('Example 4: Bootstrap Connectivity Verification');
  print('--------------------------------------------');
  
  try {
    final host = await _createMockHost();
    final providerStore = MemoryProviderStore();
    
    final dht = IpfsDHTv2(
      host: host,
      providerStore: providerStore,
      options: DHTOptions(
        mode: DHTMode.server,
        bucketSize: 20,
        maxRetryAttempts: 3,
        retryInitialBackoff: Duration(milliseconds: 500),
        retryMaxBackoff: Duration(seconds: 5),
      ),
    );
    
    await dht.start();
    print('✓ DHT started with connectivity verification');
    
    // Bootstrap with connectivity verification
    final stopwatch = Stopwatch()..start();
    await dht.bootstrap();
    stopwatch.stop();
    
    print('✓ Bootstrap completed in ${stopwatch.elapsed.inMilliseconds}ms');
    
    // Verify connectivity to bootstrap peers
    final bootstrapPeers = await dht.getBootstrapPeers();
    print('✓ Available bootstrap peers: ${bootstrapPeers.length}');
    
    var connectedPeers = 0;
    for (final peerInfo in bootstrapPeers.take(3)) {
      try {
        // Try to find each peer (this verifies connectivity)
        final found = await dht.findPeer(peerInfo.id);
        if (found != null) {
          connectedPeers++;
          print('  ✓ Connected to peer: ${peerInfo.id.toBase58().substring(0, 8)}');
        } else {
          print('  ✗ Failed to connect to peer: ${peerInfo.id.toBase58().substring(0, 8)}');
        }
      } catch (e) {
        print('  ✗ Error connecting to peer: $e');
      }
    }
    
    print('✓ Successfully connected to $connectedPeers peers');
    
    await dht.close();
    print('✓ DHT closed successfully\n');
    
  } catch (e) {
    print('✗ Error: $e\n');
  }
}

/// Creates a mock host for testing
Future<Host> _createMockHost() async {
  // In a real implementation, this would create a proper libp2p host
  // For this example, we'll create a mock that demonstrates the interface
  throw UnimplementedError('Mock host creation not implemented in this example');
}

/// Memory-based provider store for testing
class MemoryProviderStore implements ProviderStore {
  final Map<String, List<AddrInfo>> _providers = {};
  
  @override
  Future<void> addProvider(dynamic cid, AddrInfo provider) async {
    final key = cid.toString();
    _providers.putIfAbsent(key, () => []).add(provider);
  }
  
  @override
  Future<List<AddrInfo>> getProviders(dynamic cid) async {
    return _providers[cid.toString()] ?? [];
  }
  
  @override
  Future<void> removeProvider(dynamic cid, AddrInfo provider) async {
    final key = cid.toString();
    _providers[key]?.remove(provider);
  }
  
  @override
  Future<void> clear() async {
    _providers.clear();
  }
  
  @override
  Future<void> close() async {
    // No-op for memory store
  }
  
  @override
  Future<void> start() async {
    // No-op for memory store
  }
} 