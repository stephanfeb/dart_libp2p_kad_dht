// Ported from go-libp2p-kad-dht/internal/config/config.go

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p_kad_dht/src/record/namespace_validator.dart';
import 'package:meta/meta.dart';
// Removed: import '../../record/pb/crypto.pb.dart' as pb; 

// Imports for Validator interfaces and implementations from lib/src/record/
import '../../record/validator.dart' show Validator, NamespacedValidator;
import '../../record/public_key_validator.dart' show PublicKeyValidator;
import '../../record/ipns_validator.dart' show IpnsValidator; // This file will be created next

/// The default prefix for DHT protocols.
const String defaultPrefix = '/amino/kad/1.0.0';

/// Describes what mode the DHT should operate in.
enum DhtMode {
  /// Client mode means the node doesn't store provider records and doesn't forward requests.
  client,
  
  /// Server mode means the node stores provider records and forwards requests.
  server,
  
  /// Auto mode means the node decides whether to act as a client or server based on network conditions.
  auto
}

/// A filter applied when considering peers to dial when querying.
typedef QueryFilterFunc = bool Function(dynamic dht, PeerInfo peerInfo);

/// A filter applied when considering connections to keep in the local route table.
typedef RouteTableFilterFunc = bool Function(dynamic dht, String peerId);

/// A function that returns a list of bootstrap peers.
typedef BootstrapPeersFunc = List<PeerInfo> Function();

/// A function that filters addresses.
typedef AddressFilterFunc = List<String> Function(List<String> addrs);

/// A function that builds a message sender.
typedef MessageSenderBuilder = dynamic Function(dynamic host, List<String> protocols);

/// A function that is called when a request is received.
typedef OnRequestHook = void Function(dynamic context, dynamic stream, dynamic message);

/// Information about a peer.
class PeerInfo {
  /// The ID of the peer.
  final String id;
  
  /// The addresses of the peer.
  final List<String> addresses;
  
  /// Creates a new peer info.
  PeerInfo(this.id, this.addresses);
}

// Validator abstract class and NamespacedValidator class are now imported from ../../record/validator.dart

/// Configuration for the routing table.
class RoutingTableConfig {
  /// The timeout for refresh queries.
  Duration refreshQueryTimeout;
  
  /// The interval between automatic refreshes.
  Duration refreshInterval;
  
  /// Whether to automatically refresh the routing table.
  bool autoRefresh;
  
  /// The tolerance for latency when selecting peers.
  Duration latencyTolerance;
  
  /// The interval for checking the routing table.
  Duration checkInterval;
  
  /// A filter for peers in the routing table.
  RouteTableFilterFunc? peerFilter;
  
  /// A filter for diversity of peers in the routing table.
  dynamic diversityFilter;
  
  /// Creates a new routing table configuration.
  RoutingTableConfig({
    this.refreshQueryTimeout = const Duration(seconds: 10),
    this.refreshInterval = const Duration(minutes: 10),
    this.autoRefresh = true,
    this.latencyTolerance = const Duration(seconds: 10),
    this.checkInterval = const Duration(minutes: 1),
    this.peerFilter,
    this.diversityFilter,
  });
}

/// Configuration for the DHT.
class DhtConfig {
  /// The datastore for storing DHT records.
  dynamic datastore;
  
  /// The validator for DHT records.
  Validator validator;
  
  /// Whether the validator has been changed from the default.
  bool validatorChanged;
  
  /// The mode the DHT should operate in.
  DhtMode mode;
  
  /// The protocol prefix for DHT protocols.
  String protocolPrefix;
  
  /// An override for the V1 protocol.
  String? v1ProtocolOverride;
  
  /// The size of k-buckets in the routing table.
  int bucketSize;
  
  /// The number of concurrent requests to make.
  int concurrency;
  
  /// The number of peers to query in parallel.
  int resiliency;
  
  /// The maximum age of records before they're considered stale.
  Duration maxRecordAge;
  
  /// Whether to enable provider records.
  bool enableProviders;
  
  /// Whether to enable value records.
  bool enableValues;
  
  /// The provider store for storing provider records.
  dynamic providerStore;
  
  /// A filter for peers to query.
  QueryFilterFunc? queryPeerFilter;
  
  /// The number of concurrent lookups to perform.
  int lookupCheckConcurrency;
  
  /// A function that builds a message sender.
  MessageSenderBuilder? msgSenderBuilder;
  
  /// Configuration for the routing table.
  final RoutingTableConfig routingTable;
  
  /// A function that returns bootstrap peers.
  BootstrapPeersFunc? bootstrapPeers;
  
  /// A function that filters addresses.
  AddressFilterFunc? addressFilter;
  
  /// A hook that is called when a request is received.
  OnRequestHook? onRequestHook;
  
  /// Whether to disable fixing low peer counts.
  bool disableFixLowPeers;
  
  /// Whether to enable test address update processing.
  bool testAddressUpdateProcessing;
  
  /// Whether to enable optimistic providing.
  bool enableOptimisticProvide;
  
  /// The size of the optimistic provide jobs pool.
  int optimisticProvideJobsPoolSize;
  
  /// Creates a new DHT configuration.
  DhtConfig({
    this.datastore,
    required this.validator,
    this.validatorChanged = false,
    this.mode = DhtMode.server,
    this.protocolPrefix = defaultPrefix,
    this.v1ProtocolOverride,
    this.bucketSize = 20,
    this.concurrency = 10,
    this.resiliency = 3,
    this.maxRecordAge = const Duration(hours: 36),
    this.enableProviders = true,
    this.enableValues = true,
    this.providerStore,
    this.queryPeerFilter,
    this.lookupCheckConcurrency = 256,
    this.msgSenderBuilder,
    RoutingTableConfig? routingTable,
    this.bootstrapPeers,
    this.addressFilter,
    this.onRequestHook,
    this.disableFixLowPeers = false,
    this.testAddressUpdateProcessing = false,
    this.enableOptimisticProvide = false,
    this.optimisticProvideJobsPoolSize = 60,
  }) : routingTable = routingTable ?? RoutingTableConfig();
  
  /// Applies the given options to this configuration.
  void apply(List<DhtOption> options) {
    for (final option in options) {
      option(this);
    }
  }
  
  /// Applies fallback values that depend on other configuration parameters.
  void applyFallbacks(dynamic host) {
    if (!validatorChanged) {
      final nsval = validator as NamespacedValidator;
      if (nsval['pk'] == null) {
        nsval['pk'] = PublicKeyValidator();
      }
      if (nsval['ipns'] == null) {
        nsval['ipns'] = IpnsValidator(host.peerstore);
      }
    }
  }
  
  /// Validates the configuration.
  @mustCallSuper
  void validate() {
    // Configuration is validated and enforced only if prefix matches Amino DHT
    if (protocolPrefix != defaultPrefix) {
      return;
    }
    
    if (bucketSize != 20) {
      throw Exception('protocol prefix $defaultPrefix must use bucket size 20');
    }
    
    if (!enableProviders) {
      throw Exception('protocol prefix $defaultPrefix must have providers enabled');
    }
    
    if (!enableValues) {
      throw Exception('protocol prefix $defaultPrefix must have values enabled');
    }
    
    final nsval = validator as NamespacedValidator?;
    if (nsval == null) {
      throw Exception('protocol prefix $defaultPrefix must use a namespaced Validator');
    }
    
    if (nsval.length != 2) {
      throw Exception('protocol prefix $defaultPrefix must have exactly two namespaced validators - /pk and /ipns');
    }
    
    final pkVal = nsval['pk'];
    if (pkVal == null) {
      throw Exception('protocol prefix $defaultPrefix must support the /pk namespaced Validator');
    }
    if (pkVal is! PublicKeyValidator) {
      throw Exception('protocol prefix $defaultPrefix must use the PublicKeyValidator for the /pk namespace');
    }
    
    final ipnsVal = nsval['ipns'];
    if (ipnsVal == null) {
      throw Exception('protocol prefix $defaultPrefix must support the /ipns namespaced Validator');
    }
    if (ipnsVal is! IpnsValidator) {
      throw Exception('protocol prefix $defaultPrefix must use IpnsValidator for the /ipns namespace');
    }
  }
}

/// A function that modifies a DHT configuration.
typedef DhtOption = void Function(DhtConfig config);

// PublicKeyValidator class is now imported from ../../record/public_key_validator.dart
// IpnsValidator class is now imported from ../../record/ipns_validator.dart (will be created)

/// Returns true for all peers.
bool emptyQueryFilter(dynamic dht, PeerInfo peerInfo) => true;

/// Returns true for all peer IDs.
bool emptyRtFilter(dynamic dht, String peerId) => true;

/// The default DHT options.
DhtOption defaultDhtOptions = (DhtConfig config) {
  config.validator = NamespacedValidator();
  config.protocolPrefix = defaultPrefix;
  config.enableProviders = true;
  config.enableValues = true;
  config.queryPeerFilter = emptyQueryFilter;
  
  config.routingTable.latencyTolerance = const Duration(seconds: 10);
  config.routingTable.refreshQueryTimeout = const Duration(seconds: 10);
  config.routingTable.refreshInterval = const Duration(minutes: 10);
  config.routingTable.autoRefresh = true;
  config.routingTable.peerFilter = emptyRtFilter;
  
  config.bucketSize = 20;
  config.concurrency = 10;
  config.resiliency = 3;
  config.lookupCheckConcurrency = 256;
  
  // MAGIC: It makes sense to set it to a multiple of OptProvReturnRatio * BucketSize. We chose a multiple of 4.
  config.optimisticProvideJobsPoolSize = 60;
};
