# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Fixed
- **A DHT message larger than one read failed to decode** (dart-libp2p-cce.2). The legacy `IpfsDHT` read a request (inbound handler) and a response (`_sendMessage`) with one `stream.read()`, and `IpfsDHTv2` read a response the same way. A read returns one transport frame. A go-libp2p peer sends small yamux frames, so a `FIND_NODE` or `GET_PROVIDERS` answer with many peers came in several reads, and decoding failed (`RangeError ... 2..4096: 4560`). Now all three read with `DhtMessageReader`, which reads until the varint-delimited message is complete. The inbound handler of `IpfsDHT` also answers more than one request on a stream, as go-libp2p-kad-dht sends them.
- **`advertise` and `findPeers` threw for a namespace that is not a CID string, and used a key that go-libp2p does not use** (dart-libp2p-cce.3). `IpfsDHT` called `CID.fromString(ns)`. `IpfsDHTv2` did not advertise or search at all. Now both use `namespaceToCid(ns)`: CIDv1, codec raw, multihash sha2-256 of the namespace, as `nsToCid` in go-libp2p's routing discovery. So Dart and Go peers find each other on the same namespace. A namespace that was a CID string has a different key now: advertisements made by an older version are not found.
- **`findProvidersAsync(cid, 0)` asked no peer.** A count of 0 means "no limit" (as in go-libp2p-kad-dht, and as `findPeers` passes it), but both DHTs returned the local providers only. Now 0 means no limit.

### Added
- `namespaceToCid` (exported).

## [1.5.1] - 2026-10-08

### Fixed
- **Provider records are keyed by the CID's multihash, so Dart and go-libp2p nodes find each other's providers.** Both DHTs sent the full CIDv1 bytes as the key of `ADD_PROVIDER` and `GET_PROVIDERS` and as the provider lookup target, and stored providers under them. go-libp2p-kad-dht, and the libp2p Kademlia spec, use the multihash (`cid.Hash()`). A Dart node therefore never found a provider that a Go node had announced (it asked a Go server for a key the server had never stored), and Go never found a provider that a Dart node had announced to a Go server. Now:
  - `provide` and `findProvidersAsync` (`IpfsDHT` and `IpfsDHTv2`) send the multihash and look up the peers closest to it;
  - `MemoryProviderStore` and `ProviderManager` key records by the multihash, so every CID of the same content (v0 or v1, any codec) shares one set of providers;
  - the `ADD_PROVIDER` and `GET_PROVIDERS` handlers, and `addProvider`/`getLocalProviders`, read a multihash key, and still accept the full CIDv1 bytes that Dart peers before 1.5.1 send. A provider that an older Dart peer announces to an updated one is stored under the multihash, so both versions find it there; an updated node looking up providers on an older Dart server does not find them.
- New: `providerKeyOf`, `providerKeyFromWire` and `cidForProviderKey` (`lib/src/providers/provider_key.dart`, exported). A custom `ProviderStore` should key records by `providerKeyOf(cid)` as well.

## [1.5.0] - 2026-10-08

### Changed (behaviour)
- **IpfsDHTv2 value records are checked by their namespace validator; keys without one are refused by default.** This follows go-libp2p-kad-dht. `putValue('my-key', ...)` now throws a `DHTProtocolException`, because `my-key` has no namespace. Register a validator for your namespace (`IpfsDHTv2(validator: ...)`), or set the new `DHTOptions.allowUnvalidatedRecords: true` (see Security below). The default validator now has `pk` and `ipns` only: the `v` entry (`DHTRecordValidator`, which expected a JSON-encoded record as the value, and was never called) was removed. The legacy `IpfsDHT` now follows the same rules (see the next entry).
- **The legacy `IpfsDHT` validates, selects and expires value records as `IpfsDHTv2` does.** Its `validateRecord` returned `true` for every record, the `PUT_VALUE` handler stored any record from anyone (and dropped every record that had no author, as go-libp2p records have none), `getValue` called the validator without waiting for it, and records never expired. The validation, selection and expiry code of `IpfsDHTv2` moved to a shared `ValueRecordStore` (`lib/src/record/value_record_store.dart`), which both DHTs use. In `IpfsDHT` now:
  - the `PUT_VALUE` handler refuses a record whose key is not the message key, or that the namespace validator refuses, or whose key has no validator (unless `DHTOptions.allowUnvalidatedRecords`); the stream is then reset. A valid record replaces the stored one only if the validator's `select()` prefers it. The answer echoes the record, as go-libp2p-kad-dht expects;
  - `putValue` signs the record when the host's private key is known, refuses a record that peers would refuse (`DHTProtocolException`), and honours `RoutingOptions.offline`;
  - `getValue` validates each record in `GET_VALUE` answers, reads the local record and asks the network (it returned the local record alone before), and selects the best record with `select()`. `RoutingOptions.offline` reads only the local datastore;
  - `searchValue` ignores answer records for another key;
  - records expire after `DHTOptions.maxRecordAge` (36 hours) and are pruned every hour;
  - `putRecordToDatastore` checks the signature (if any) and the namespace validator (if any), and throws when the record is not valid; a record under a key without a validator must be signed;
  - the default validator has `pk` and `ipns` only; the `v` entry (`GenericValidator`, which accepted any value) is gone. A validator passed to the constructor gets `pk` and `ipns` only when it has no entry for them (they replaced the caller's entries before);
  - `checkLocalDatastore` looks keys up by their bytes (one character per byte), as `IpfsDHTv2` does, instead of base64.
- **`getValue` asks the network.** It no longer returns the local copy alone: it reads the local record, sends `GET_VALUE` to the closest peers, and selects the best valid record with the validator's `select()`. The lookup stops when `resiliency` peers returned a valid record or `resiliency` peers were queried. `RoutingOptions.offline` reads only the local datastore. `searchValue` validates each record and emits only records that are better than the ones it emitted before.
- **Auto mode switches between client and server (IpfsDHTv2).** `DHTMode.auto`, the default, registered the DHT stream handler only in server and autoServer modes, and nothing watched reachability, so an auto-mode node stayed a client. It now subscribes to `EvtLocalReachabilityChanged` on the host event bus: it registers the `/ipfs/kad/1.0.0` handler while reachability is public and removes it while reachability is private or unknown, as go-libp2p-kad-dht does. `DHTMode.autoServer` starts as a server and becomes a client only while reachability is private. Removing or adding the handler makes Identify push the new protocol list, so peers update their routing tables. The subscription is closed when the DHT closes. New: `IpfsDHTv2.isServer`, and `ProtocolManager.enableServerMode`, `disableServerMode` and `isServing`.

### Security
- **Value records could be overwritten by anyone.** The `PUT_VALUE` handler of `IpfsDHTv2` checked only that a record was signed by the author it names, and replaced the stored record when the new record's `timeReceived` was greater. That timestamp is chosen by the writer, and nothing tied the key to the author; the namespace validators (`pk`, `ipns`) were never called. Now:
  - the record's key must be the message key, a record that has an author or a signature must have a valid signature, and the validator of the key's namespace must accept the value;
  - the validator's `select()` between the received and the stored record decides which one is kept (the received record first, as in go);
  - with `allowUnvalidatedRecords`, a record in a namespace without a validator must be signed, and it replaces a stored record only if it has the same author and is newer;
  - records in the local datastore expire `DHTOptions.maxRecordAge` (new, default 36 hours, as go's `MaxRecordAge`) after they were stored. Expired records are not served and are removed periodically. The DHT does not republish records; put them again to keep them.
  - `IpfsDHTv2.validateRecord` now validates (it returned `true` for every record).
- New API (all additive): `DHTOptions.maxRecordAge`, `DHTOptions.allowUnvalidatedRecords` (and the same fields, `copyWith` parameters and builder methods on `DHTConfigV2`), `AminoConstants.defaultMaxRecordAge`, and on the internal `ProtocolManager`: an optional `validator` argument to `initialize`, `validateRecord`, `selectRecord` and `pruneExpiredRecords`.

### Fixed
- **Go peers got no answer to their second request on a stream (IpfsDHTv2).** go-libp2p-kad-dht keeps one stream per peer and sends its next request on it (for example `PUT_VALUE` after `FIND_NODE`). The v2 `ProtocolManager` read one message, answered it, and then did not read the stream again or close it, so the next request was never answered. The handler now loops: it reads a varint-length-prefixed message, answers it (`ADD_PROVIDER` has no answer) and reads the next one. A message can arrive in parts or together with the next one; the new `DhtMessageReader` keeps the extra bytes. The handler closes the stream when the peer ends it or sends nothing for 1 minute (`AminoConstants.inboundStreamIdleTimeout`, as go's `dhtStreamIdleTimeout`; `ProtocolManager.inboundStreamIdleTimeout` changes it). It resets the stream when a message is not valid (bad frame, larger than 4 MiB, bad protobuf, unknown type) or a request fails, as go does; before, it sent a `PING` message as an error answer. The Dart client, which opens one stream per request, is not changed.
- **`PUT_VALUE` answers now echo the record (IpfsDHTv2).** The go client checks that the answer carries the value it put, and fails the put otherwise.
- `ProtocolManager.getRecordFromDatastoreBytes` (used by `checkLocalDatastore`) decoded the key as UTF-8, but keys are stored with one character per byte. Binary keys such as `/pk/<multihash>` were not found.
- **Any peer could register any peer as a provider, without limit.** The `ADD_PROVIDER` handler (v2 `ProtocolManager` and the legacy `DHTHandlers`) stored every entry in the message, whatever peer sent it, and `MemoryProviderStore` appended each one to a list with no limit and no duplicate check. Now:
  - only the entry for the sending peer is stored, with its addresses; entries for other peers are ignored and logged at `FINE` (go-libp2p-kad-dht does the same);
  - `MemoryProviderStore` keeps one record per (key, provider). A repeated announcement refreshes the expiry and replaces the addresses;
  - `MemoryProviderStore` has limits, set through new `ProviderManagerOptions` fields: `maxProvidersPerKey` (default 100), `maxKeysPerProvider` (default 1000) and `maxProviderRecords` (default 100000). When a limit is reached, expired records are removed first; if it is still reached, the new record is refused and the stored records stay. Refusing, and not evicting the oldest record, stops a peer with many peer IDs from pushing honest providers out of a key. The local peer's own records are not limited: `MemoryProviderStore.localPeerId` (new, optional constructor argument) marks them, and the DHT sets it when it is not set.
  - `ProviderManager.addProvider` now clears its cached set for the key instead of adding to it, because the store can refuse a record.
- **Short keys crashed value operations.** Log lines in `putValue`, `getValue`, `searchValue` and the datastore helpers printed `key.substring(0, 10)`, which throws a `RangeError` for a key shorter than 10 characters. `putValue('my-key', ...)` threw, and `getValue('my-key')` caught the error and returned `null`. A helper now shortens keys, CIDs and lookup targets for logs without throwing. The IPv6 diversity-group label had the same fault for short addresses such as `::1`.

## [1.4.1] - 2026-10-04

### Fixed
- **Client-mode peers entered routing tables.** A DHT server added every peer that sent it a request to its routing table, including client-mode peers, which do not serve `/ipfs/kad/1.0.0`. The server then named those clients as closer peers, and lookups and `ADD_PROVIDER` were sent to them and failed, so provider records could be lost. Now, as in go-libp2p-kad-dht, only DHT servers go into the routing table:
  - a peer that sends a request is added only if Identify reports that it serves the DHT protocol;
  - a peer whose Identify completes, or whose protocols change, is added when it serves the DHT protocol and removed when it stops;
  - a peer that another peer names in a response is added after it answers a lookup check (a `FIND_NODE`), which runs in the background;
  - a peer that answers one of our queries is added, as before.
  The legacy `IpfsDHT` request handler applies the same check.
- **Logging.** The library no longer writes to stdout: its `print` calls now go through `package:logging` loggers. Messages about one peer or one query (a failed query to one peer, a removed peer, a refused routing-table entry, invalid data from a remote peer) and debug traces moved from `WARNING` or `SEVERE` to `FINE` or `FINEST`. `WARNING` and `SEVERE` are now kept for problems an operator can act on, such as an invalid bootstrap address or a failed bootstrap.
- README: `DHTOptions.bootstrapPeers` takes `MultiAddr` values that end in `/p2p/<peer ID>`, not `AddrInfo` values.

## [1.4.0] - 2026-10-04

### Changed
- **Works with dart_libp2p 3.x and 4.x**: `dart_libp2p` is now `>=1.0.0 <5.0.0` and `dart_udx` is `>=2.0.1 <5.0.0`. Neither release changes an API this package uses; the test suite gives the same results against dart_libp2p 3.0.0 and 4.0.0, and the Go interop tests pass against 4.0.0. The upper bounds had made this package unresolvable alongside dart_libp2p 3.0.0 or later.
- **A fresh clone builds from published packages.** The local path overrides moved out of `pubspec.yaml` into a git-ignored `pubspec_overrides.yaml` (see README).
- The Go DHT interop tests moved here from dart_libp2p. They build the go-libp2p peer from a dart_libp2p checkout (`GO_PEER_DIR`, or `../dart-libp2p/interop/go-peer`).

## [1.3.0] - 2026-09-23

### Changed
- **Dependency constraints widened so this package works with dart_libp2p 2.x**: `dart_libp2p` is now `>=1.0.0 <3.0.0` and `dart_udx` is `>=2.0.1 <4.0.0`. dart_libp2p 2.0.0 changes no API used here; it requires dart_udx 3.0.0, whose wire protocol v3 does not interoperate with v2. Pinning to `^1.0.0` and `^2.0.1` made this package unresolvable alongside dart_libp2p 2.x, so a consumer could not upgrade either.

### Fixed
- **Client mode no longer serves DHT queries.** Go's kad-dht `ModeClient` explicitly removes its stream handler and resets inbound DHT streams. Registering the `/ipfs/kad/1.0.0` handler in client mode made server nodes refresh their routing tables against mobile clients that cannot serve responses properly, which tore connections down. Both v1 (`IpfsDHT`) and v2 (`ProtocolManager`) register the handler only in server and autoServer modes.

### Documentation
- README now records the initialization order that matters: start the DHT before `host.start()`, or AutoRelay's first Identify exchange omits `/ipfs/kad/1.0.0` and Go peers mark the node as "peer stopped dht".

## [1.2.0] - 2026-02-17

### Changed (Breaking)
- **Wire format**: Switched DHT wire format from JSON to protobuf with spec-compliant keys for go-libp2p interoperability
- Updated `dart_libp2p` dependency to `^1.0.0`
- Updated `dart_udx` dependency to `^2.0.1`

### Added
- Bootstrap fallback for routing table building

### Fixed
- Critical fix: store addresses in peerstore before adding to routing table
- Added protection to connections
- Addressed timeout issues
- Routing manager crash fix

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
