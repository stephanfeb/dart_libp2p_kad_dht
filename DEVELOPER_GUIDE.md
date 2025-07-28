# Dart libp2p Kademlia DHT Developer Guide

A comprehensive guide for P2P application developers using the Dart libp2p Kademlia DHT implementation.

## Table of Contents

1. [Quick Start](#quick-start)
2. [Core Concepts](#core-concepts)
3. [API Reference](#api-reference)
4. [Configuration Guide](#configuration-guide)
5. [Usage Patterns](#usage-patterns)
6. [Integration Examples](#integration-examples)
7. [Testing and Development](#testing-and-development)
8. [Advanced Topics](#advanced-topics)
9. [Troubleshooting](#troubleshooting)
10. [Performance and Optimization](#performance-and-optimization)

## Quick Start

### Installation

Add the DHT package to your `pubspec.yaml`:

```yaml
dependencies:
  dart_libp2p_kad_dht: ^1.0.2
  dart_libp2p: # Your libp2p dependency
  dcid: # For content addressing
```

### Basic DHT Node

Here's a minimal example to get you started:

```dart
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:dart_libp2p/dart_libp2p.dart';

Future<void> main() async {
  // Create a libp2p host (see libp2p documentation for details)
  final host = await createLibp2pHost();
  
  // Create a provider store for content routing
  final providerStore = MemoryProviderStore();
  
  // Create and start the DHT
  final dht = IpfsDHT(
    host: host,
    providerStore: providerStore,
    options: const DHTOptions(
      mode: DHTMode.auto, // Automatically switch between client/server
    ),
  );
  
  await dht.start();
  await dht.bootstrap(); // Connect to the network
  
  // Your P2P application logic here
  
  // Cleanup
  await dht.close();
  await host.close();
}
```

### Key Operations

```dart
// Find a peer by ID
final peerInfo = await dht.findPeer(targetPeerId);

// Publish that you provide content
await dht.provide(contentCid, true); // true = announce to network

// Find providers of content
await for (final provider in dht.findProvidersAsync(contentCid, 10)) {
  print('Found provider: ${provider.id}');
}

// Store a value
await dht.putValue('my-key', utf8.encode('my-value'));

// Retrieve a value
final value = await dht.getValue('my-key');
```

## Core Concepts

### Kademlia DHT Fundamentals

The Kademlia DHT is a distributed hash table that enables:

- **Peer Discovery**: Find peers by their ID
- **Content Routing**: Find who has specific content
- **Value Storage**: Distributed key-value storage
- **Network Topology**: Self-organizing network structure

### Network Modes

The DHT operates in three modes:

- **Client Mode**: Can query but doesn't respond to requests (mobile-friendly)
- **Server Mode**: Full participant, handles incoming requests
- **Auto Mode**: Automatically switches based on network conditions

### Routing Table

The DHT maintains a routing table of known peers organized by XOR distance:

```dart
// Get routing table information
final tableSize = await dht.routingTable.size();
final closestPeers = await dht.getClosestPeers(targetPeerId);
```

### Provider Records

Provider records announce that a peer has specific content:

```dart
// Announce you have content
await dht.provide(CID.fromString('QmExample...'), true);

// Find who has content
final providers = dht.findProvidersAsync(CID.fromString('QmExample...'), 5);
```

## API Reference

### IpfsDHT Class

The main DHT interface implementing both `Routing` and `Discovery` interfaces.

#### Constructor

```dart
IpfsDHT({
  required Host host,
  required ProviderStore providerStore,
  DHTOptions? options,
  NamespacedValidator? validator,
})
```

#### Core Methods

##### Lifecycle Management

```dart
// Start the DHT
Future<void> start()

// Bootstrap into the network
Future<void> bootstrap({
  bool quickConnectOnly = false,
  Duration? periodicRefreshInterval,
})

// Close and cleanup
Future<void> close()
```

##### Peer Discovery

```dart
// Find a peer by ID
Future<AddrInfo?> findPeer(PeerId id, {RoutingOptions? options})

// Get closest peers to a target
Future<List<AddrInfo>> getClosestPeers(PeerId target)
```

##### Content Routing

```dart
// Announce you provide content
Future<void> provide(CID cid, bool announce)

// Find providers of content
Stream<AddrInfo> findProvidersAsync(CID cid, int count)
```

##### Value Storage

```dart
// Store a key-value pair
Future<void> putValue(String key, Uint8List value, {RoutingOptions? options})

// Retrieve a value
Future<Uint8List?> getValue(String key, RoutingOptions? options)

// Search for values (returns stream of all found values)
Stream<Uint8List> searchValue(String key, RoutingOptions? options)
```

##### Discovery Interface

```dart
// Advertise in a namespace
Future<Duration> advertise(String ns, [List<DiscoveryOption> options])

// Find peers in a namespace
Future<Stream<AddrInfo>> findPeers(String ns, [List<DiscoveryOption> options])
```

### DHTOptions Configuration

```dart
class DHTOptions {
  final DHTMode mode;                    // Client/Server/Auto
  final int bucketSize;                  // K-bucket size (default: 20)
  final int concurrency;                 // Query concurrency (default: 10)
  final int resiliency;                  // Required responses (default: 3)
  final Duration provideValidity;        // Provider record TTL
  final Duration providerAddrTTL;        // Provider address TTL
  final bool autoRefresh;                // Auto-refresh routing table
  final List<MultiAddr>? bootstrapPeers; // Bootstrap peer addresses
  final int maxRetryAttempts;            // Message retry limit
  final Duration retryInitialBackoff;    // Initial retry delay
  final Duration retryMaxBackoff;        // Maximum retry delay
  final double retryBackoffFactor;       // Backoff multiplier
  final bool filterLocalhostInResponses; // Filter localhost addresses
}
```

## Configuration Guide

### Basic Configuration

#### Client Node (Mobile/Resource-Constrained)

```dart
final dht = IpfsDHT(
  host: host,
  providerStore: providerStore,
  options: const DHTOptions(
    mode: DHTMode.client,        // Client-only mode
    bucketSize: 15,              // Smaller routing table
    concurrency: 5,              // Lower concurrency
    resiliency: 2,               // Fewer required responses
    maxRetryAttempts: 2,         // Fewer retries
  ),
);
```

#### Server Node (Bootstrap/Infrastructure)

```dart
final dht = IpfsDHT(
  host: host,
  providerStore: providerStore,
  options: const DHTOptions(
    mode: DHTMode.server,        // Always server mode
    bucketSize: 30,              // Larger routing table
    concurrency: 15,             // Higher concurrency
    resiliency: 5,               // More required responses
    autoRefresh: true,           // Keep routing table fresh
  ),
);
```

### Functional Configuration Pattern

Use the new functional configuration for more flexibility:

```dart
final dhtOptions = <DHTOption>[
  mode(DHTMode.auto),
  bucketSize(25),
  concurrency(12),
  resiliency(4),
  
  // Bootstrap configuration
  bootstrapPeers([
    AddrInfo(peerId1, [MultiAddr('/ip4/1.2.3.4/tcp/4001')]),
    AddrInfo(peerId2, [MultiAddr('/ip4/5.6.7.8/tcp/4001')]),
  ]),
  
  // Performance tuning
  maxDhtMessageRetries(5),
  dhtMessageRetryInitialBackoff(Duration(milliseconds: 250)),
  dhtMessageRetryMaxBackoff(Duration(seconds: 15)),
  
  // Advanced features
  enableOptimisticProvide(),
  optimisticProvideJobsPoolSize(100),
];

final dht = await DHT.new_(host, providerStore, dhtOptions);
```

### Bootstrap Configuration

Bootstrap peers are essential for joining the network:

```dart
// Method 1: Via DHTOptions
final dht = IpfsDHT(
  host: host,
  providerStore: providerStore,
  options: DHTOptions(
    bootstrapPeers: [
      MultiAddr('/ip4/104.131.131.82/tcp/4001/p2p/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ'),
      MultiAddr('/ip4/104.236.179.241/tcp/4001/p2p/QmSoLPppuBtQSGwKDZT2M73ULpjvfd3aZ6ha4oFGL1KrGM'),
    ],
  ),
);

// Method 2: Via functional options
final dhtOptions = <DHTOption>[
  bootstrapPeers([
    AddrInfo(
      PeerId.fromString('QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ'),
      [MultiAddr('/ip4/104.131.131.82/tcp/4001')],
    ),
  ]),
];
```

## Usage Patterns

### Peer Discovery Pattern

```dart
class PeerDiscoveryService {
  final IpfsDHT dht;
  
  PeerDiscoveryService(this.dht);
  
  Future<AddrInfo?> findPeerWithRetry(PeerId peerId, {int maxAttempts = 3}) async {
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final peerInfo = await dht.findPeer(peerId);
        if (peerInfo != null) {
          return peerInfo;
        }
      } catch (e) {
        if (attempt == maxAttempts) rethrow;
        await Future.delayed(Duration(seconds: attempt));
      }
    }
    return null;
  }
  
  Stream<AddrInfo> discoverPeersInNamespace(String namespace) async* {
    final stream = await dht.findPeers(namespace);
    await for (final peer in stream) {
      yield peer;
    }
  }
}
```

### Content Routing Pattern

```dart
class ContentRouter {
  final IpfsDHT dht;
  
  ContentRouter(this.dht);
  
  // Announce content availability
  Future<void> announceContent(CID contentId) async {
    await dht.provide(contentId, true);
    print('Announced availability of content: $contentId');
  }
  
  // Find content providers
  Future<List<AddrInfo>> findContentProviders(CID contentId, {int maxProviders = 10}) async {
    final providers = <AddrInfo>[];
    final stream = dht.findProvidersAsync(contentId, maxProviders);
    
    await for (final provider in stream) {
      providers.add(provider);
      if (providers.length >= maxProviders) break;
    }
    
    return providers;
  }
  
  // Content discovery with timeout
  Future<List<AddrInfo>> findContentWithTimeout(
    CID contentId, 
    Duration timeout, {
    int maxProviders = 5,
  }) async {
    final providers = <AddrInfo>[];
    final stream = dht.findProvidersAsync(contentId, maxProviders);
    
    await for (final provider in stream.timeout(timeout)) {
      providers.add(provider);
    }
    
    return providers;
  }
}
```

### Distributed Storage Pattern

```dart
class DistributedStorage {
  final IpfsDHT dht;
  
  DistributedStorage(this.dht);
  
  Future<void> store(String key, String value) async {
    final valueBytes = utf8.encode(value);
    await dht.putValue(key, valueBytes);
    print('Stored value for key: $key');
  }
  
  Future<String?> retrieve(String key) async {
    final valueBytes = await dht.getValue(key);
    if (valueBytes != null) {
      return utf8.decode(valueBytes);
    }
    return null;
  }
  
  // Retrieve with multiple attempts to find the best value
  Future<String?> retrieveBest(String key) async {
    final values = <String>[];
    final stream = dht.searchValue(key, null);
    
    await for (final valueBytes in stream) {
      values.add(utf8.decode(valueBytes));
    }
    
    // Return the most recent or apply custom selection logic
    return values.isNotEmpty ? values.last : null;
  }
}
```

## Integration Examples

### Basic P2P Application

```dart
import 'dart:async';
import 'dart:convert';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';

class BasicP2PApp {
  late final Host host;
  late final IpfsDHT dht;
  late final ProviderStore providerStore;
  
  Future<void> initialize() async {
    // Create libp2p host (implementation depends on your setup)
    host = await createLibp2pHost();
    
    // Create provider store
    providerStore = MemoryProviderStore();
    
    // Create and configure DHT
    dht = IpfsDHT(
      host: host,
      providerStore: providerStore,
      options: const DHTOptions(
        mode: DHTMode.auto,
        bucketSize: 20,
        concurrency: 10,
      ),
    );
    
    await dht.start();
    await dht.bootstrap();
    
    print('P2P application initialized');
    print('Peer ID: ${host.id}');
    print('Listening on: ${host.addrs}');
  }
  
  Future<void> announceService(String serviceName) async {
    // Use the service name as a namespace for discovery
    await dht.advertise(serviceName);
    print('Announced service: $serviceName');
  }
  
  Future<List<AddrInfo>> findServicePeers(String serviceName) async {
    final peers = <AddrInfo>[];
    final stream = await dht.findPeers(serviceName);
    
    await for (final peer in stream) {
      peers.add(peer);
      if (peers.length >= 10) break; // Limit results
    }
    
    return peers;
  }
  
  Future<void> shutdown() async {
    await dht.close();
    await providerStore.close();
    await host.close();
  }
}
```

### Mobile-Optimized P2P App

```dart
class MobileP2PApp {
  late final IpfsDHT dht;
  Timer? _refreshTimer;
  
  Future<void> initialize() async {
    final host = await createMobileOptimizedHost();
    final providerStore = MemoryProviderStore();
    
    // Mobile-optimized configuration
    final dhtOptions = <DHTOption>[
      mode(DHTMode.client),           // Client-only for battery life
      bucketSize(15),                 // Smaller routing table
      concurrency(5),                 // Lower network usage
      resiliency(2),                  // Fewer required responses
      maxDhtMessageRetries(2),        // Fewer retries
      dhtMessageRetryMaxBackoff(Duration(seconds: 10)),
      
      // Conservative bootstrap
      bootstrapPeers([
        AddrInfo(
          PeerId.fromString('QmBootstrapPeer1...'),
          [MultiAddr('/ip4/1.2.3.4/tcp/4001')],
        ),
      ]),
    ];
    
    dht = await DHT.new_(host, providerStore, dhtOptions);
    await dht.start();
    
    // Periodic refresh for mobile (less frequent)
    _refreshTimer = Timer.periodic(Duration(minutes: 10), (_) {
      dht.bootstrap(quickConnectOnly: true);
    });
  }
  
  Future<void> shutdown() async {
    _refreshTimer?.cancel();
    await dht.close();
  }
}
```

### High-Performance Server Node

```dart
class ServerNode {
  late final IpfsDHT dht;
  
  Future<void> initialize() async {
    final host = await createServerHost();
    final providerStore = MemoryProviderStore();
    
    // High-performance server configuration
    final dhtOptions = <DHTOption>[
      mode(DHTMode.server),
      bucketSize(30),                 // Large routing table
      concurrency(20),                // High concurrency
      resiliency(8),                  // More thorough queries
      lookupCheckConcurrency(512),    // High lookup concurrency
      
      // Optimistic provide for better performance
      enableOptimisticProvide(),
      optimisticProvideJobsPoolSize(200),
      
      // Aggressive retry strategy
      maxDhtMessageRetries(5),
      dhtMessageRetryInitialBackoff(Duration(milliseconds: 100)),
      dhtMessageRetryMaxBackoff(Duration(seconds: 30)),
      
      // Large bootstrap peer list
      bootstrapPeers(await loadBootstrapPeers()),
    ];
    
    dht = await DHT.new_(host, providerStore, dhtOptions);
    await dht.start();
    
    // Continuous bootstrap with periodic refresh
    await dht.bootstrap(
      quickConnectOnly: false,
      periodicRefreshInterval: Duration(minutes: 5),
    );
  }
  
  Future<List<AddrInfo>> loadBootstrapPeers() async {
    // Load from configuration file or hardcoded list
    return [
      AddrInfo(PeerId.fromString('Qm...'), [MultiAddr('/ip4/...')]),
      // ... more bootstrap peers
    ];
  }
}
```

## Testing and Development

### Unit Testing with Mocks

```dart
import 'package:test/test.dart';
import 'package:mockito/mockito.dart';

class MockHost extends Mock implements Host {}
class MockProviderStore extends Mock implements ProviderStore {}

void main() {
  group('DHT Tests', () {
    late MockHost mockHost;
    late MockProviderStore mockProviderStore;
    late IpfsDHT dht;
    
    setUp(() {
      mockHost = MockHost();
      mockProviderStore = MockProviderStore();
      
      when(mockHost.id).thenReturn(PeerId.fromString('QmTest...'));
      when(mockHost.addrs).thenReturn([MultiAddr('/ip4/127.0.0.1/tcp/0')]);
      
      dht = IpfsDHT(
        host: mockHost,
        providerStore: mockProviderStore,
        options: const DHTOptions(mode: DHTMode.client),
      );
    });
    
    test('should initialize correctly', () async {
      await dht.start();
      expect(dht.routingTable, isNotNull);
    });
    
    tearDown(() async {
      await dht.close();
    });
  });
}
```

### Integration Testing

```dart
import 'package:test/test.dart';
import '../test/real_net_stack.dart'; // Your real network utilities

void main() {
  group('DHT Integration Tests', () {
    test('peer discovery between two nodes', () async {
      // Create two real nodes
      final node1 = await createLibp2pNode();
      final node2 = await createLibp2pNode();
      
      final dht1 = IpfsDHT(
        host: node1.host,
        providerStore: MemoryProviderStore(),
        options: const DHTOptions(mode: DHTMode.server),
      );
      
      final dht2 = IpfsDHT(
        host: node2.host,
        providerStore: MemoryProviderStore(),
        options: DHTOptions(
          mode: DHTMode.server,
          bootstrapPeers: [
            MultiAddr('/ip4/127.0.0.1/tcp/${node1.port}/p2p/${node1.peerId}'),
          ],
        ),
      );
      
      await dht1.start();
      await dht2.start();
      await dht2.bootstrap();
      
      // Test peer discovery
      final foundPeer = await dht2.findPeer(node1.peerId);
      expect(foundPeer, isNotNull);
      expect(foundPeer!.id, equals(node1.peerId));
      
      // Cleanup
      await dht1.close();
      await dht2.close();
      await node1.host.close();
      await node2.host.close();
    });
  });
}
```

## Advanced Topics

### Custom Record Validators

```dart
class CustomValidator implements Validator {
  @override
  void validate(String key, Uint8List value) {
    // Custom validation logic
    if (key.startsWith('/myapp/')) {
      final decoded = utf8.decode(value);
      final json = jsonDecode(decoded);
      
      // Validate JSON structure
      if (!json.containsKey('timestamp') || !json.containsKey('signature')) {
        throw ValidationException('Invalid record format');
      }
      
      // Validate timestamp (not too old)
      final timestamp = DateTime.fromMillisecondsSinceEpoch(json['timestamp']);
      if (DateTime.now().difference(timestamp) > Duration(hours: 24)) {
        throw ValidationException('Record too old');
      }
      
      // Validate signature (implement your crypto logic)
      if (!verifySignature(json)) {
        throw ValidationException('Invalid signature');
      }
    }
  }
  
  @override
  Future<int> select(String key, List<Uint8List> values) async {
    // Select the best value (e.g., most recent)
    int bestIndex = 0;
    int latestTimestamp = 0;
    
    for (int i = 0; i < values.length; i++) {
      try {
        final decoded = utf8.decode(values[i]);
        final json = jsonDecode(decoded);
        final timestamp = json['timestamp'] as int;
        
        if (timestamp > latestTimestamp) {
          latestTimestamp = timestamp;
          bestIndex = i;
        }
      } catch (e) {
        // Skip invalid values
      }
    }
    
    return bestIndex;
  }
  
  bool verifySignature(Map<String, dynamic> json) {
    // Implement your signature verification
    return true; // Placeholder
  }
}

// Use custom validator
final validator = NamespacedValidator();
validator.addValidator('myapp', CustomValidator());

final dht = IpfsDHT(
  host: host,
  providerStore: providerStore,
  validator: validator,
);
```

### Network Size Estimation

```dart
class NetworkMonitor {
  final IpfsDHT dht;
  
  NetworkMonitor(this.dht);
  
  Future<NetworkStats> getNetworkStats() async {
    final estimator = dht.nsEstimator;
    final routingTable = dht.routingTable;
    
    final networkSize = await estimator.estimate();
    final tableSize = await routingTable.size();
    final peers = await routingTable.listPeers();
    
    return NetworkStats(
      estimatedNetworkSize: networkSize,
      routingTableSize: tableSize,
      connectedPeers: peers.length,
      averageLatency: _calculateAverageLatency(peers),
    );
  }
  
  Duration _calculateAverageLatency(List<DhtPeerInfo> peers) {
    if (peers.isEmpty) return Duration.zero;
    
    final totalLatency = peers
        .map((p) => p.latency ?? Duration.zero)
        .fold(Duration.zero, (a, b) => a + b);
    
    return Duration(
      microseconds: totalLatency.inMicroseconds ~/ peers.length,
    );
  }
}

class NetworkStats {
  final int estimatedNetworkSize;
  final int routingTableSize;
  final int connectedPeers;
  final Duration averageLatency;
  
  NetworkStats({
    required this.estimatedNetworkSize,
    required this.routingTableSize,
    required this.connectedPeers,
    required this.averageLatency,
  });
}
```

### Error Handling and Retry Strategies

```dart
class RobustDHTClient {
  final IpfsDHT dht;
  
  RobustDHTClient(this.dht);
  
  Future<T> withRetry<T>(
    Future<T> Function() operation, {
    int maxAttempts = 3,
    Duration baseDelay = const Duration(seconds: 1),
    double backoffFactor = 2.0,
  }) async {
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await operation();
      } catch (e) {
        if (attempt == maxAttempts) rethrow;
        
        if (e is MaxRetriesExceededException) {
          // DHT already did its retries, don't retry again
          rethrow;
        }
        
        final delay = Duration(
          milliseconds: (baseDelay.inMilliseconds * 
                        math.pow(backoffFactor, attempt - 1)).round(),
        );
        
        print('Attempt $attempt failed: $e. Retrying in $delay...');
        await Future.delayed(delay);
      }
    }
    
    throw StateError('Should not reach here');
  }
  
  Future<AddrInfo?> findPeerRobust(PeerId peerId) async {
    return await withRetry(() => dht.findPeer(peerId));
  }
  
  Future<void> putValueRobust(String key, Uint8List value) async {
    return await withRetry(() => dht.putValue(key, value));
  }
  
  Future<Uint8List?> getValueRobust(String key) async {
    return await withRetry(() => dht.getValue(key));
  }
}
```

## Troubleshooting

### Common Issues

#### 1. Bootstrap Failures

**Problem**: DHT fails to bootstrap or connect to the network.

**Solutions**:
```dart
// Check bootstrap peer connectivity
final bootstrapPeers = [
  MultiAddr('/ip4/104.131.131.82/tcp/4001/p2p/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ'),
];

// Test connectivity to bootstrap peers
for (final addr in bootstrapPeers) {
  try {
    final peerId = PeerId.fromString(addr.valueForProtocol('p2p')!);
    await host.connect(AddrInfo(peerId, [addr.decapsulate('p2p')!]));
    print('Successfully connected to bootstrap peer: $peerId');
  } catch (e) {
    print('Failed to connect to bootstrap peer: $e');
  }
}
```

#### 2. Peer Discovery Issues

**Problem**: `findPeer()` returns null or times out.

**Solutions**:
```dart
// Check routing table size
final tableSize = await dht.routingTable.size();
if (tableSize < 5) {
  print('Routing table too small ($tableSize peers). Bootstrapping...');
  await dht.bootstrap();
}

// Use multiple discovery methods
Future<AddrInfo?> findPeerMultiMethod(PeerId peerId) async {
  // Method 1: Direct DHT lookup
  var result = await dht.findPeer(peerId);
  if (result != null) return result;
  
  // Method 2: Check local peerstore
  final peerInfo = await host.peerStore.getPeer(peerId);
  if (peerInfo != null && peerInfo.addrs.isNotEmpty) {
    return AddrInfo(peerId, peerInfo.addrs.toList());
  }
  
  // Method 3: Bootstrap and retry
  await dht.bootstrap();
  return await dht.findPeer(peerId);
}
```

#### 3. High Memory Usage

**Problem**: DHT consumes too much memory on mobile devices.

**Solutions**:
```dart
// Use mobile-optimized configuration
final mobileOptions = <DHTOption>[
  mode(DHTMode.client),           // Client-only mode
  bucketSize(10),                 // Smaller buckets
  maxRoutingTableSize(200),       // Limit total peers
  concurrency(3),                 // Lower concurrency
  resiliency(2),                  // Fewer required responses
  disableAutoRefresh(),           // Manual refresh control
];

// Implement periodic cleanup
Timer.periodic(Duration(minutes: 30), (_) async {
  // Force garbage collection of expired records
  await providerStore.cleanup();
  
  // Optionally restart DHT if memory usage is too high
  if (shouldRestartDHT()) {
    await dht.close();
    dht = await DHT.new_(host, providerStore, mobileOptions);
    await dht.start();
  }
});
```

### Debugging Tools

#### Enable Detailed Logging

```dart
import 'package:logging/logging.dart';

void setupDHTLogging() {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
    if (record.error != null) {
      print('ERROR: ${record.error}');
    }
    if (record.stackTrace != null) {
      print('STACKTRACE: ${record.stackTrace}');
    }
  });
}
```

#### DHT Health Check

```dart
class DHTHealthChecker {
  final IpfsDHT dht;
  
  DHTHealthChecker(this.dht);
  
  Future<HealthReport> checkHealth() async {
    final report = HealthReport();
    
    // Check routing table
    report.routingTableSize = await dht.routingTable.size();
    report.isHealthy = report.routingTableSize > 0;
    
    // Test basic operations
    try {
      // Test self-lookup
      final selfPeer = await dht.findPeer(dht.host().id);
      report.canFindSelf = selfPeer != null;
    } catch (e) {
      report.canFindSelf = false;
      report.errors.add('Self-lookup failed: $e');
    }
    
    // Test value storage
    try {
      final testKey = 'health-check-${DateTime.now().millisecondsSinceEpoch}';
      final testValue = utf8.encode('test-value');
      
      await dht.putValue(testKey, testValue);
      final retrieved = await dht.getValue(testKey);
      
      report.canStoreValues = retrieved != null && 
          String.fromCharCodes(retrieved) == String.fromCharCodes(testValue);
    } catch (e) {
      report.canStoreValues = false;
      report.errors.add('Value storage test failed: $e');
    }
    
    return report;
  }
}

class HealthReport {
  int routingTableSize = 0;
  bool isHealthy = false;
  bool canFindSelf = false;
  bool canStoreValues = false;
  List<String> errors = [];
  
  @override
  String toString() {
    return '''
DHT Health Report:
- Routing Table Size: $routingTableSize
- Overall Health: ${isHealthy ? 'HEALTHY' : 'UNHEALTHY'}
- Can Find Self: ${canFindSelf ? 'YES' : 'NO'}
- Can Store Values: ${canStoreValues ? 'YES' : 'NO'}
- Errors: ${errors.isEmpty ? 'None' : errors.join(', ')}
''';
  }
}
```

## Performance and Optimization

### Mobile Optimization

For mobile and resource-constrained environments:

```dart
class MobileOptimizedDHT {
  static const mobileConfig = <DHTOption>[
    mode(DHTMode.client),           // Client-only mode saves resources
    bucketSize(10),                 // Smaller routing table
    concurrency(3),                 // Lower network concurrency
    resiliency(2),                  // Fewer required responses
    maxDhtMessageRetries(2),        // Fewer retry attempts
    dhtMessageRetryMaxBackoff(Duration(seconds: 10)),
    disableAutoRefresh(),           // Manual refresh control
  ];
  
  static Future<IpfsDHT> create(Host host, ProviderStore store) async {
    final dht = await DHT.new_(host, store, mobileConfig);
    
    // Set up battery-friendly refresh schedule
    Timer.periodic(Duration(minutes: 15), (_) async {
      if (await _shouldRefresh()) {
        await dht.bootstrap(quickConnectOnly: true);
      }
    });
    
    return dht;
  }
  
  static Future<bool> _shouldRefresh() async {
    // Only refresh if network conditions are good
    // and battery level is sufficient
    return true; // Implement your logic
  }
}
```

### Server Optimization

For high-performance server nodes:

```dart
class HighPerformanceDHT {
  static const serverConfig = <DHTOption>[
    mode(DHTMode.server),
    bucketSize(50),                 // Large routing table
    concurrency(25),                // High concurrency
    resiliency(10),                 // Thorough queries
    lookupCheckConcurrency(1024),   // High lookup concurrency
    
    // Optimistic provide for better performance
    enableOptimisticProvide(),
    optimisticProvideJobsPoolSize(500),
    
    // Aggressive retry strategy
    maxDhtMessageRetries(7),
    dhtMessageRetryInitialBackoff(Duration(milliseconds: 50)),
    dhtMessageRetryMaxBackoff(Duration(seconds: 60)),
    dhtMessageRetryBackoffFactor(1.5),
  ];
  
  static Future<IpfsDHT> create(Host host, ProviderStore store) async {
    final dht = await DHT.new_(host, store, serverConfig);
    
    // Continuous bootstrap with frequent refresh
    await dht.bootstrap(
      quickConnectOnly: false,
      periodicRefreshInterval: Duration(minutes: 2),
    );
    
    return dht;
  }
}
```

### Memory Management

```dart
class DHTMemoryManager {
  final IpfsDHT dht;
  final ProviderStore providerStore;
  Timer? _cleanupTimer;
  
  DHTMemoryManager(this.dht, this.providerStore);
  
  void startMemoryManagement() {
    _cleanupTimer = Timer.periodic(Duration(minutes: 30), (_) async {
      await _performCleanup();
    });
  }
  
  Future<void> _performCleanup() async {
    // Clean up expired provider records
    if (providerStore is MemoryProviderStore) {
      await (providerStore as MemoryProviderStore).cleanup();
    }
    
    // Check routing table size and trim if necessary
    final tableSize = await dht.routingTable.size();
    if (tableSize > 1000) { // Adjust threshold as needed
      await _trimRoutingTable();
    }
  }
  
  Future<void> _trimRoutingTable() async {
    // Implementation would depend on routing table internals
    // This is a placeholder for custom trimming logic
    print('Routing table size exceeded threshold, consider trimming');
  }
  
  void stop() {
    _cleanupTimer?.cancel();
  }
}
```

### Performance Monitoring

```dart
class DHTPerformanceMonitor {
  final IpfsDHT dht;
  final Map<String, List<Duration>> _operationTimes = {};
  
  DHTPerformanceMonitor(this.dht);
  
  Future<T> measureOperation<T>(String operationName, Future<T> Function() operation) async {
    final stopwatch = Stopwatch()..start();
    try {
      final result = await operation();
      stopwatch.stop();
      _recordOperationTime(operationName, stopwatch.elapsed);
      return result;
    } catch (e) {
      stopwatch.stop();
      _recordOperationTime('${operationName}_error', stopwatch.elapsed);
      rethrow;
    }
  }
  
  void _recordOperationTime(String operation, Duration duration) {
    _operationTimes.putIfAbsent(operation, () => []).add(duration);
    
    // Keep only last 100 measurements
    final times = _operationTimes[operation]!;
    if (times.length > 100) {
      times.removeRange(0, times.length - 100);
    }
  }
  
  Map<String, PerformanceStats> getPerformanceStats() {
    final stats = <String, PerformanceStats>{};
    
    for (final entry in _operationTimes.entries) {
      final times = entry.value;
      if (times.isNotEmpty) {
        times.sort();
        final avg = times.fold(Duration.zero, (a, b) => a + b) ~/ times.length;
        final median = times[times.length ~/ 2];
        final p95 = times[(times.length * 0.95).floor()];
        
        stats[entry.key] = PerformanceStats(
          operation: entry.key,
          count: times.length,
          average: avg,
          median: median,
          p95: p95,
          min: times.first,
          max: times.last,
        );
      }
    }
    
    return stats;
  }
}

class PerformanceStats {
  final String operation;
  final int count;
  final Duration average;
  final Duration median;
  final Duration p95;
  final Duration min;
  final Duration max;
  
  PerformanceStats({
    required this.operation,
    required this.count,
    required this.average,
    required this.median,
    required this.p95,
    required this.min,
    required this.max,
  });
  
  @override
  String toString() {
    return '''
$operation:
  Count: $count
  Average: ${average.inMilliseconds}ms
  Median: ${median.inMilliseconds}ms
  95th percentile: ${p95.inMilliseconds}ms
  Min: ${min.inMilliseconds}ms
  Max: ${max.inMilliseconds}ms
''';
  }
}
```

### Best Practices Summary

1. **Choose the Right Mode**:
   - Use `DHTMode.client` for mobile/resource-constrained devices
   - Use `DHTMode.server` for infrastructure nodes
   - Use `DHTMode.auto` for general applications

2. **Configure for Your Use Case**:
   - Lower `bucketSize` and `concurrency` for mobile
   - Higher values for server nodes
   - Adjust `resiliency` based on network reliability needs

3. **Bootstrap Configuration**:
   - Always configure bootstrap peers for network connectivity
   - Use multiple bootstrap peers for redundancy
   - Consider geographic distribution of bootstrap peers

4. **Error Handling**:
   - Implement retry logic for critical operations
   - Handle `MaxRetriesExceededException` appropriately
   - Use timeouts for operations that might hang

5. **Memory Management**:
   - Implement periodic cleanup for long-running applications
   - Monitor routing table size on resource-constrained devices
   - Use appropriate provider store implementations

6. **Performance Monitoring**:
   - Monitor key metrics like routing table size and operation latencies
   - Implement health checks for production deployments
   - Use performance monitoring to optimize configuration

---

## Conclusion

This developer guide provides comprehensive coverage of the Dart libp2p Kademlia DHT implementation. The library offers a robust, feature-complete DHT suitable for various P2P applications, from mobile apps to server infrastructure.

Key takeaways:
- Start with the basic examples and gradually explore advanced features
- Choose configuration options appropriate for your deployment environment
- Implement proper error handling and monitoring for production use
- Leverage the extensive test suite and examples for learning and development

For additional help, refer to the integration tests in the `test/` directory, which demonstrate real-world usage patterns and provide excellent examples of working code.
