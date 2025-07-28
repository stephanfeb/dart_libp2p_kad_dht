/// Package amino provides protocol parameters and suggested default values for the Amino DHT.
///
/// Amino DHT is an implementation of the Kademlia distributed hash table (DHT) algorithm,
/// originally designed for use in IPFS (InterPlanetary File System) network.
/// This file defines key constants and protocol identifiers used in the Amino DHT implementation.

import 'dart:core';

/// Protocol identifier type
typedef ProtocolID = String;

/// Protocol constants for the Amino DHT
class AminoConstants {
  /// Private constructor to prevent instantiation
  AminoConstants._();

  /// ProtocolPrefix is the base prefix for Amino DHT protocols.
  static const ProtocolID protocolPrefix = '/ipfs';

  /// ProtocolID is the latest protocol identifier for the Amino DHT.
  static const ProtocolID protocolID = '/ipfs/kad/1.0.0';

  /// DefaultBucketSize is the Amino DHT bucket size (k in the Kademlia paper).
  /// It represents the maximum number of peers stored in each
  /// k-bucket of the routing table.
  static const int defaultBucketSize = 20;

  /// DefaultConcurrency is the suggested number of concurrent requests (alpha
  /// in the Kademlia paper) for a given query path in Amino DHT. It
  /// determines how many parallel lookups are performed during network
  /// traversal.
  static const int defaultConcurrency = 10;

  /// DefaultResiliency is the suggested number of peers closest to a target
  /// that must have responded in order for a given query path to complete in
  /// Amino DHT. This helps ensure reliable results by requiring multiple
  /// confirmations.
  static const int defaultResiliency = 3;

  /// DefaultProvideValidity is the default time that a Provider Record should
  /// last on Amino DHT before it needs to be refreshed or removed. This value
  /// is also known as Provider Record Expiration Interval.
  static const Duration defaultProvideValidity = Duration(hours: 48);

  /// DefaultProviderAddrTTL is the TTL to keep the multi addresses of
  /// provider peers around. Those addresses are returned alongside provider.
  /// After it expires, the returned records will require an extra lookup, to
  /// find the multiaddress associated with the returned peer id.
  static const Duration defaultProviderAddrTTL = Duration(hours: 24);

  /// DefaultMaxPeersPerIPGroup is the maximal number of peers with addresses in
  /// the same IP group allowed in the routing table. Once this limit is
  /// reached, newly discovered peers with addresses in the same IP group will
  /// not be added to the routing table.
  static const int defaultMaxPeersPerIPGroup = 3;

  /// DefaultMaxPeersPerIPGroupPerCpl is maximal number of peers with addresses
  /// in the same IP group allowed in each routing table bucket, defined by its
  /// common prefix length to self peer id.
  /// also see: `DefaultMaxPeersPerIPGroup`.
  static const int defaultMaxPeersPerIPGroupPerCpl = 2;

  /// ServerModeMinPeers is the minimum number of peers required in the routing table
  /// for the DHT to switch to server mode when in auto mode.
  static const int serverModeMinPeers = 4;

  /// DefaultMaxLatency is the maximum acceptable latency for peers in the routing table.
  /// Peers with higher latency will not be added to the routing table.
  static const Duration defaultMaxLatency = Duration(seconds: 10);

  /// DefaultUsefulnessGracePeriod is the period after which a peer is considered
  /// not useful if it hasn't been useful during this time.
  static const Duration defaultUsefulnessGracePeriod = Duration(hours: 1);

  static const Duration defaultRefreshInterval = Duration(minutes: 15);

  /// DefaultRefreshQueryTimeout is the timeout for routing table refresh queries.
  static const Duration defaultRefreshQueryTimeout = Duration(seconds: 10);

  /// DefaultRecordTTL is the maximum time that any node will hold onto a record
  /// from the time it's received. This is the same as DefaultProvideValidity.
  static const Duration defaultRecordTTL = Duration(hours: 48);

  /// DefaultLookupCheckConcurrency is the maximal number of routines that can be used
  /// to perform a lookup check operation, before adding a new node to the routing table.
  static const int defaultLookupCheckConcurrency = 256;

  /// DefaultOptimisticProvideJobsPoolSize is the asynchronicity limit for in-flight
  /// ADD_PROVIDER RPCs. It's set to a multiple of OptProvReturnRatio * BucketSize.
  static const int defaultOptimisticProvideJobsPoolSize = 60;
  }

/// Protocols is a list containing all supported protocol IDs for Amino DHT.
/// Currently, it only includes the main ProtocolID, but it's defined as a list
/// to allow for potential future protocol versions or variants.
final List<ProtocolID> protocols = [AminoConstants.protocolID];
