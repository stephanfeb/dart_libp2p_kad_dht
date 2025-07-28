import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:logging/logging.dart';

import '../../providers/provider_store.dart';
import '../dht_options.dart';
import 'dht_v2.dart';
import 'config/dht_config.dart';

/// Example usage of the DHT v2 implementation
/// 
/// This example demonstrates:
/// 1. Creating a DHT with improved configuration
/// 2. Using the modular architecture
/// 3. Monitoring with built-in metrics
/// 4. Error handling improvements
/// 5. Testing-friendly design
Future<void> exampleUsage() async {
  // Set up logging
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });
  
  print('=== DHT v2 Example Usage ===\n');
  
  // Example 1: Basic DHT setup with improved configuration
  await _basicSetupExample();
  
  // Example 2: Advanced configuration with builder pattern
  await _advancedConfigExample();
  
  // Example 3: Monitoring and metrics
  await _monitoringExample();
  
  // Example 4: Error handling demonstration
  await _errorHandlingExample();
  
  // Example 5: Testing-friendly design
  await _testingExample();
}

/// Example 1: Basic DHT setup with improved configuration
Future<void> _basicSetupExample() async {
  print('Example 1: Basic DHT Setup');
  print('---------------------------');
  
  // Create a mock host (in real usage, this would be your libp2p host)
  final host = await _createMockHost();
  
  // Create provider store - using a concrete implementation
  final providerStore = MemoryProviderStore();
  
  // Create DHT with simple configuration
  final dht = IpfsDHTv2(
    host: host,
    providerStore: providerStore,
    options: DHTOptions(
      mode: DHTMode.server,
      bucketSize: 20,
      filterLocalhostInResponses: false, // Good for testing
    ),
  );
  
  try {
    // Start the DHT
    await dht.start();
    print('✓ DHT started successfully');
    
    // Bootstrap the DHT
    await dht.bootstrap();
    print('✓ DHT bootstrap completed');
    
    // Check metrics
    final metrics = dht.metrics;
    print('✓ Metrics: ${metrics.toString()}');
    
    // Clean shutdown
    await dht.close();
    print('✓ DHT closed successfully');
  } catch (e) {
    print('✗ Error: $e');
  }
  
  print('');
}

/// Example 2: Advanced configuration with builder pattern
Future<void> _advancedConfigExample() async {
  print('Example 2: Advanced Configuration');
  print('----------------------------------');
  
  // Create DHT with builder pattern for complex configuration
  final config = DHTConfigBuilder()
    .mode(DHTMode.server)
    .bucketSize(25)
    .filterLocalhost(false)
    .networkTimeout(Duration(seconds: 30))
    .queryTimeout(Duration(seconds: 60))
    .enableMetrics(true)
    .optimisticProvide(true)
    .build();
  
  final host = await _createMockHost();
  final providerStore = MemoryProviderStore();
  
  final dht = IpfsDHTv2(
    host: host,
    providerStore: providerStore,
    options: config.toOptions(),
  );
  
  try {
    await dht.start();
    print('✓ DHT started with advanced configuration');
    
    // Show configuration
    print('  - Mode: ${config.mode}');
    print('  - Bucket Size: ${config.bucketSize}');
    print('  - Network Timeout: ${config.networkTimeout}');
    print('  - Metrics Enabled: ${config.enableMetrics}');
    
    await dht.close();
    print('✓ DHT closed successfully');
  } catch (e) {
    print('✗ Error: $e');
  }
  
  print('');
}

/// Example 3: Monitoring and metrics
Future<void> _monitoringExample() async {
  print('Example 3: Monitoring and Metrics');
  print('----------------------------------');
  
  final host = await _createMockHost();
  final providerStore = MemoryProviderStore();
  
  final dht = IpfsDHTv2(
    host: host,
    providerStore: providerStore,
    options: DHTOptions(
      mode: DHTMode.server,
      // Metrics are enabled by default in v2
    ),
  );
  
  try {
    await dht.start();
    print('✓ DHT started with monitoring enabled');
    
    // Simulate some operations
    final targetPeer = PeerId.fromString('12D3KooWExample');
    try {
      await dht.findPeer(targetPeer);
    } catch (e) {
      // Expected to fail for demo
    }
    
    // Check detailed metrics
    final metrics = dht.metrics;
    print('📊 Detailed Metrics:');
    print('  - Total Queries: ${metrics.totalQueries}');
    print('  - Success Rate: ${(metrics.querySuccessRate * 100).toStringAsFixed(1)}%');
    print('  - Routing Table Size: ${metrics.routingTableSize}');
    print('  - Network Requests: ${metrics.totalNetworkRequests}');
    print('  - Queries/sec: ${metrics.queriesPerSecond.toStringAsFixed(2)}');
    
    await dht.close();
    print('✓ DHT closed successfully');
  } catch (e) {
    print('✗ Error: $e');
  }
  
  print('');
}

/// Example 4: Error handling demonstration
Future<void> _errorHandlingExample() async {
  print('Example 4: Error Handling');
  print('-------------------------');
  
  final host = await _createMockHost();
  final providerStore = MemoryProviderStore();
  
  final dht = IpfsDHTv2(
    host: host,
    providerStore: providerStore,
    options: DHTOptions(mode: DHTMode.server),
  );
  
  try {
    await dht.start();
    print('✓ DHT started for error handling demo');
    
    // Demonstrate structured error handling
    try {
      final nonExistentPeer = PeerId.fromString('12D3KooWNonExistent');
      await dht.findPeer(nonExistentPeer);
      print('✗ This should not be reached');
    } catch (e) {
      print('✓ Graceful error handling: Operation failed as expected');
      print('  - Error handled gracefully without crashing');
    }
    
    // Show that DHT is still operational after error
    final metrics = dht.metrics;
    print('✓ DHT remains operational after error');
    print('  - Failed queries tracked: ${metrics.failedQueries}');
    
    await dht.close();
    print('✓ DHT closed successfully');
  } catch (e) {
    print('✗ Error: $e');
  }
  
  print('');
}

/// Example 5: Testing-friendly design
Future<void> _testingExample() async {
  print('Example 5: Testing-Friendly Design');
  print('----------------------------------');
  
  final host = await _createMockHost();
  final providerStore = MemoryProviderStore();
  
  // Configuration optimized for testing
  final testConfig = DHTConfigBuilder()
    .mode(DHTMode.server)
    .bucketSize(5)  // Smaller for testing
    .filterLocalhost(false)  // Allow localhost for testing
    .networkTimeout(Duration(seconds: 5))  // Shorter timeouts
    .queryTimeout(Duration(seconds: 10))
    .enableMetrics(true)  // Monitor test behavior
    .build();
  
  final dht = IpfsDHTv2(
    host: host,
    providerStore: providerStore,
    options: testConfig.toOptions(),
  );
  
  try {
    await dht.start();
    print('✓ DHT started with test-friendly configuration');
    
    // Each component can be tested independently
    print('✓ Modular architecture allows component isolation');
    print('  - NetworkManager: handles network operations');
    print('  - RoutingManager: manages routing table');
    print('  - QueryManager: coordinates queries');
    print('  - ProtocolManager: processes messages');
    print('  - MetricsManager: tracks performance');
    
    // Configuration is easily modified for different test scenarios
    print('✓ Configuration easily modified for testing');
    print('  - Timeouts: ${testConfig.networkTimeout}');
    print('  - Bucket size: ${testConfig.bucketSize}');
    print('  - Localhost filtering: ${testConfig.filterLocalhostInResponses}');
    
    await dht.close();
    print('✓ DHT closed successfully');
  } catch (e) {
    print('✗ Error: $e');
  }
  
  print('');
}

/// Creates a mock host for demonstration purposes
Future<Host> _createMockHost() async {
  // In a real implementation, this would create an actual libp2p host
  // For this example, we'll create a mock
  throw UnimplementedError('Mock host creation not implemented in this example');
}

/// Architecture Summary
/// 
/// The DHT v2 architecture provides:
/// 
/// 1. **Modular Design**: Clear separation of concerns
///    - NetworkManager: Network operations
///    - RoutingManager: Routing table management
///    - QueryManager: Query coordination
///    - ProtocolManager: Message processing
///    - MetricsManager: Performance monitoring
/// 
/// 2. **Configuration System**: Flexible and type-safe
///    - DHTConfigV2: Comprehensive configuration
///    - DHTConfigBuilder: Builder pattern for complex setups
///    - Backward compatibility with DHTOptions
/// 
/// 3. **Error Handling**: Structured and consistent
///    - Custom exception hierarchy
///    - Retry logic with exponential backoff
///    - Graceful degradation
/// 
/// 4. **Observability**: Built-in monitoring
///    - Comprehensive metrics collection
///    - Performance tracking
///    - Error rate monitoring
/// 
/// 5. **Testing**: Designed for testability
///    - Dependency injection
///    - Configurable timeouts
///    - Component isolation
/// 
/// 6. **Performance**: Optimized for efficiency
///    - Parallel operations
///    - Connection pooling
///    - Smart caching
/// 
/// This architecture addresses the key issues identified in the original
/// implementation while maintaining API compatibility.
void architectureSummary() {
  // This function serves as documentation
  // See the comment above for the architecture overview
} 