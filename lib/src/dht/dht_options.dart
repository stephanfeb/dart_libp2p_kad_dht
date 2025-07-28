import 'dart:async';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/dht_v2.dart';
import 'package:dart_libp2p_kad_dht/src/record/namespace_validator.dart';

import '../amino/defaults.dart';
import '../internal/net/message_manager.dart' as net;
import '../pb/dht_message.dart';
import '../providers/provider_store.dart';
import '../record/validator.dart';
import '../rtrefresh/rt_refresh_manager.dart';
import 'dht.dart';

/// Interface for a message sender that can disconnect from peers.
abstract class MessageSenderWithDisconnect implements net.MessageSender {
  /// Disconnects from a peer.
  Future<void> disconnect(String peerId);
}

/// Mode options for the DHT
enum DHTMode {
  /// ModeAuto utilizes network events to dynamically switch the DHT
  /// between Client and Server modes based on network conditions
  auto,

  /// ModeClient operates the DHT as a client only, it cannot respond to incoming queries
  client,

  /// ModeServer operates the DHT as a server, it can both send and respond to queries
  server,

  /// ModeAutoServer operates in the same way as ModeAuto, but acts as a server when reachability is unknown
  autoServer,
}


/// Options for configuring the DHT
class DHTOptions {
  /// The mode of operation for the DHT
  final DHTMode mode;

  /// The bucket size for the routing table
  final int bucketSize;

  /// The number of concurrent requests to make during lookups
  final int concurrency;

  /// The number of closest peers to return in response to a query
  final int resiliency;

  /// The time that a provider record should last before expiring
  final Duration provideValidity;

  /// The TTL to keep the multi addresses of provider peers around
  final Duration providerAddrTTL;

  /// Whether to automatically refresh the routing table
  final bool autoRefresh;

  /// Optional list of bootstrap peer multiaddresses
  final List<MultiAddr>? bootstrapPeers;

  /// The maximum number of retry attempts for a DHT message.
  final int maxRetryAttempts;

  /// The initial backoff delay for retrying a DHT message.
  final Duration retryInitialBackoff;

  /// The maximum backoff delay for retrying a DHT message.
  final Duration retryMaxBackoff;

  /// The backoff factor for retrying a DHT message.
  final double retryBackoffFactor;

  /// Whether to filter localhost addresses from FIND_NODE responses
  final bool filterLocalhostInResponses;

  /// Creates new DHT options
  const DHTOptions({
    this.mode = DHTMode.auto,
    this.bucketSize = AminoConstants.defaultBucketSize,
    this.concurrency = AminoConstants.defaultConcurrency,
    this.resiliency = AminoConstants.defaultResiliency,
    this.provideValidity = AminoConstants.defaultProvideValidity,
    this.providerAddrTTL = AminoConstants.defaultProviderAddrTTL,
    this.autoRefresh = true,
    this.bootstrapPeers, // Added
    this.maxRetryAttempts = 3,
    this.retryInitialBackoff = const Duration(milliseconds: 500),
    this.retryMaxBackoff = const Duration(seconds: 30),
    this.retryBackoffFactor = 2.0,
    this.filterLocalhostInResponses = true,
  });
}

/// Configuration for the DHT
class DHTConfig {
  /// The mode of operation for the DHT
  DHTMode mode;

  /// The datastore for the DHT
  dynamic datastore;

  /// The provider store for the DHT
  ProviderStore? providerStore;

  /// The validator for records
  Validator validator;

  /// Whether the validator has been changed from the default
  bool validatorChanged = false;

  /// The protocol prefix for the DHT
  ProtocolID protocolPrefix;

  /// Override for the v1 protocol
  ProtocolID? v1ProtocolOverride;

  /// The bucket size for the routing table
  int bucketSize;

  /// The concurrency level for queries
  int concurrency;

  /// The resiliency level for queries
  int resiliency;

  /// The maximum acceptable latency for peers in the routing table
  Duration routingTableLatencyTolerance;

  /// The refresh interval for the routing table
  Duration routingTableRefreshInterval;

  /// The timeout for routing table refresh queries
  Duration routingTableRefreshQueryTimeout;

  /// Whether to automatically refresh the routing table
  bool routingTableAutoRefresh;

  /// The filter for peers in the routing table
  RouteTableFilterFunc? routingTablePeerFilter;

  /// The diversity filter for the routing table
  dynamic routingTableDiversityFilter;

  /// The maximum age for records
  Duration maxRecordAge;

  /// Whether to enable providers
  bool enableProviders;

  /// Whether to enable values
  bool enableValues;

  /// The filter for peers to query
  QueryFilterFunc? queryPeerFilter;

  /// Function to get bootstrap peers
  List<AddrInfo> Function()? bootstrapPeers;

  /// The lookup check concurrency
  int lookupCheckConcurrency;

  /// Whether to enable optimistic provide
  bool enableOptimisticProvide;

  /// The pool size for optimistic provide jobs
  int optimisticProvideJobsPoolSize;

  /// The filter for addresses
  List<MultiAddr> Function(List<MultiAddr>)? addressFilter;

  /// The builder for message senders
  MessageSenderBuilder? msgSenderBuilder;

  /// Hook for incoming requests
  void Function(dynamic, Stream, Message)? onRequestHook;

  /// Whether to disable fixing low peers (for tests only)
  bool disableFixLowPeers;

  /// Whether to force address update processing (for tests only)
  bool testAddressUpdateProcessing;

  /// The maximum number of retry attempts for a DHT message.
  int maxDhtMessageRetryAttempts;

  /// The initial backoff delay for retrying a DHT message.
  Duration dhtMessageRetryInitialBackoff;

  /// The maximum backoff delay for retrying a DHT message.
  Duration dhtMessageRetryMaxBackoff;

  /// The backoff factor for retrying a DHT message.
  double dhtMessageRetryBackoffFactor;

  /// Whether to filter localhost addresses from FIND_NODE responses
  bool filterLocalhostInResponses;

  /// Maximum number of peers per k-bucket (for bootstrap server capacity)
  int maxPeersPerBucket;

  /// Maximum size of the routing table (total peers across all buckets)
  int maxRoutingTableSize;

  /// Creates a new DHT configuration with default values
  DHTConfig({
    this.mode = DHTMode.auto,
    this.datastore,
    this.providerStore,
    Validator? validator,
    this.protocolPrefix = AminoConstants.protocolPrefix,
    this.v1ProtocolOverride,
    this.bucketSize = AminoConstants.defaultBucketSize,
    this.concurrency = AminoConstants.defaultConcurrency,
    this.resiliency = AminoConstants.defaultResiliency,
    this.routingTableLatencyTolerance = AminoConstants.defaultMaxLatency,
    this.routingTableRefreshInterval = AminoConstants.defaultRefreshInterval,
    this.routingTableRefreshQueryTimeout = AminoConstants.defaultRefreshQueryTimeout,
    this.routingTableAutoRefresh = true,
    this.routingTablePeerFilter,
    this.routingTableDiversityFilter,
    this.maxRecordAge = AminoConstants.defaultRecordTTL,
    this.enableProviders = true,
    this.enableValues = true,
    this.queryPeerFilter,
    this.bootstrapPeers,
    this.lookupCheckConcurrency = AminoConstants.defaultLookupCheckConcurrency,
    this.enableOptimisticProvide = false,
    this.optimisticProvideJobsPoolSize = AminoConstants.defaultOptimisticProvideJobsPoolSize,
    this.addressFilter,
    this.msgSenderBuilder,
    this.onRequestHook,
    this.disableFixLowPeers = false,
    this.testAddressUpdateProcessing = false,
    this.maxDhtMessageRetryAttempts = 3,
    this.dhtMessageRetryInitialBackoff = const Duration(milliseconds: 500),
    this.dhtMessageRetryMaxBackoff = const Duration(seconds: 30),
    this.dhtMessageRetryBackoffFactor = 2.0,
    this.filterLocalhostInResponses = true,
    this.maxPeersPerBucket = 20,
    this.maxRoutingTableSize = 1000,
  }) : validator = validator ?? NamespacedValidator();
}

/// Type definition for a function that filters peers for queries
typedef QueryFilterFunc = bool Function(dynamic dht, AddrInfo peerInfo);

/// Type definition for a function that filters peers for the routing table
typedef RouteTableFilterFunc = bool Function(dynamic dht, PeerId peerId);

/// Type definition for a function that builds message senders
typedef MessageSenderBuilder = MessageSenderWithDisconnect Function(Host host, List<ProtocolID> protocols);

/// Type definition for a DHT option function
typedef DHTOption = FutureOr<void> Function(DHTConfig config);

/// ProviderStore sets the provider storage manager.
DHTOption providerStore(ProviderStore ps) {
  return (config) {
    config.providerStore = ps;
  };
}

/// RoutingTableLatencyTolerance sets the maximum acceptable latency for peers
/// in the routing table's cluster.
DHTOption routingTableLatencyTolerance(Duration latency) {
  return (config) {
    config.routingTableLatencyTolerance = latency;
  };
}

/// RoutingTableRefreshQueryTimeout sets the timeout for routing table refresh
/// queries.
DHTOption routingTableRefreshQueryTimeout(Duration timeout) {
  return (config) {
    config.routingTableRefreshQueryTimeout = timeout;
  };
}

/// RoutingTableRefreshPeriod sets the period for refreshing buckets in the
/// routing table. The DHT will refresh buckets every period by:
///
/// 1. First searching for nearby peers to figure out how many buckets we should try to fill.
/// 2. Then searching for a random key in each bucket that hasn't been queried in
///    the last refresh period.
DHTOption routingTableRefreshPeriod(Duration period) {
  return (config) {
    config.routingTableRefreshInterval = period;
  };
}

/// Datastore configures the DHT to use the specified datastore.
///
/// Defaults to an in-memory (temporary) map.
DHTOption datastore(dynamic ds) {
  return (config) {
    config.datastore = ds;
  };
}

/// Mode configures which mode the DHT operates in (Client, Server, Auto).
///
/// Defaults to DHTMode.auto.
DHTOption mode(DHTMode m) {
  return (config) {
    config.mode = m;
  };
}

/// Validator configures the DHT to use the specified validator.
///
/// Defaults to a namespaced validator that can validate both public key (under the "pk"
/// namespace) and IPNS records (under the "ipns" namespace). Setting the validator
/// implies that the user wants to control the validators and therefore the default
/// public key and IPNS validators will not be added.
DHTOption validator(Validator v) {
  return (config) {
    config.validator = v;
    config.validatorChanged = true;
  };
}

/// NamespacedValidator adds a validator namespaced under `ns`. This option fails
/// if the DHT is not using a `NamespacedValidator` as its validator (it
/// uses one by default but this can be overridden with the `Validator` option).
/// Adding a namespaced validator without changing the `Validator` will result in
/// adding a new validator in addition to the default public key and IPNS validators.
/// The "pk" and "ipns" namespaces cannot be overridden here unless a new `Validator`
/// has been set first.
///
/// Example: Given a validator registered as `namespacedValidator("ipns",
/// myValidator)`, all records with keys starting with `/ipns/` will be validated
/// with `myValidator`.
DHTOption namespacedValidator(String ns, Validator v) {
  return (config) {
    if (config.validator is! NamespacedValidator) {
      throw Exception('can only add namespaced validators to a NamespacedValidator');
    }
    (config.validator as NamespacedValidator).addValidator(ns, v);
  };
}

/// ProtocolPrefix sets an application specific prefix to be attached to all DHT protocols. For example,
/// /myapp/kad/1.0.0 instead of /ipfs/kad/1.0.0. Prefix should be of the form /myapp.
///
/// Defaults to AminoConstants.protocolPrefix
DHTOption protocolPrefix(ProtocolID prefix) {
  return (config) {
    config.protocolPrefix = prefix;
  };
}

/// ProtocolExtension adds an application specific protocol to the DHT protocol. For example,
/// /ipfs/lan/kad/1.0.0 instead of /ipfs/kad/1.0.0. extension should be of the form /lan.
DHTOption protocolExtension(ProtocolID ext) {
  return (config) {
    config.protocolPrefix += ext;
  };
}

/// V1ProtocolOverride overrides the protocolID used for /kad/1.0.0 with another. This is an
/// advanced feature, and should only be used to handle legacy networks that have not been
/// using protocolIDs of the form /app/kad/1.0.0.
///
/// This option will override and ignore the ProtocolPrefix and ProtocolExtension options
DHTOption v1ProtocolOverride(ProtocolID proto) {
  return (config) {
    config.v1ProtocolOverride = proto;
  };
}

/// BucketSize configures the bucket size (k in the Kademlia paper) of the routing table.
///
/// The default value is AminoConstants.defaultBucketSize
DHTOption bucketSize(int size) {
  return (config) {
    config.bucketSize = size;
  };
}

/// Concurrency configures the number of concurrent requests (alpha in the Kademlia paper) for a given query path.
///
/// The default value is AminoConstants.defaultConcurrency
DHTOption concurrency(int alpha) {
  return (config) {
    config.concurrency = alpha;
  };
}

/// Resiliency configures the number of peers closest to a target that must have responded in order for a given query
/// path to complete.
///
/// The default value is AminoConstants.defaultResiliency
DHTOption resiliency(int beta) {
  return (config) {
    config.resiliency = beta;
  };
}

/// LookupCheckConcurrency configures maximal number of go routines that can be used to
/// perform a lookup check operation, before adding a new node to the routing table.
DHTOption lookupCheckConcurrency(int n) {
  return (config) {
    config.lookupCheckConcurrency = n;
  };
}

/// MaxRecordAge specifies the maximum time that any node will hold onto a record ("PutValue record")
/// from the time its received. This does not apply to any other forms of validity that
/// the record may contain.
/// For example, a record may contain an ipns entry with an EOL saying its valid
/// until the year 2020 (a great time in the future). For that record to stick around
/// it must be rebroadcasted more frequently than once every 'MaxRecordAge'
DHTOption maxRecordAge(Duration maxAge) {
  return (config) {
    config.maxRecordAge = maxAge;
  };
}

/// DisableAutoRefresh completely disables 'auto-refresh' on the DHT routing
/// table. This means that we will neither refresh the routing table periodically
/// nor when the routing table size goes below the minimum threshold.
DHTOption disableAutoRefresh() {
  return (config) {
    config.routingTableAutoRefresh = false;
  };
}

/// DisableProviders disables storing and retrieving provider records.
///
/// Defaults to enabled.
///
/// WARNING: do not change this unless you're using a forked DHT (i.e., a private
/// network and/or distinct DHT protocols with the `Protocols` option).
DHTOption disableProviders() {
  return (config) {
    config.enableProviders = false;
  };
}

/// DisableValues disables storing and retrieving value records (including
/// public keys).
///
/// Defaults to enabled.
///
/// WARNING: do not change this unless you're using a forked DHT (i.e., a private
/// network and/or distinct DHT protocols with the `Protocols` option).
DHTOption disableValues() {
  return (config) {
    config.enableValues = false;
  };
}

/// QueryFilter sets a function that approves which peers may be dialed in a query
DHTOption queryFilter(QueryFilterFunc filter) {
  return (config) {
    config.queryPeerFilter = filter;
  };
}

/// RoutingTableFilter sets a function that approves which peers may be added to the routing table. The host should
/// already have at least one connection to the peer under consideration.
DHTOption routingTableFilter(RouteTableFilterFunc filter) {
  return (config) {
    config.routingTablePeerFilter = filter;
  };
}

/// BootstrapPeers configures the bootstrapping nodes that we will connect to to seed
/// and refresh our Routing Table if it becomes empty.
DHTOption bootstrapPeers(List<AddrInfo> bootstrappers) {
  return (config) {
    config.bootstrapPeers = () => bootstrappers;
  };
}

/// BootstrapPeersFunc configures the function that returns the bootstrapping nodes that we will
/// connect to to seed and refresh our Routing Table if it becomes empty.
DHTOption bootstrapPeersFunc(List<AddrInfo> Function() getBootstrapPeers) {
  return (config) {
    config.bootstrapPeers = getBootstrapPeers;
  };
}

/// RoutingTablePeerDiversityFilter configures the implementation of the diversity filter for the Routing Table.
DHTOption routingTablePeerDiversityFilter(dynamic pg) {
  return (config) {
    config.routingTableDiversityFilter = pg;
  };
}

/// EnableOptimisticProvide enables an optimization that skips the last hops of the provide process.
/// This works by using the network size estimator (which uses the keyspace density of queries)
/// to optimistically send ADD_PROVIDER requests when we most likely have found the last hop.
/// It will also run some ADD_PROVIDER requests asynchronously in the background after returning,
/// this allows to optimistically return earlier if some threshold number of RPCs have succeeded.
/// The number of background/in-flight queries can be configured with the OptimisticProvideJobsPoolSize
/// option.
///
/// EXPERIMENTAL: This is an experimental option and might be removed in the future. Use at your own risk.
DHTOption enableOptimisticProvide() {
  return (config) {
    config.enableOptimisticProvide = true;
  };
}

/// OptimisticProvideJobsPoolSize allows to configure the asynchronicity limit for in-flight ADD_PROVIDER RPCs.
/// It makes sense to set it to a multiple of optProvReturnRatio * BucketSize. Check the description of
/// EnableOptimisticProvide for more details.
///
/// EXPERIMENTAL: This is an experimental option and might be removed in the future. Use at your own risk.
DHTOption optimisticProvideJobsPoolSize(int size) {
  return (config) {
    config.optimisticProvideJobsPoolSize = size;
  };
}

/// AddressFilter allows to configure the address filtering function.
/// This function is run before addresses are added to the peerstore.
/// It is most useful to avoid adding localhost / local addresses.
DHTOption addressFilter(List<MultiAddr> Function(List<MultiAddr>) f) {
  return (config) {
    config.addressFilter = f;
  };
}

/// WithCustomMessageSender configures the MessageSender of the DHT to use the
/// custom implementation of the MessageSender
DHTOption withCustomMessageSender(MessageSenderBuilder messageSenderBuilder) {
  return (config) {
    config.msgSenderBuilder = messageSenderBuilder;
  };
}

/// OnRequestHook registers a callback function that will be invoked for every
/// incoming DHT protocol message.
/// Note: Ensure that the callback executes efficiently, as it will block the
/// entire message handler.
DHTOption onRequestHook(void Function(dynamic ctx, Stream s, Message req) f) {
  return (config) {
    config.onRequestHook = f;
  };
}

/// MaxDhtMessageRetries configures the maximum number of attempts for sending a DHT message.
DHTOption maxDhtMessageRetries(int count) {
  return (config) {
    config.maxDhtMessageRetryAttempts = count;
  };
}

/// DhtMessageRetryInitialBackoff configures the initial delay before retrying a DHT message.
DHTOption dhtMessageRetryInitialBackoff(Duration delay) {
  return (config) {
    config.dhtMessageRetryInitialBackoff = delay;
  };
}

/// DhtMessageRetryMaxBackoff configures the maximum delay between DHT message retries.
DHTOption dhtMessageRetryMaxBackoff(Duration delay) {
  return (config) {
    config.dhtMessageRetryMaxBackoff = delay;
  };
}

/// DhtMessageRetryBackoffFactor configures the multiplicative factor for DHT message retry backoff.
DHTOption dhtMessageRetryBackoffFactor(double factor) {
  return (config) {
    config.dhtMessageRetryBackoffFactor = factor;
  };
}

/// FilterLocalhostInResponses configures whether to filter localhost addresses from FIND_NODE responses.
/// This prevents advertising 127.0.0.1 addresses to remote peers, which are not useful for them.
/// 
/// Defaults to true for security and network health.
DHTOption filterLocalhostInResponses(bool filter) {
  return (config) {
    config.filterLocalhostInResponses = filter;
  };
}

/// MaxPeersPerBucket configures the maximum number of peers per k-bucket.
/// This is particularly useful for controlling bootstrap server capacity.
///
/// Defaults to 20.
DHTOption maxPeersPerBucket(int count) {
  return (config) {
    config.maxPeersPerBucket = count;
  };
}

/// MaxRoutingTableSize configures the maximum size of the routing table.
/// This limits the total number of peers across all buckets, which is useful
/// for mobile devices with limited resources.
///
/// Defaults to 1000 (mobile-friendly).
DHTOption maxRoutingTableSize(int size) {
  return (config) {
    config.maxRoutingTableSize = size;
  };
}

/// RefreshInterval configures the refresh interval for the routing table.
/// This is a convenience function that sets the routingTableRefreshInterval.
///
/// Defaults to Duration(minutes: 15).
DHTOption refreshInterval(Duration interval) {
  return (config) {
    config.routingTableRefreshInterval = interval;
  };
}

/// DHT builder class that provides functional configuration similar to libp2p host configuration
class DHT {
  /// Private constructor to prevent direct instantiation
  DHT._();

  /// Creates a new DHT instance with functional configuration options
  /// 
  /// Example usage:
  /// ```dart
  /// final dhtOptions = <DHTOption>[
  ///   mode(DHTMode.server),
  ///   bucketSize(25),
  ///   maxPeersPerBucket(30),
  ///   maxRoutingTableSize(2000),
  ///   refreshInterval(const Duration(minutes: 3)),
  ///   bootstrapPeers([
  ///     AddrInfo(peerId1, [addr1]),
  ///     AddrInfo(peerId2, [addr2]),
  ///   ]),
  ///   enableOptimisticProvide(),
  /// ];
  /// 
  /// final dht = await DHT.new_(host, providerStore, dhtOptions);
  /// ```
  static Future<IpfsDHTv2> new_(
    Host host,
    ProviderStore providerStore,
    List<DHTOption> options, {
    NamespacedValidator? validator,
  }) async {
    // Create a default configuration
    final config = DHTConfig();
    
    // Apply all the functional options to the configuration
    for (final option in options) {
      await option(config);
    }
    
    // Convert DHTConfig to DHTOptions for the current constructor
    final dhtOptions = _configToOptions(config);

    // Create the DHT instance
    final dht = IpfsDHTv2(
      host: host,
      providerStore: providerStore,
      options: dhtOptions,
      validator: validator ?? (config.validator is NamespacedValidator 
          ? config.validator as NamespacedValidator 
          : null),
    );


    return dht;
  }
  
  /// Converts a DHTConfig to DHTOptions for backward compatibility
  static DHTOptions _configToOptions(DHTConfig config) {
    // Convert bootstrap peers function to MultiAddr list
    List<MultiAddr>? bootstrapPeers;
    if (config.bootstrapPeers != null) {
      final addrInfos = config.bootstrapPeers!();
      bootstrapPeers = addrInfos
          .expand((addrInfo) => addrInfo.addrs)
          .map((addr) {
            // Add peer ID to the multiaddr if it doesn't have one
            final addrStr = addr.toString();
            if (!addrStr.contains('/p2p/')) {
              final peerIdFromAddrInfo = addrInfos
                  .firstWhere((ai) => ai.addrs.contains(addr))
                  .id;
              return MultiAddr('$addrStr/p2p/${peerIdFromAddrInfo.toBase58()}');
            }
            return addr;
          })
          .toList();
    }
    
    return DHTOptions(
      mode: config.mode,
      bucketSize: config.bucketSize,
      concurrency: config.concurrency,
      resiliency: config.resiliency,
      provideValidity: AminoConstants.defaultProvideValidity, // Use default since not in config
      providerAddrTTL: AminoConstants.defaultProviderAddrTTL, // Use default since not in config
      autoRefresh: config.routingTableAutoRefresh,
      bootstrapPeers: bootstrapPeers,
      maxRetryAttempts: config.maxDhtMessageRetryAttempts,
      retryInitialBackoff: config.dhtMessageRetryInitialBackoff,
      retryMaxBackoff: config.dhtMessageRetryMaxBackoff,
      retryBackoffFactor: config.dhtMessageRetryBackoffFactor,
      filterLocalhostInResponses: config.filterLocalhostInResponses,
    );
  }
}
