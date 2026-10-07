# Dart libp2p Kademlia DHT

[![Dart](https://img.shields.io/badge/Dart-3.5.0+-blue.svg)](https://dart.dev/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-1.1.0-orange.svg)](pubspec.yaml)

A comprehensive Dart implementation of the libp2p Kademlia Distributed Hash Table (DHT) for building decentralized peer-to-peer applications. This library provides the core infrastructure for peer discovery, content routing, and distributed key-value storage in P2P networks.

## 🚀 **Featured Implementation: IpfsDHTv2**

**IpfsDHTv2** is our flagship implementation featuring a modular, production-ready architecture with enhanced performance, observability, and maintainability. It's a drop-in replacement for the original IpfsDHT with significant improvements.

### 🌟 Key Improvements in v2

- **🔄 Modular Architecture**: Clean separation of concerns with focused components
- **📊 Built-in Observability**: Comprehensive metrics and monitoring out of the box
- **🛡️ Enhanced Error Handling**: Structured exceptions with retry logic
- **⚡ Performance Optimized**: Parallel operations and efficient routing
- **🧪 Testing-Friendly**: Dependency injection for easy testing
- **🔧 Flexible Configuration**: Builder pattern for complex setups

## 🌟 Features

### Core DHT Capabilities
- **Peer Discovery**: Find peers by their ID across the network using Kademlia routing
- **Content Routing**: Discover who has specific content using content addressing (CID)
- **Distributed Storage**: Store and retrieve key-value pairs across the network
- **Service Discovery**: Advertise and find services in the P2P network
- **Provider Records**: Track and announce content availability across the network

### Network Modes
- **Client Mode**: Lightweight mode for mobile and resource-constrained devices
- **Server Mode**: Full participant mode for infrastructure and bootstrap nodes
- **Auto Mode**: Switches between client and server with the host's reachability: a server while AutoNAT (or `forceReachability`) reports public reachability, a client while it is private or unknown

### Advanced Features
- **Bootstrap Integration**: Easy connection to existing libp2p networks with configurable bootstrap peers
- **Routing Table Management**: Kademlia-based peer routing with configurable bucket sizes
- **Query Engine**: Efficient parallel query execution with configurable concurrency
- **Retry Logic**: Configurable retry mechanisms with exponential backoff
- **Network Size Estimation**: Built-in network size estimation capabilities

### Production-Ready Components
- **Cryptographic Validation**: Signed records with anti-replay protection
- **4-Phase Bootstrap**: Comprehensive network connectivity with health monitoring
- **Provider Operations**: Complete network-integrated provider management
- **Datastore Operations**: Full local record storage with validation
- **Metrics & Monitoring**: Real-time performance tracking and health checks

## 🚀 Quick Start

### Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  dart_libp2p_kad_dht: ^1.4.1
  dart_libp2p: ^0.5.2
  dcid: ^1.0.0
```

### Basic Usage with IpfsDHTv2

```dart
import 'package:dart_libp2p_kad_dht/src/dht/v2/dht_v2.dart';
import 'package:dart_libp2p/dart_libp2p.dart';

Future<void> main() async {
  // Create a libp2p host
  final host = await createLibp2pHost();
  
  // Create a provider store for content routing
  final providerStore = MemoryProviderStore();
  
  // Create and start the DHT v2 (recommended)
  final dht = IpfsDHTv2(
    host: host,
    providerStore: providerStore,
    options: const DHTOptions(
      mode: DHTMode.auto,
      bucketSize: 20,
      concurrency: 10,
    ),
  );
  
  await dht.start();
  await dht.bootstrap(); // Connect to the network
  
  // Find a peer
  final peerInfo = await dht.findPeer(targetPeerId);
  
  // Store a value (signed). The key's namespace needs a validator:
  // '/pk/<peer ID bytes>' is a public-key record. See "Value Records" for
  // your own namespaces.
  final pkKey = '/pk/${String.fromCharCodes(host.id.toBytes())}';
  await dht.putValue(pkKey, (await host.peerStore.keyBook.pubKey(host.id))!.marshal());
  
  // Retrieve a value (validated; asks the network)
  final value = await dht.getValue(pkKey);
  
  // Announce content availability
  await dht.provide(CID.fromString('QmExample...'), true);
  
  // Find content providers
  await for (final provider in dht.findProvidersAsync(CID.fromString('QmExample...'), 10)) {
    print('Found provider: ${provider.id}');
  }
  
  // Check metrics
  final metrics = dht.metrics;
  print('Success rate: ${metrics.querySuccessRate * 100}%');
  
  // Cleanup
  await dht.close();
  await host.close();
}
```

### Critical: Initialization Order

**You must start the DHT _before_ starting the host.** When `host.start()` is called, AutoRelay immediately connects to relay servers and triggers an Identify exchange. If the DHT hasn't registered its protocol handler yet, the first Identify response will be missing `/ipfs/kad/1.0.0`. Go-based peers that receive this will mark your node as "peer stopped dht" and refuse to open DHT streams to it — breaking peer discovery permanently for that connection.

```dart
// CORRECT — DHT starts first, then host
final host = await createLibp2pHost(); // Do NOT call host.start() yet
final dht = IpfsDHTv2(host: host, providerStore: store, options: options);
await dht.start();       // Registers /ipfs/kad/1.0.0 protocol handler
await host.start();      // Now AutoRelay's Identify will include DHT protocol
await dht.bootstrap();

// WRONG — host starts before DHT
final host = await createLibp2pHost();
await host.start();      // AutoRelay connects, Identify sent WITHOUT /ipfs/kad/1.0.0
final dht = IpfsDHTv2(host: host, providerStore: store, options: options);
await dht.start();       // Too late — Go already marked us "peer stopped dht"
```

This applies to any protocol handler that must be advertised via Identify — always register handlers before `host.start()`.

In `DHTMode.auto` (the default), `IpfsDHTv2` starts as a client and registers
the `/ipfs/kad/1.0.0` handler only when the host reports public reachability
(`EvtLocalReachabilityChanged`, from AutoNAT or the `forceReachability` host
option). It removes the handler again when reachability becomes private or
unknown. Identify pushes each change to connected peers, which add the node
to or remove it from their routing tables. `DHTMode.autoServer` starts as a
server and is a client only while reachability is private. `dht.isServer`
tells whether the node serves now. Start the DHT before the host, as above,
so that the DHT sees the first reachability event.

### Value Records

`putValue` and `getValue` store and read signed records under a key. As in
go-libp2p-kad-dht, the key's namespace (`/<namespace>/...`) decides how a
record is checked:

- A record is accepted (by `putValue`, by a server receiving `PUT_VALUE`, and
  in `GET_VALUE` answers) only if the validator registered for its namespace
  accepts it. The default validator has the `pk` and `ipns` namespaces.
- A key whose namespace has no validator, such as `my-key`, is refused by
  default: `putValue` throws a `DHTProtocolException` and `getValue` returns
  only a record that this node stored itself.
- When a node holds a record and receives another one for the same key, the
  validator's `select()` decides which one it keeps. The record's timestamp
  is chosen by its writer and does not decide.
- A node keeps a record for `DHTOptions.maxRecordAge` (default 36 hours)
  after it stored it. Put a record again before then to keep it in the
  network; the DHT does not republish records itself.
- `getValue` reads the local record and asks the closest peers. It selects
  the best valid record with `select()`. With `RoutingOptions()..offline =
  true` it reads only the local datastore.

Register a validator for your own namespace:

```dart
import 'package:dart_libp2p_kad_dht/src/record/namespace_validator.dart';
import 'package:dart_libp2p_kad_dht/src/record/public_key_validator.dart';
import 'package:dart_libp2p_kad_dht/src/record/ipns_validator.dart';
import 'package:dart_libp2p_kad_dht/src/record/validator.dart';

class GreetingValidator implements Validator {
  @override
  Future<void> validate(String key, Uint8List value) async {
    // Throw if the value is not valid for this key. To stop other peers
    // from replacing a value, tie the key to its owner here, e.g. require
    // a signature in the value by the peer ID that the key contains.
    if (value.length > 1024) throw Exception('value too large');
  }

  @override
  Future<int> select(String key, List<Uint8List> values) async {
    return 0; // index of the best value
  }
}

final dht = IpfsDHTv2(
  host: host,
  providerStore: providerStore,
  validator: NamespacedValidator()
    ..['pk'] = PublicKeyValidator()
    ..['ipns'] = IpnsValidator(host.peerStore)
    ..['greeting'] = GreetingValidator(),
);
await dht.putValue('/greeting/alice', utf8.encode('hello'));
```

Passing `validator:` replaces the default validator, so add `pk` and `ipns`
again if you need them.

For keys without a namespace validator, `DHTOptions(allowUnvalidatedRecords:
true)` accepts records that carry a valid signature of their author. A node
then replaces a stored record only with a newer record of the same author, so
the first author to store a key on a node keeps it there until it expires.
This is weaker than a validator; use it for trusted or test networks.

The legacy `IpfsDHT` applies the same rules: the `PUT_VALUE` handler, records
in `GET_VALUE` answers, `putValue` and `getValue` (which now also asks the
network when it has a local record) all use the same validation, selection
and expiry code as `IpfsDHTv2`. Its default validator also has only `pk` and
`ipns`; the `v` namespace, which accepted any value, is gone. A `validator:`
passed to `IpfsDHT` gets `pk` and `ipns` added when it has no entry for them.

### Advanced Configuration with Builder Pattern

```dart
import 'package:dart_libp2p_kad_dht/src/dht/v2/config/dht_config.dart';

// Use builder pattern for complex configuration
final config = DHTConfigBuilder()
  .mode(DHTMode.server)
  .bucketSize(25)
  .concurrency(15)
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

## 📚 Examples

### Interactive P2P Node (v2)

Run a fully interactive P2P node with all DHT operations:

```bash
dart run example/basic_p2p_node.dart
```

**Available Commands:**
- `stats` - Show network statistics and metrics
- `store <key> <value>` - Store a cryptographically signed key-value pair
- `get <key>` - Retrieve a validated value
- `announce <content-id>` - Announce content availability
- `find-content <content-id>` - Find content providers
- `find-peer <peer-id>` - Find a specific peer
- `metrics` - Show detailed performance metrics
- `quit` - Exit the demo

### Mobile Optimized Node

For resource-constrained environments:

```bash
dart run example/mobile_p2p_node.dart
```

### Server Node

High-performance server deployment:

```bash
dart run example/server_node.dart --port 4001
```

## 🔧 Configuration

### DHT v2 Options

```dart
final dhtOptions = DHTOptions(
  mode: DHTMode.auto,        // client, server, or auto
  bucketSize: 20,            // K-bucket size
  concurrency: 10,           // Concurrent operations
  resiliency: 3,             // Query redundancy
  bootstrapPeers: [          // Network entry points; each address must end in /p2p/<peer ID>
    MultiAddr('/ip4/203.0.113.7/udp/4001/udx/p2p/12D3KooW...'),
    MultiAddr('/ip4/203.0.113.8/tcp/4001/p2p/12D3KooW...'),
  ],
  maxRecordAge: Duration(hours: 36), // How long a value record is kept
  allowUnvalidatedRecords: false,    // Accept keys without a namespace validator
);
```

### Advanced Configuration with Builder

```dart
final config = DHTConfigBuilder()
  .mode(DHTMode.server)
  .bucketSize(30)
  .concurrency(20)
  .resiliency(5)
  .networkTimeout(Duration(seconds: 30))
  .queryTimeout(Duration(seconds: 60))
  .enableMetrics(true)
  .optimisticProvide(true)
  .maxRetryAttempts(5)
  .retryInitialBackoff(Duration(milliseconds: 250))
  .build();
```

## 🏗️ Architecture

### DHT v2 Modular Components

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
└─────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

- **NetworkManager**: Message handling, connection management, retry logic
- **RoutingManager**: Routing table management, peer discovery, bootstrap
- **QueryManager**: Query coordination, peer lookups, value operations
- **ProtocolManager**: Protocol message processing, request/response handling
- **MetricsManager**: Performance monitoring, error tracking, health checks

## 📊 Monitoring & Metrics

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

## 🛡️ Error Handling

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

## 🧪 Testing

Run the comprehensive test suite:

```bash
dart test
```

The test suite includes:
- Unit tests for all components
- Integration tests with real network scenarios
- Performance benchmarks
- Mobile device simulation tests

A fresh clone builds against the published packages. To develop against local
checkouts of [dart_libp2p](https://github.com/stephanfeb/dart_libp2p) or
[dart-udx](https://github.com/stephanfeb/dart-udx), create a
`pubspec_overrides.yaml` (git-ignored) next to `pubspec.yaml`:

```yaml
dependency_overrides:
  dart_libp2p:
    path: ../dart-libp2p
  dart_udx:
    path: ../dart-udx
```

The Go interop tests in `test/interop` build the go-libp2p peer from a
dart_libp2p checkout (`GO_PEER_DIR`, or `../dart-libp2p/interop/go-peer` by
default) and need Go.

## 📖 Documentation

- **[Developer Guide](DEVELOPER_GUIDE.md)**: Comprehensive guide for P2P application developers
- **[Examples](example/README.md)**: Detailed examples and use cases
- **[DHT v2 Documentation](lib/src/dht/v2/README.md)**: Complete v2 architecture guide
- **[Integration Tests](test/dht/)**: Real-world usage patterns

## 🔄 Migration from Original DHT

### Simple Migration

```dart
// Old
import 'package:dart_libp2p_kad_dht/src/dht/dht.dart';
final dht = IpfsDHT(host: host, providerStore: providerStore, options: options);

// New (recommended)
import 'package:dart_libp2p_kad_dht/src/dht/v2/dht_v2.dart';
final dht = IpfsDHTv2(host: host, providerStore: providerStore, options: options);
```

### Benefits of Migration

- **Better error handling**: Structured exceptions and retry logic
- **Improved observability**: Built-in metrics and monitoring
- **Better testability**: Modular design and dependency injection
- **Enhanced performance**: Optimized query patterns and caching
- **Future-proof**: Easier to extend and maintain

## 🤝 Contributing

We welcome contributions! Please see our contributing guidelines:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Ensure all tests pass
6. Submit a pull request

### Development Setup

```bash
# Clone the repository
git clone https://github.com/stephanfeb/dart_libp2p_kad_dht.git
cd dart_libp2p_kad_dht

# Install dependencies
dart pub get

# Run tests
dart test

# Run examples
dart run example/basic_p2p_node.dart
```

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Based on the [go-libp2p-kad-dht](https://github.com/libp2p/go-libp2p-kad-dht) implementation
- Implements the [Kademlia DHT](https://en.wikipedia.org/wiki/Kademlia) algorithm
- Built for the [libp2p](https://libp2p.io/) networking stack

## 🔗 Related Projects

- [dart_libp2p](https://pub.dev/packages/dart_libp2p): Core libp2p networking library
- [dcid](https://pub.dev/packages/dcid): Content addressing utilities
- [dart_udx](https://pub.dev/packages/dart_udx): UDP-based transport layer

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/stephanfeb/dart_libp2p_kad_dht/issues)
- **Discussions**: [GitHub Discussions](https://github.com/stephanfeb/dart_libp2p_kad_dht/discussions)
- **Documentation**: [Developer Guide](DEVELOPER_GUIDE.md)

---

**Built with ❤️ for the decentralized web**
