import 'dart:async';

import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import '../../dht_options.dart';
import '../../../amino/defaults.dart';

/// Unified configuration for DHT v2
/// 
/// This replaces the dual DHTOptions/DHTConfig system with a single,
/// comprehensive configuration approach that supports both simple
/// and advanced use cases.
class DHTConfigV2 {
  // Core settings
  final DHTMode mode;
  final int bucketSize;
  final int concurrency;
  final int resiliency;
  final Duration provideValidity;
  final Duration providerAddrTTL;
  final bool autoRefresh;
  
  // Network settings
  final List<MultiAddr>? bootstrapPeers;
  final int maxRetryAttempts;
  final Duration retryInitialBackoff;
  final Duration retryMaxBackoff;
  final double retryBackoffFactor;
  final bool filterLocalhostInResponses;
  final Duration networkTimeout;
  
  // Routing settings
  final Duration refreshInterval;
  final Duration maxLatency;
  final int maxPeersPerBucket;
  final int maxRoutingTableSize;
  
  // Query settings
  final Duration queryTimeout;
  final int maxConcurrentQueries;
  final bool optimisticProvide;
  
  // Monitoring settings
  final bool enableMetrics;
  final Duration metricsInterval;
  
  const DHTConfigV2({
    // Core settings
    this.mode = DHTMode.auto,
    this.bucketSize = AminoConstants.defaultBucketSize,
    this.concurrency = AminoConstants.defaultConcurrency,
    this.resiliency = AminoConstants.defaultResiliency,
    this.provideValidity = AminoConstants.defaultProvideValidity,
    this.providerAddrTTL = AminoConstants.defaultProviderAddrTTL,
    this.autoRefresh = true,
    
    // Network settings
    this.bootstrapPeers,
    this.maxRetryAttempts = 3,
    this.retryInitialBackoff = const Duration(milliseconds: 500),
    this.retryMaxBackoff = const Duration(seconds: 30),
    this.retryBackoffFactor = 2.0,
    this.filterLocalhostInResponses = true,
    this.networkTimeout = const Duration(seconds: 30),
    
    // Routing settings
    this.refreshInterval = const Duration(minutes: 15),
    this.maxLatency = AminoConstants.defaultMaxLatency,
    this.maxPeersPerBucket = 20,
    this.maxRoutingTableSize = 1000,
    
    // Query settings
    this.queryTimeout = const Duration(seconds: 60),
    this.maxConcurrentQueries = 10,
    this.optimisticProvide = false,
    
    // Monitoring settings
    this.enableMetrics = true,
    this.metricsInterval = const Duration(minutes: 1),
  });
  
  /// Creates a DHTConfigV2 from the legacy DHTOptions
  /// 
  /// This ensures backward compatibility with existing code
  factory DHTConfigV2.fromOptions(DHTOptions options) {
    return DHTConfigV2(
      mode: options.mode,
      bucketSize: options.bucketSize,
      concurrency: options.concurrency,
      resiliency: options.resiliency,
      provideValidity: options.provideValidity,
      providerAddrTTL: options.providerAddrTTL,
      autoRefresh: options.autoRefresh,
      bootstrapPeers: options.bootstrapPeers,
      maxRetryAttempts: options.maxRetryAttempts,
      retryInitialBackoff: options.retryInitialBackoff,
      retryMaxBackoff: options.retryMaxBackoff,
      retryBackoffFactor: options.retryBackoffFactor,
      filterLocalhostInResponses: options.filterLocalhostInResponses,
    );
  }
  
  /// Converts back to legacy DHTOptions for compatibility
  DHTOptions toOptions() {
    return DHTOptions(
      mode: mode,
      bucketSize: bucketSize,
      concurrency: concurrency,
      resiliency: resiliency,
      provideValidity: provideValidity,
      providerAddrTTL: providerAddrTTL,
      autoRefresh: autoRefresh,
      bootstrapPeers: bootstrapPeers,
      maxRetryAttempts: maxRetryAttempts,
      retryInitialBackoff: retryInitialBackoff,
      retryMaxBackoff: retryMaxBackoff,
      retryBackoffFactor: retryBackoffFactor,
      filterLocalhostInResponses: filterLocalhostInResponses,
    );
  }
  
  /// Creates a new config with updated values
  DHTConfigV2 copyWith({
    DHTMode? mode,
    int? bucketSize,
    int? concurrency,
    int? resiliency,
    Duration? provideValidity,
    Duration? providerAddrTTL,
    bool? autoRefresh,
    List<MultiAddr>? bootstrapPeers,
    int? maxRetryAttempts,
    Duration? retryInitialBackoff,
    Duration? retryMaxBackoff,
    double? retryBackoffFactor,
    bool? filterLocalhostInResponses,
    Duration? networkTimeout,
    Duration? refreshInterval,
    Duration? maxLatency,
    int? maxPeersPerBucket,
    int? maxRoutingTableSize,
    Duration? queryTimeout,
    int? maxConcurrentQueries,
    bool? optimisticProvide,
    bool? enableMetrics,
    Duration? metricsInterval,
  }) {
    return DHTConfigV2(
      mode: mode ?? this.mode,
      bucketSize: bucketSize ?? this.bucketSize,
      concurrency: concurrency ?? this.concurrency,
      resiliency: resiliency ?? this.resiliency,
      provideValidity: provideValidity ?? this.provideValidity,
      providerAddrTTL: providerAddrTTL ?? this.providerAddrTTL,
      autoRefresh: autoRefresh ?? this.autoRefresh,
      bootstrapPeers: bootstrapPeers ?? this.bootstrapPeers,
      maxRetryAttempts: maxRetryAttempts ?? this.maxRetryAttempts,
      retryInitialBackoff: retryInitialBackoff ?? this.retryInitialBackoff,
      retryMaxBackoff: retryMaxBackoff ?? this.retryMaxBackoff,
      retryBackoffFactor: retryBackoffFactor ?? this.retryBackoffFactor,
      filterLocalhostInResponses: filterLocalhostInResponses ?? this.filterLocalhostInResponses,
      networkTimeout: networkTimeout ?? this.networkTimeout,
      refreshInterval: refreshInterval ?? this.refreshInterval,
      maxLatency: maxLatency ?? this.maxLatency,
      maxPeersPerBucket: maxPeersPerBucket ?? this.maxPeersPerBucket,
      maxRoutingTableSize: maxRoutingTableSize ?? this.maxRoutingTableSize,
      queryTimeout: queryTimeout ?? this.queryTimeout,
      maxConcurrentQueries: maxConcurrentQueries ?? this.maxConcurrentQueries,
      optimisticProvide: optimisticProvide ?? this.optimisticProvide,
      enableMetrics: enableMetrics ?? this.enableMetrics,
      metricsInterval: metricsInterval ?? this.metricsInterval,
    );
  }
  
  @override
  String toString() => 'DHTConfigV2(mode: $mode, bucketSize: $bucketSize, concurrency: $concurrency)';
}

/// Builder for creating DHT configuration
/// 
/// Provides a fluent API for configuration:
/// ```dart
/// final config = DHTConfigBuilder()
///   .mode(DHTMode.server)
///   .bucketSize(25)
///   .filterLocalhost(false)
///   .build();
/// ```
class DHTConfigBuilder {
  DHTMode _mode = DHTMode.auto;
  int _bucketSize = AminoConstants.defaultBucketSize;
  int _concurrency = AminoConstants.defaultConcurrency;
  int _resiliency = AminoConstants.defaultResiliency;
  Duration _provideValidity = AminoConstants.defaultProvideValidity;
  Duration _providerAddrTTL = AminoConstants.defaultProviderAddrTTL;
  bool _autoRefresh = true;
  List<MultiAddr>? _bootstrapPeers;
  int _maxRetryAttempts = 3;
  Duration _retryInitialBackoff = const Duration(milliseconds: 500);
  Duration _retryMaxBackoff = const Duration(seconds: 30);
  double _retryBackoffFactor = 2.0;
  bool _filterLocalhostInResponses = true;
  Duration _networkTimeout = const Duration(seconds: 30);
  Duration _refreshInterval = const Duration(minutes: 15);
  Duration _maxLatency = AminoConstants.defaultMaxLatency;
  int _maxPeersPerBucket = 20;
  int _maxRoutingTableSize = 1000;
  Duration _queryTimeout = const Duration(seconds: 60);
  int _maxConcurrentQueries = 10;
  bool _optimisticProvide = false;
  bool _enableMetrics = true;
  Duration _metricsInterval = const Duration(minutes: 1);
  
  DHTConfigBuilder mode(DHTMode mode) {
    _mode = mode;
    return this;
  }
  
  DHTConfigBuilder bucketSize(int size) {
    _bucketSize = size;
    return this;
  }
  
  DHTConfigBuilder concurrency(int concurrency) {
    _concurrency = concurrency;
    return this;
  }
  
  DHTConfigBuilder resiliency(int resiliency) {
    _resiliency = resiliency;
    return this;
  }
  
  DHTConfigBuilder filterLocalhost(bool filter) {
    _filterLocalhostInResponses = filter;
    return this;
  }
  
  DHTConfigBuilder bootstrapPeers(List<MultiAddr> peers) {
    _bootstrapPeers = peers;
    return this;
  }
  
  DHTConfigBuilder networkTimeout(Duration timeout) {
    _networkTimeout = timeout;
    return this;
  }
  
  DHTConfigBuilder queryTimeout(Duration timeout) {
    _queryTimeout = timeout;
    return this;
  }
  
  DHTConfigBuilder enableMetrics(bool enable) {
    _enableMetrics = enable;
    return this;
  }
  
  DHTConfigBuilder optimisticProvide(bool enable) {
    _optimisticProvide = enable;
    return this;
  }
  
  DHTConfigV2 build() {
    return DHTConfigV2(
      mode: _mode,
      bucketSize: _bucketSize,
      concurrency: _concurrency,
      resiliency: _resiliency,
      provideValidity: _provideValidity,
      providerAddrTTL: _providerAddrTTL,
      autoRefresh: _autoRefresh,
      bootstrapPeers: _bootstrapPeers,
      maxRetryAttempts: _maxRetryAttempts,
      retryInitialBackoff: _retryInitialBackoff,
      retryMaxBackoff: _retryMaxBackoff,
      retryBackoffFactor: _retryBackoffFactor,
      filterLocalhostInResponses: _filterLocalhostInResponses,
      networkTimeout: _networkTimeout,
      refreshInterval: _refreshInterval,
      maxLatency: _maxLatency,
      maxPeersPerBucket: _maxPeersPerBucket,
      maxRoutingTableSize: _maxRoutingTableSize,
      queryTimeout: _queryTimeout,
      maxConcurrentQueries: _maxConcurrentQueries,
      optimisticProvide: _optimisticProvide,
      enableMetrics: _enableMetrics,
      metricsInterval: _metricsInterval,
    );
  }
} 