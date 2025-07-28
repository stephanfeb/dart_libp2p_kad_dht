# DHT v2 - Modular DHT Implementation

## Overview

DHT v2 is a complete reimplementation of the IPFS DHT with a focus on modularity, maintainability, and testability. This implementation addresses the key architectural issues identified in the original DHT while maintaining API compatibility.

## Architecture

### Core Components

```
┌─────────────────────────────────────────────────────────────┐
│                        IpfsDHTv2                           │
│                  (Main Interface)                          │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │  Network    │  │  Routing    │  │   Query     │         │
│  │  Manager    │  │  Manager    │  │  Manager    │         │
│  └─────────────┘  └─────────────┘  └─────────────┘         │
│                                                             │
│  ┌─────────────┐  ┌─────────────┐                          │
│  │  Protocol   │  │  Metrics    │                          │
│  │  Manager    │  │  Manager    │                          │
│  └─────────────┘  └─────────────┘                          │
├─────────────────────────────────────────────────────────────┤
│                 Configuration System                        │
│          ┌─────────────┐  ┌─────────────┐                  │
│          │ DHTConfigV2 │  │ DHTConfig   │                  │
│          │             │  │  Builder    │                  │
│          └─────────────┘  └─────────────┘                  │
├─────────────────────────────────────────────────────────────┤
│                  Error Handling                             │
│          ┌─────────────┐  ┌─────────────┐                  │
│          │ DHT         │  │ DHT Error   │                  │
│          │ Exceptions  │  │ Handler     │                  │
│          └─────────────┘  └─────────────┘                  │
└─────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

#### NetworkManager
- Message sending and receiving
- Connection management
- Network error handling
- Retry logic with exponential backoff
- Timeout management

#### RoutingManager
- Routing table management
- Peer addition and removal
- Bootstrap operations
- Periodic refresh
- Peer discovery

#### QueryManager
- Query coordination
- Peer lookups
- Value operations
- Provider operations
- Discovery operations

#### ProtocolManager
- Protocol message processing
- Request/response handling
- Message validation
- Protocol-specific logic

#### MetricsManager
- Performance monitoring
- Error tracking
- Rate calculation
- Periodic reporting

## Key Improvements

### 1. Modular Architecture
- **Clear separation of concerns**: Each component has a single responsibility
- **Testable components**: Components can be tested in isolation
- **Maintainable code**: Easy to understand and modify individual components

### 2. Unified Configuration
- **DHTConfigV2**: Comprehensive configuration with all options
- **DHTConfigBuilder**: Builder pattern for complex configurations
- **Backward compatibility**: Works with existing DHTOptions

### 3. Structured Error Handling
- **Custom exception hierarchy**: Specific exception types for different errors
- **Retry logic**: Automatic retry with exponential backoff
- **Graceful degradation**: System continues operating after errors

### 4. Built-in Observability
- **Comprehensive metrics**: Track all DHT operations
- **Performance monitoring**: Latency, throughput, and error rates
- **Health checks**: Monitor system health and routing table status

### 5. Testing-Friendly Design
- **Dependency injection**: Easy to mock dependencies for testing
- **Configurable timeouts**: Adjust timeouts for different test scenarios
- **Component isolation**: Test individual components independently

## Usage Examples

### Basic Usage

```dart
import 'package:dart_libp2p_kad_dht/src/dht/v2/dht_v2.dart';

// Create DHT with simple configuration
final dht = IpfsDHTv2(
  host: host,
  providerStore: providerStore,
  options: DHTOptions(
    mode: DHTMode.server,
    bucketSize: 20,
    filterLocalhostInResponses: false,
  ),
);

// Start the DHT
await dht.start();

// Bootstrap
await dht.bootstrap();

// Use DHT operations
final peer = await dht.findPeer(targetPeerId);
await dht.putValue(key, value);
final value = await dht.getValue(key);

// Check metrics
final metrics = dht.metrics;
print('Success rate: ${metrics.querySuccessRate}');

// Clean shutdown
await dht.close();
```

### Advanced Configuration

```dart
import 'package:dart_libp2p_kad_dht/src/dht/v2/config/dht_config.dart';

// Use builder pattern for complex configuration
final config = DHTConfigBuilder()
  .mode(DHTMode.server)
  .bucketSize(25)
  .filterLocalhost(false)
  .networkTimeout(Duration(seconds: 30))
  .queryTimeout(Duration(seconds: 60))
  .enableMetrics(true)
  .optimisticProvide(true)
  .build();

final dht = IpfsDHTv2(
  host: host,
  providerStore: providerStore,
  options: config.toOptions(),
);
```

### Testing Configuration

```dart
// Configuration optimized for testing
final testConfig = DHTConfigBuilder()
  .mode(DHTMode.server)
  .bucketSize(5)  // Smaller for testing
  .filterLocalhost(false)  // Allow localhost
  .networkTimeout(Duration(seconds: 5))  // Shorter timeouts
  .queryTimeout(Duration(seconds: 10))
  .enableMetrics(true)  // Monitor test behavior
  .build();
```

## API Compatibility

DHT v2 maintains full API compatibility with the original IpfsDHT:

```dart
// All existing methods work the same way
Future<AddrInfo?> findPeer(PeerId id, {RoutingOptions? options});
Future<List<AddrInfo>> getClosestPeers(PeerId target, {bool networkQueryEnabled = true});
Stream<AddrInfo> findProvidersAsync(CID cid, int count);
Future<Uint8List?> getValue(String key, [RoutingOptions? options]);
Future<void> putValue(String key, Uint8List value, [RoutingOptions? options]);
Future<void> provide(CID cid, bool announce);
```

## Migration Guide

### From Original DHT to DHT v2

1. **Replace import**:
   ```dart
   // Old
   import 'package:dart_libp2p_kad_dht/src/dht/dht.dart';
   
   // New
   import 'package:dart_libp2p_kad_dht/src/dht/v2/dht_v2.dart';
   ```

2. **Update constructor**:
   ```dart
   // Old
   final dht = IpfsDHT(host: host, providerStore: providerStore, options: options);
   
   // New
   final dht = IpfsDHTv2(host: host, providerStore: providerStore, options: options);
   ```

3. **All other code remains the same!**

### Benefits of Migration

- **Better error handling**: Structured exceptions and retry logic
- **Improved observability**: Built-in metrics and monitoring
- **Better testability**: Modular design and dependency injection
- **Enhanced performance**: Optimized query patterns and caching
- **Future-proof**: Easier to extend and maintain

## Monitoring and Metrics

DHT v2 provides comprehensive monitoring out of the box:

```dart
final metrics = dht.metrics;

// Query metrics
print('Total queries: ${metrics.totalQueries}');
print('Success rate: ${metrics.querySuccessRate * 100}%');
print('Average latency: ${metrics.averageQueryLatency.inMilliseconds}ms');

// Network metrics
print('Network requests: ${metrics.totalNetworkRequests}');
print('Network success rate: ${metrics.networkSuccessRate * 100}%');

// Routing table metrics
print('Routing table size: ${metrics.routingTableSize}');
print('Peers added: ${metrics.peersAdded}');

// Performance metrics
print('Queries per second: ${metrics.queriesPerSecond}');
print('Network requests per second: ${metrics.networkRequestsPerSecond}');
```

## Error Handling

DHT v2 provides structured error handling:

```dart
try {
  final peer = await dht.findPeer(targetPeerId);
} on DHTNetworkException catch (e) {
  print('Network error: ${e.message}');
  // Handle network-specific errors
} on DHTTimeoutException catch (e) {
  print('Timeout error: ${e.message}');
  // Handle timeout-specific errors
} on DHTException catch (e) {
  print('DHT error: ${e.message}');
  // Handle general DHT errors
}
```

## Performance Considerations

### Optimizations in DHT v2

1. **Parallel operations**: Multiple queries run concurrently
2. **Connection pooling**: Reuse connections where possible
3. **Smart caching**: Cache frequently accessed data
4. **Efficient routing**: Optimized routing table operations
5. **Reduced allocations**: Minimize memory allocations in hot paths

### Configuration for Performance

```dart
final config = DHTConfigBuilder()
  .concurrency(20)  // Higher concurrency for better performance
  .bucketSize(30)   // Larger buckets for better connectivity
  .optimisticProvide(true)  // Reduce latency for provide operations
  .build();
```

## Testing

DHT v2 is designed with testing in mind:

```dart
// Test-friendly configuration
final testConfig = DHTConfigBuilder()
  .filterLocalhost(false)  // Allow localhost addresses
  .networkTimeout(Duration(seconds: 1))  // Short timeouts for fast tests
  .enableMetrics(true)  // Monitor test behavior
  .build();

// Each component can be tested independently
final networkManager = NetworkManager(mockHost);
final routingManager = RoutingManager(mockHost, testOptions);
final queryManager = QueryManager();
```

## Development Status

DHT v2 is a complete architectural redesign that addresses the key issues in the original implementation:

- ✅ **Modular architecture**: Clear separation of concerns
- ✅ **Unified configuration**: Comprehensive configuration system
- ✅ **Structured error handling**: Custom exception hierarchy
- ✅ **Built-in observability**: Comprehensive metrics
- ✅ **Testing-friendly**: Dependency injection and isolation
- ✅ **API compatibility**: Drop-in replacement for original DHT

The implementation provides a solid foundation for building robust and maintainable DHT applications.

## Future Enhancements

Potential future improvements:

1. **Query optimization**: Advanced query routing strategies
2. **Peer diversity**: Enhanced peer diversity filters
3. **Protocol versioning**: Support for multiple protocol versions
4. **Persistent storage**: Optional persistent routing table storage
5. **Performance profiling**: Built-in performance profiling tools

## Contributing

When contributing to DHT v2, please follow these guidelines:

1. **Component isolation**: Keep components focused on single responsibilities
2. **Error handling**: Use structured exceptions and error handlers
3. **Testing**: Include comprehensive tests for new features
4. **Metrics**: Add appropriate metrics for monitoring
5. **Documentation**: Update documentation for new features

This architecture provides a solid foundation for building robust, maintainable, and testable DHT applications. 