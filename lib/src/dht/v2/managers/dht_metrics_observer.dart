import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'metrics_manager.dart';

/// Observer interface for DHT metrics
/// 
/// Implementations can track DHT operations including queries, routing table
/// updates, provider operations, and network requests.
abstract class DHTMetricsObserver {
  /// Called when DHT metrics are updated
  /// 
  /// This is the primary callback that provides a snapshot of all DHT metrics.
  /// Implementations should use this for comprehensive metrics tracking.
  void onMetricsUpdated(DHTMetrics metrics);
  
  /// Optional: Called when a query is started
  void onQueryStarted(String queryType, String key) {}
  
  /// Optional: Called when a query completes
  void onQueryCompleted(String queryType, String key, Duration latency, bool success) {}
  
  /// Optional: Called when the routing table is updated
  void onRoutingTableUpdated(int size, int peersAdded, int peersRemoved) {}
  
  /// Optional: Called when a provider operation occurs
  void onProviderOperation(String operation, bool success) {}
  
  /// Optional: Called when a network request completes
  void onNetworkRequest(bool success, {PeerId? peer, String? errorType}) {}
}

