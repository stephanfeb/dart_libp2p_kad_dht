# Changelog

All notable changes to this project will be documented in this file.

## [1.1.0] - 2025-07-29

### Added

#### Core DHT Features
- **Peer Discovery**: Find peers by their ID across the network using Kademlia routing
- **Content Routing**: Discover who has specific content using content addressing (CID)
- **Distributed Key-Value Storage**: Store and retrieve key-value pairs across the network
- **Service Discovery**: Advertise and find services in the P2P network using namespaces
- **Provider Records**: Track and announce content availability across the network

#### Network Modes
- **Client Mode**: Lightweight mode for mobile and resource-constrained devices
- **Server Mode**: Full participant mode for infrastructure and bootstrap nodes
- **Auto Mode**: Automatically switches between client/server based on network conditions

#### Advanced Features
- **Bootstrap Integration**: Easy connection to existing libp2p networks with configurable bootstrap peers
- **Routing Table Management**: Kademlia-based peer routing with configurable bucket sizes
- **Query Engine**: Efficient parallel query execution with configurable concurrency
- **Retry Logic**: Configurable retry mechanisms with exponential backoff
- **Network Size Estimation**: Built-in network size estimation capabilities

#### Configuration & Performance
- **Functional Configuration**: Flexible configuration using functional options pattern
- **Performance Tuning**: Configurable concurrency, resiliency, and bucket sizes
- **Mobile Optimization**: Resource-efficient operation for mobile devices
- **Metrics & Monitoring**: Built-in metrics collection and health monitoring

#### Record Types & Validation
- **Value Records**: Distributed key-value storage with TTL support
- **Provider Records**: Content availability announcements
- **Peer Records**: Peer information and address storage
- **Service Records**: Service discovery and registration
- **Custom Validators**: Support for custom record validation (IPNS, Public Key, Generic)

#### Protocol Support
- **DHT Protocol v1**: Full implementation of the libp2p DHT protocol
- **DHT Protocol v2**: New modular implementation with improved architecture
- **Protocol Buffers**: Efficient message serialization using protobuf
- **Multiaddr Support**: Full support for libp2p multiaddresses

#### Developer Experience
- **Comprehensive Examples**: Interactive examples for basic, mobile, and server nodes
- **Extensive Testing**: Unit tests, integration tests, and real network scenarios
- **Developer Guide**: Complete documentation with usage patterns and best practices
- **Error Handling**: Comprehensive error handling with detailed error messages

### Technical Improvements

#### Architecture
- **Modular Design**: Clean separation of concerns with focused components
- **Manager Pattern**: Dedicated managers for network, routing, queries, protocols, and metrics
- **Event-Driven**: Event-based architecture for better scalability
- **Async/Await**: Full async support throughout the codebase

#### Performance
- **Optimized Routing**: Efficient Kademlia routing table implementation
- **Parallel Queries**: Concurrent query execution for better performance
- **Memory Management**: LRU caches and efficient memory usage
- **Connection Pooling**: Reuse of network connections

#### Reliability
- **Graceful Degradation**: Handles network failures gracefully
- **Timeout Handling**: Configurable timeouts for all operations
- **Circuit Breakers**: Protection against cascading failures
- **Health Checks**: Built-in health monitoring capabilities

### Dependencies

#### Core Dependencies
- `dart_libp2p: ^0.5.2` - Core libp2p networking library
- `dcid: ^1.0.0` - Content addressing utilities
- `dart_udx: ^0.3.1` - UDP-based transport layer
- `pointycastle: ^3.7.0` - Cryptographic operations
- `protobuf: ^3.1.0` - Protocol buffer serialization
- `cbor: 6.3.5` - CBOR serialization
- `multibase: ^1.0.0` - Multi-base encoding
- `dart_multihash: ^1.0.0` - Multi-hash support

#### Development Dependencies
- `test: ^1.24.0` - Testing framework
- `mockito: ^5.4.5` - Mocking library
- `protoc_plugin: ^21.0.0` - Protocol buffer compiler
- `lints: ^2.1.0` - Code linting rules

### Breaking Changes

None in this release. The API maintains backward compatibility with previous versions.

### Migration Guide

This release is a drop-in replacement for previous versions. No migration steps required.

### Known Issues

- Mobile devices may experience higher battery usage in server mode
- Large routing tables may consume significant memory on resource-constrained devices
- Network connectivity issues may cause temporary bootstrap failures

### Future Roadmap

- Enhanced mobile optimization features
- Additional record types and validators
- Improved network size estimation algorithms
- Better integration with libp2p ecosystem
- Performance benchmarking tools
