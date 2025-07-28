# Dart libp2p Kademlia DHT Examples

This directory contains practical examples demonstrating how to use the Dart libp2p Kademlia DHT implementation in real P2P applications.

## Examples

### 1. Basic P2P Node (`basic_p2p_node.dart`)

A comprehensive interactive example that demonstrates all major DHT operations:

- **Peer Discovery**: Find peers by their ID
- **Content Routing**: Announce and find content providers
- **Value Storage**: Store and retrieve key-value pairs
- **Service Discovery**: Advertise and find services
- **Network Statistics**: Monitor DHT health and network size

**Usage:**
```bash
# Run without bootstrap peers (will use configured defaults)
dart run examples/basic_p2p_node.dart

# Run with specific bootstrap peers
dart run examples/basic_p2p_node.dart /ip4/1.2.3.4/tcp/4001/p2p/QmBootstrapPeer1 /ip4/5.6.7.8/tcp/4001/p2p/QmBootstrapPeer2
```

**Interactive Commands:**
- `stats` - Show network statistics
- `store <key> <value>` - Store a key-value pair
- `get <key>` - Retrieve a value
- `announce <content-id>` - Announce content
- `find-content <content-id>` - Find content providers
- `advertise <service>` - Advertise a service
- `find-service <service>` - Find service providers
- `find-peer <peer-id>` - Find a specific peer
- `quit` - Exit the demo

### 2. Mobile Optimized Node (`mobile_p2p_node.dart`)

A mobile-friendly P2P node example optimized for resource-constrained environments:

- **Client-only mode** for battery efficiency
- **Reduced routing table size** and memory usage
- **Lower network concurrency** to conserve resources
- **Background task management** with pause/resume functionality
- **Periodic cleanup** and memory management
- **Mobile app lifecycle support** (foreground/background transitions)

**Usage:**
```bash
# Run mobile node without bootstrap peers
dart run examples/mobile_p2p_node.dart

# Run with specific bootstrap peers
dart run examples/mobile_p2p_node.dart /ip4/1.2.3.4/tcp/4001/p2p/QmBootstrapPeer1
```

### 3. Server Node (`server_node.dart`)

A high-performance server node example for infrastructure deployment:

- **Server mode** with large routing table capacity
- **High concurrency** for better performance
- **Comprehensive metrics reporting** and health monitoring
- **Graceful shutdown** handling with SIGINT support
- **Command-line configuration** for bootstrap peers and ports
- **Production-ready logging** and error handling

**Usage:**
```bash
# Run server node with default settings
dart run examples/server_node.dart

# Run with custom port and bootstrap peers
dart run examples/server_node.dart --port 4001 --bootstrap /ip4/1.2.3.4/tcp/4001/p2p/QmPeer1,/ip4/5.6.7.8/tcp/4001/p2p/QmPeer2
```

## Configuration Examples

### Basic Configuration

```dart
final dht = IpfsDHT(
  host: host,
  providerStore: providerStore,
  options: const DHTOptions(
    mode: DHTMode.auto,
    bucketSize: 20,
    concurrency: 10,
    resiliency: 3,
  ),
);
```

### Functional Configuration

```dart
final dhtOptions = <DHTOption>[
  mode(DHTMode.server),
  bucketSize(30),
  concurrency(15),
  resiliency(5),
  bootstrapPeers([
    AddrInfo(peerId1, [addr1]),
    AddrInfo(peerId2, [addr2]),
  ]),
  enableOptimisticProvide(),
  maxDhtMessageRetries(5),
];

final dht = await DHT.new_(host, providerStore, dhtOptions);
```

## Running the Examples

1. **Prerequisites:**
   - Dart SDK 3.5.0 or later
   - All dependencies installed (`dart pub get`)

2. **Basic Usage:**
   ```bash
   # Navigate to project root
   cd dart-libp2p-kat-dht
   
   # Install dependencies
   dart pub get
   
   # Run an example
   dart run examples/basic_p2p_node.dart
   ```

3. **Multi-Node Testing:**
   
   To test peer discovery and content routing between multiple nodes:
   
   **Terminal 1 (Bootstrap Node):**
   ```bash
   dart run examples/basic_p2p_node.dart
   # Note the peer ID and listening address from output
   ```
   
   **Terminal 2 (Client Node):**
   ```bash
   dart run examples/basic_p2p_node.dart /ip4/127.0.0.1/tcp/PORT/p2p/PEER_ID_FROM_TERMINAL_1
   ```
   
   Now you can test operations like:
   - Store a value in Terminal 1, retrieve it from Terminal 2
   - Announce content in Terminal 1, find it from Terminal 2
   - Advertise a service in Terminal 1, discover it from Terminal 2

## Common Use Cases

### Content Distribution Network (CDN)

```dart
// Node 1: Content provider
await node.announceContent('QmContentHash123');

// Node 2: Content consumer
final providers = await node.findContentProviders('QmContentHash123');
// Connect to providers and download content
```

### Service Discovery

```dart
// Service provider
await node.advertiseService('file-sharing-service');

// Service consumer
final providers = await node.findServiceProviders('file-sharing-service');
// Connect to service providers
```

### Distributed Key-Value Store

```dart
// Store data
await node.storeValue('user:123:profile', jsonEncode(userProfile));

// Retrieve data
final profileJson = await node.retrieveValue('user:123:profile');
final profile = jsonDecode(profileJson);
```

## Best Practices

1. **Choose the Right Mode:**
   - Use `DHTMode.client` for mobile/resource-constrained devices
   - Use `DHTMode.server` for infrastructure nodes
   - Use `DHTMode.auto` for general applications

2. **Configure Bootstrap Peers:**
   - Always provide bootstrap peers for network connectivity
   - Use multiple bootstrap peers for redundancy
   - Consider geographic distribution

3. **Error Handling:**
   - Implement retry logic for critical operations
   - Handle network failures gracefully
   - Use timeouts for operations that might hang

4. **Performance Optimization:**
   - Adjust `bucketSize` and `concurrency` based on your environment
   - Use `enableOptimisticProvide()` for better content routing performance
   - Monitor routing table size and network statistics

5. **Security Considerations:**
   - Validate content before storing or serving
   - Implement proper authentication for sensitive operations
   - Consider using custom validators for application-specific data

## Troubleshooting

### Common Issues

1. **Bootstrap Failures:**
   - Check network connectivity to bootstrap peers
   - Verify bootstrap peer addresses are correct
   - Ensure bootstrap peers are actually running

2. **Peer Discovery Issues:**
   - Check routing table size (`stats` command)
   - Try bootstrapping again if routing table is empty
   - Verify target peer is actually online and reachable

3. **High Memory Usage:**
   - Use client mode for mobile devices
   - Reduce `bucketSize` and `maxRoutingTableSize`
   - Implement periodic cleanup

### Debug Logging

Enable detailed logging to troubleshoot issues:

```dart
Logger.root.level = Level.ALL;
Logger.root.onRecord.listen((record) {
  print('${record.level.name}: ${record.loggerName}: ${record.message}');
});
```

## Contributing

When adding new examples:

1. Follow the existing code style and structure
2. Include comprehensive documentation
3. Add error handling and logging
4. Test with multiple nodes
5. Update this README with usage instructions

## Related Documentation

- [Main Developer Guide](../DEVELOPER_GUIDE.md)
- [Integration Tests](../test/dht/) - Real-world usage patterns
- [API Reference](../lib/src/dht/dht.dart) - Complete API documentation
