import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:logging/logging.dart';

import '../config/dht_config.dart';

/// Metrics data structure for DHT operations
class DHTMetrics {
  // Query metrics
  final int totalQueries;
  final int successfulQueries;
  final int failedQueries;
  final Duration averageQueryLatency;
  final Duration maxQueryLatency;
  final Duration minQueryLatency;
  
  // Network metrics
  final int totalNetworkRequests;
  final int successfulNetworkRequests;
  final int failedNetworkRequests;
  final int timeoutNetworkRequests;
  
  // Routing table metrics
  final int routingTableSize;
  final int peersAdded;
  final int peersRemoved;
  final int bucketRefreshes;
  
  // Provider metrics
  final int providersStored;
  final int providersRetrieved;
  final int providerQueries;
  
  // Error metrics
  final Map<String, int> errorCounts;
  final Map<String, int> errorsByPeer;
  
  // Performance metrics
  final double queriesPerSecond;
  final double networkRequestsPerSecond;
  final int activeConnections;
  
  const DHTMetrics({
    required this.totalQueries,
    required this.successfulQueries,
    required this.failedQueries,
    required this.averageQueryLatency,
    required this.maxQueryLatency,
    required this.minQueryLatency,
    required this.totalNetworkRequests,
    required this.successfulNetworkRequests,
    required this.failedNetworkRequests,
    required this.timeoutNetworkRequests,
    required this.routingTableSize,
    required this.peersAdded,
    required this.peersRemoved,
    required this.bucketRefreshes,
    required this.providersStored,
    required this.providersRetrieved,
    required this.providerQueries,
    required this.errorCounts,
    required this.errorsByPeer,
    required this.queriesPerSecond,
    required this.networkRequestsPerSecond,
    required this.activeConnections,
  });
  
  /// Success rate for queries (0.0 to 1.0)
  double get querySuccessRate => 
    totalQueries > 0 ? successfulQueries / totalQueries : 0.0;
  
  /// Success rate for network requests (0.0 to 1.0)
  double get networkSuccessRate => 
    totalNetworkRequests > 0 ? successfulNetworkRequests / totalNetworkRequests : 0.0;
  
  @override
  String toString() => 'DHTMetrics(queries: $totalQueries, success: ${(querySuccessRate * 100).toStringAsFixed(1)}%, rt_size: $routingTableSize)';
}

/// Latency histogram for tracking response times
class LatencyHistogram {
  final Queue<Duration> _samples = Queue();
  final int _maxSamples;
  Duration _total = Duration.zero;
  Duration _max = Duration.zero;
  Duration _min = Duration(days: 1);
  
  LatencyHistogram({int maxSamples = 1000}) : _maxSamples = maxSamples;
  
  void record(Duration latency) {
    _samples.add(latency);
    _total += latency;
    
    if (latency > _max) _max = latency;
    if (latency < _min) _min = latency;
    
    // Remove old samples if we exceed max
    while (_samples.length > _maxSamples) {
      final removed = _samples.removeFirst();
      _total -= removed;
    }
  }
  
  Duration get average => _samples.isNotEmpty 
    ? Duration(microseconds: _total.inMicroseconds ~/ _samples.length)
    : Duration.zero;
  
  Duration get max => _max;
  Duration get min => _samples.isEmpty ? Duration.zero : _min;
  int get count => _samples.length;
  
  void clear() {
    _samples.clear();
    _total = Duration.zero;
    _max = Duration.zero;
    _min = Duration(days: 1);
  }
}

/// Counter for tracking occurrences
class Counter {
  int _count = 0;
  
  void increment([int amount = 1]) {
    _count += amount;
  }
  
  int get value => _count;
  
  void reset() {
    _count = 0;
  }
}

/// Gauge for tracking current values
class Gauge {
  double _value = 0.0;
  
  void set(double value) {
    _value = value;
  }
  
  void increment([double amount = 1.0]) {
    _value += amount;
  }
  
  void decrement([double amount = 1.0]) {
    _value -= amount;
  }
  
  double get value => _value;
  
  void reset() {
    _value = 0.0;
  }
}

/// Rate calculator for tracking events per second
class RateCalculator {
  final Queue<DateTime> _events = Queue();
  final Duration _window;
  
  RateCalculator({Duration window = const Duration(minutes: 1)}) : _window = window;
  
  void recordEvent() {
    final now = DateTime.now();
    _events.add(now);
    
    // Remove old events outside the window
    final cutoff = now.subtract(_window);
    while (_events.isNotEmpty && _events.first.isBefore(cutoff)) {
      _events.removeFirst();
    }
  }
  
  double get rate => _events.length / _window.inSeconds;
  
  void clear() {
    _events.clear();
  }
}

/// Manages metrics collection and reporting for DHT v2
class MetricsManager {
  static final Logger _logger = Logger('MetricsManager');
  
  // Configuration
  DHTConfigV2? _config;
  
  // State
  bool _started = false;
  bool _closed = false;
  Timer? _reportingTimer;
  
  // Metrics collectors
  final LatencyHistogram _queryLatency = LatencyHistogram();
  final Counter _totalQueries = Counter();
  final Counter _successfulQueries = Counter();
  final Counter _failedQueries = Counter();
  
  final Counter _totalNetworkRequests = Counter();
  final Counter _successfulNetworkRequests = Counter();
  final Counter _failedNetworkRequests = Counter();
  final Counter _timeoutNetworkRequests = Counter();
  
  final Gauge _routingTableSize = Gauge();
  final Counter _peersAdded = Counter();
  final Counter _peersRemoved = Counter();
  final Counter _bucketRefreshes = Counter();
  
  final Counter _providersStored = Counter();
  final Counter _providersRetrieved = Counter();
  final Counter _providerQueries = Counter();
  
  final Map<String, Counter> _errorCounters = <String, Counter>{};
  final Map<String, Counter> _peerErrorCounters = <String, Counter>{};
  
  final RateCalculator _queryRate = RateCalculator();
  final RateCalculator _networkRate = RateCalculator();
  final Gauge _activeConnections = Gauge();
  
  /// Initializes the metrics manager
  void initialize({required DHTConfigV2 config}) {
    _config = config;
  }
  
  /// Starts the metrics manager
  Future<void> start() async {
    if (_started || _closed) return;
    
    _logger.info('Starting MetricsManager...');
    
    if (_config?.enableMetrics == true) {
      _startReporting();
    }
    
    _started = true;
    _logger.info('MetricsManager started');
  }
  
  /// Stops the metrics manager
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    
    _logger.info('Closing MetricsManager...');
    
    _reportingTimer?.cancel();
    _reportingTimer = null;
    
    _logger.info('MetricsManager closed');
  }
  
  /// Starts periodic reporting of metrics
  void _startReporting() {
    final interval = _config?.metricsInterval ?? Duration(minutes: 1);
    _reportingTimer = Timer.periodic(interval, (_) {
      _reportMetrics();
    });
  }
  
  /// Reports current metrics to the log
  void _reportMetrics() {
    if (!_started || _closed) return;
    
    final metrics = getMetrics();
    
    _logger.info('DHT Metrics Report:');
    _logger.info('  Queries: ${metrics.totalQueries} (${(metrics.querySuccessRate * 100).toStringAsFixed(1)}% success)');
    _logger.info('  Network: ${metrics.totalNetworkRequests} (${(metrics.networkSuccessRate * 100).toStringAsFixed(1)}% success)');
    _logger.info('  Routing Table: ${metrics.routingTableSize} peers');
    _logger.info('  Latency: avg=${metrics.averageQueryLatency.inMilliseconds}ms, max=${metrics.maxQueryLatency.inMilliseconds}ms');
    _logger.info('  Rates: ${metrics.queriesPerSecond.toStringAsFixed(2)} q/s, ${metrics.networkRequestsPerSecond.toStringAsFixed(2)} req/s');
    
    if (metrics.errorCounts.isNotEmpty) {
      _logger.info('  Errors: ${metrics.errorCounts}');
    }
  }
  
  /// Gets current metrics snapshot
  DHTMetrics getMetrics() {
    return DHTMetrics(
      totalQueries: _totalQueries.value,
      successfulQueries: _successfulQueries.value,
      failedQueries: _failedQueries.value,
      averageQueryLatency: _queryLatency.average,
      maxQueryLatency: _queryLatency.max,
      minQueryLatency: _queryLatency.min,
      totalNetworkRequests: _totalNetworkRequests.value,
      successfulNetworkRequests: _successfulNetworkRequests.value,
      failedNetworkRequests: _failedNetworkRequests.value,
      timeoutNetworkRequests: _timeoutNetworkRequests.value,
      routingTableSize: _routingTableSize.value.toInt(),
      peersAdded: _peersAdded.value,
      peersRemoved: _peersRemoved.value,
      bucketRefreshes: _bucketRefreshes.value,
      providersStored: _providersStored.value,
      providersRetrieved: _providersRetrieved.value,
      providerQueries: _providerQueries.value,
      errorCounts: Map.fromEntries(
        _errorCounters.entries.map((e) => MapEntry(e.key, e.value.value))
      ),
      errorsByPeer: Map.fromEntries(
        _peerErrorCounters.entries.map((e) => MapEntry(e.key, e.value.value))
      ),
      queriesPerSecond: _queryRate.rate,
      networkRequestsPerSecond: _networkRate.rate,
      activeConnections: _activeConnections.value.toInt(),
    );
  }
  
  // Query metrics
  
  void recordQueryStart() {
    _totalQueries.increment();
    _queryRate.recordEvent();
  }
  
  void recordQuerySuccess(Duration latency) {
    _successfulQueries.increment();
    _queryLatency.record(latency);
  }
  
  void recordQueryFailure(String errorType, {PeerId? peer}) {
    _failedQueries.increment();
    _recordError(errorType, peer: peer);
  }
  
  // Network metrics
  
  void recordNetworkRequest() {
    _totalNetworkRequests.increment();
    _networkRate.recordEvent();
  }
  
  void recordNetworkSuccess() {
    _successfulNetworkRequests.increment();
  }
  
  void recordNetworkFailure(String errorType, {PeerId? peer}) {
    _failedNetworkRequests.increment();
    _recordError(errorType, peer: peer);
  }
  
  void recordNetworkTimeout({PeerId? peer}) {
    _timeoutNetworkRequests.increment();
    _recordError('timeout', peer: peer);
  }
  
  // Routing table metrics
  
  void recordRoutingTableSize(int size) {
    _routingTableSize.set(size.toDouble());
  }
  
  void recordPeerAdded() {
    _peersAdded.increment();
  }
  
  void recordPeerRemoved() {
    _peersRemoved.increment();
  }
  
  void recordBucketRefresh() {
    _bucketRefreshes.increment();
  }
  
  // Provider metrics
  
  void recordProviderStored() {
    _providersStored.increment();
  }
  
  void recordProviderRetrieved() {
    _providersRetrieved.increment();
  }
  
  void recordProviderQuery() {
    _providerQueries.increment();
  }
  
  // Connection metrics
  
  void recordConnectionOpened() {
    _activeConnections.increment();
  }
  
  void recordConnectionClosed() {
    _activeConnections.decrement();
  }
  
  // Error tracking
  
  void _recordError(String errorType, {PeerId? peer}) {
    _errorCounters.putIfAbsent(errorType, () => Counter()).increment();
    
    if (peer != null) {
      final peerKey = peer.toBase58().substring(0, 6);
      _peerErrorCounters.putIfAbsent(peerKey, () => Counter()).increment();
    }
  }
  
  /// Resets all metrics
  void reset() {
    _queryLatency.clear();
    _totalQueries.reset();
    _successfulQueries.reset();
    _failedQueries.reset();
    
    _totalNetworkRequests.reset();
    _successfulNetworkRequests.reset();
    _failedNetworkRequests.reset();
    _timeoutNetworkRequests.reset();
    
    _routingTableSize.reset();
    _peersAdded.reset();
    _peersRemoved.reset();
    _bucketRefreshes.reset();
    
    _providersStored.reset();
    _providersRetrieved.reset();
    _providerQueries.reset();
    
    _errorCounters.clear();
    _peerErrorCounters.clear();
    
    _queryRate.clear();
    _networkRate.clear();
    _activeConnections.reset();
  }
} 