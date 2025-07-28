import 'dart:async';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:dart_libp2p_kad_dht/src/kbucket/table/table_refresh.dart';
import 'package:logging/logging.dart';

import '../kbucket/table/table.dart';


/// Logger for the routing table refresh component
final _logger = Logger('RtRefreshManagerCustomLogger'); // Changed logger name

/// Timeout for pinging a peer to check liveness
const peerPingTimeout = Duration(seconds: 10);

/// Request to trigger a routing table refresh
class TriggerRefreshRequest {
  /// Channel to receive the response
  final Completer<void> completer;
  
  /// Whether to force a refresh of all CPLs
  final bool forceCplRefresh;

  /// Creates a new refresh request
  TriggerRefreshRequest({
    Completer<void>? completer,
    this.forceCplRefresh = false,
  }) : completer = completer ?? Completer<void>();
}

/// Manages refreshing of the routing table
class RtRefreshManager {
  /// The host
  final Host host;
  
  /// The peer ID of this DHT node
  final PeerId dhtPeerId;
  
  /// The routing table
  final RoutingTable rt;
  
  /// Whether to run periodic refreshes
  final bool enableAutoRefresh;
  
  /// Function to generate a key for refreshing a specific CPL
  final Future<String> Function(int cpl) refreshKeyGenFnc;
  
  /// Function to run a query for a refresh
  final Future<void> Function(String key) refreshQueryFnc;
  
  /// Function to ping a peer to check liveness
  final Future<void> Function(PeerId peerId) refreshPingFnc;
  
  /// Timeout for a refresh query
  final Duration refreshQueryTimeout;
  
  /// Interval between periodic refreshes
  final Duration refreshInterval;
  
  /// Grace period for successful outbound queries
  final Duration successfulOutboundQueryGracePeriod;
  
  /// Controller for the refresh done stream
  final StreamController<void> _refreshDoneController = StreamController<void>.broadcast();
  
  /// Stream of refresh done events
  Stream<void> get refreshDone => _refreshDoneController.stream;
  
  /// Controller for the trigger refresh stream
  final StreamController<TriggerRefreshRequest> _triggerRefreshController = StreamController<TriggerRefreshRequest>();
  
  /// Timer for periodic refreshes
  Timer? _refreshTimer;
  
  /// Whether the manager is running
  bool _isRunning = false;
  
  /// Creates a new routing table refresh manager
  RtRefreshManager({
    required this.host,
    required this.dhtPeerId,
    required this.rt,
    required this.enableAutoRefresh,
    required this.refreshKeyGenFnc,
    required this.refreshQueryFnc,
    required this.refreshPingFnc,
    required this.refreshQueryTimeout,
    required this.refreshInterval,
    required this.successfulOutboundQueryGracePeriod,
  });
  
  /// Starts the refresh manager
  void start() {
    _logger.info('RtRefreshManager.start() called. _isRunning: $_isRunning');
    if (_isRunning) {
      _logger.info('RtRefreshManager.start(): Already running, returning.');
      return;
    }
    _isRunning = true;
    _logger.info('RtRefreshManager.start(): Set _isRunning to true.');
    
    // Start listening for refresh requests
    _logger.info('RtRefreshManager.start(): Subscribing _handleRefreshRequest to _triggerRefreshController.stream.');
    _triggerRefreshController.stream.listen(_handleRefreshRequest);
    _logger.info('RtRefreshManager.start(): Subscription to _triggerRefreshController.stream completed.');
    
    // If auto-refresh is enabled, do an initial refresh and start the timer
    if (enableAutoRefresh) {
      _doRefresh(true).then((_) {
        if (_isRunning) {
          _refreshTimer = Timer.periodic(refreshInterval, (_) => _handlePeriodicRefresh());
        }
      });
    }
  }
  
  /// Stops the refresh manager
  Future<void> close() async {
    if (!_isRunning) return;
    _isRunning = false;
    
    // Cancel the timer
    _refreshTimer?.cancel();
    _refreshTimer = null;
    
    // Close the controllers
    await _triggerRefreshController.close();
    await _refreshDoneController.close();
  }
  
  /// Refreshes the routing table
  /// 
  /// If [force] is true, all buckets will be refreshed regardless of when they were last refreshed.
  /// Returns a future that completes when the refresh is done.
  Future<void> refresh(bool force) {
    final request = TriggerRefreshRequest(
      completer: Completer<void>(),
      forceCplRefresh: force,
    );
    
    _triggerRefreshController.add(request);
    return request.completer.future;
  }
  
  /// Requests a refresh without waiting for it to complete
  void refreshNoWait() {
    if (_triggerRefreshController.isClosed) return;
    _triggerRefreshController.add(TriggerRefreshRequest());
  }
  
  /// Handles a refresh request
  Future<void> _handleRefreshRequest(TriggerRefreshRequest request) async {
    _logger.info('Entering _handleRefreshRequest. forceCplRefresh: ${request.forceCplRefresh}');
    try {
      await _pingAndEvictPeers();
      await _doRefresh(request.forceCplRefresh);
      request.completer.complete();
    } catch (e) {
      request.completer.completeError(e);
    }
  }
  
  /// Handles a periodic refresh
  Future<void> _handlePeriodicRefresh() async {
    try {
      await _pingAndEvictPeers();
      await _doRefresh(false);
    } catch (e) {
      _logger.warning('Failed when refreshing routing table: $e');
    }
  }
  
  /// Pings peers that haven't been heard from in a while and evicts them if they don't respond
  Future<void> _pingAndEvictPeers() async {
    _logger.info('Starting _pingAndEvictPeers. Current RT size: ${await rt.size}');
    final peers = await rt.listPeers();
    _logger.info('_pingAndEvictPeers: Found ${peers.length} peers in routing table.');
    final futures = <Future<void>>[];
    int peersToPingCount = 0;
    
    for (final peerInfo in peers) {
      if (DateTime.now().difference(peerInfo.lastSuccessfulOutboundQueryAt) <= successfulOutboundQueryGracePeriod) {
        _logger.fine('_pingAndEvictPeers: Skipping ping for ${peerInfo.id.toBase58()} (recently active).');
        continue;
      }
      peersToPingCount++;
      _logger.info('_pingAndEvictPeers: Will attempt to ping ${peerInfo.id.toBase58()}.');
      futures.add(_pingAndEvictPeer(peerInfo.id));
    }
    
    if (futures.isEmpty) {
      _logger.info('_pingAndEvictPeers: No peers require pinging.');
    } else {
      _logger.info('_pingAndEvictPeers: Pinging $peersToPingCount peers.');
      await Future.wait(futures);
      _logger.info('_pingAndEvictPeers: Finished pinging $peersToPingCount peers.');
    }
    _logger.info('_pingAndEvictPeers completed.');
  }
  
  /// Pings a peer and evicts it if it doesn't respond
  Future<void> _pingAndEvictPeer(PeerId peerId) async {
    _logger.info('Starting _pingAndEvictPeer for ${peerId.toBase58()}');
    try {
      // Try to connect to the peer
      _logger.fine('_pingAndEvictPeer: Dialing ${peerId.toBase58()}');
      await (host as dynamic).dialPeer(peerId);
      _logger.fine('_pingAndEvictPeer: Dial successful for ${peerId.toBase58()}');
      
      // Try to ping the peer
      _logger.fine('_pingAndEvictPeer: Pinging ${peerId.toBase58()} via refreshPingFnc');
      await refreshPingFnc(peerId);
      _logger.info('_pingAndEvictPeer: Ping successful for ${peerId.toBase58()}');
    } catch (e) {
      _logger.warning('Evicting peer ${peerId.toBase58()} after failed dial/ping: $e');
      rt.removePeer(peerId);
    }
    _logger.info('_pingAndEvictPeer for ${peerId.toBase58()} completed.');
  }
  
  /// Performs a routing table refresh
  Future<void> _doRefresh(bool forceRefresh) async {
    _logger.info('Starting _doRefresh. forceRefresh: $forceRefresh. Current RT size: ${await rt.size}');
    try {
      // Query for self
      _logger.info('Running _queryForSelf...');
      await _queryForSelf();
      _logger.info('_queryForSelf completed.');
      
      // Get CPLs to refresh
      final refreshCpls = await rt.getTrackedCplsForRefresh();
      _logger.info('Tracked CPLs for refresh (count: ${refreshCpls.length}): ${List.generate(refreshCpls.length, (i) => i)}');
      
      // Refresh each CPL
      // Iterate using CPL index (cplValue) from 0 up to the max CPL tracked.
      // refreshCpls is a List<DateTime> where index is CPL and value is last refresh time.
      bool stopRefreshDueToGap = false;
      for (int cplValue = 0; cplValue < refreshCpls.length; cplValue++) {
        _logger.info('Outer loop: current cplValue = $cplValue, stopRefreshDueToGap = $stopRefreshDueToGap');
        if (stopRefreshDueToGap) {
          _logger.info('RtRefreshManager._doRefresh: Stopping CPL processing. Breaking outer loop for cplValue = $cplValue.');
          break;
        }
        _logger.info('Processing CPL $cplValue in _doRefresh loop.');
        final lastRefreshedAt = refreshCpls[cplValue];
        
        bool refreshed = false;
        
        if (forceRefresh) {
          await _refreshCpl(cplValue); // Use cplValue (integer CPL)
          refreshed = true;
        } else {
          refreshed = await _refreshCplIfEligible(cplValue, lastRefreshedAt); // Use cplValue
        }
        
        // If we see a gap at a CPL in the routing table, we only refresh up to a certain point
        if (refreshed && await rt.nPeersForCpl(cplValue) == 0) { // Use cplValue and await nPeersForCpl
          _logger.info('Gap detected at CPL $cplValue. Will refresh further up to a limit. (Outer loop cplValue was $cplValue)');
          // The max CPL index is refreshCpls.length - 1.
          final maxCplIndex = refreshCpls.length - 1;
          // Calculate how far to refresh past the gap.
          final lastCplToRefreshInGapSequence = min(2 * (cplValue + 1), maxCplIndex);
          _logger.info('Gap-filling: cplValue=$cplValue, maxCplIndex=$maxCplIndex, lastCplToRefreshInGapSequence=$lastCplToRefreshInGapSequence');

          for (int nextCplInGapSequence = cplValue + 1; nextCplInGapSequence <= lastCplToRefreshInGapSequence; nextCplInGapSequence++) {
            _logger.info('RtRefreshManager._doRefresh: Gap-filling refresh for CPL $nextCplInGapSequence.');
            if (forceRefresh) {
              await _refreshCpl(nextCplInGapSequence);
            } else {
              final nextLastRefreshedAt = refreshCpls[nextCplInGapSequence];
              await _refreshCplIfEligible(nextCplInGapSequence, nextLastRefreshedAt);
            }
          }
          _logger.info('RtRefreshManager._doRefresh: Finished gap-filling. Setting flag to stop further CPL processing. Outer cplValue was $cplValue.');
          stopRefreshDueToGap = true; 
          _logger.info('RtRefreshManager._doRefresh: stopRefreshDueToGap is now $stopRefreshDueToGap. Outer cplValue was $cplValue when gap was detected and flag set.');
        }
      }
      
      // Signal that refresh is done
      _logger.info('_doRefresh loop completed.');
      if (!_refreshDoneController.isClosed) {
        _refreshDoneController.add(null);
      }
    } catch (e) {
      _logger.warning('Failed when refreshing routing table: $e');
      rethrow;
    }
  }
  
  /// Refreshes a CPL if it's eligible (hasn't been refreshed recently)
  Future<bool> _refreshCplIfEligible(int cpl, DateTime lastRefreshedAt) async {
    if (DateTime.now().difference(lastRefreshedAt) <= refreshInterval) {
      _logger.fine('Not running refresh for CPL $cpl as time since last refresh not above interval');
      return false;
    }
    
    await _refreshCpl(cpl);
    return true;
  }
  
  /// Refreshes a specific CPL
  Future<void> _refreshCpl(int cpl) async {
    // Generate a key for the query to refresh the CPL
    final key = await refreshKeyGenFnc(cpl);
    
    _logger.info('Starting refreshing CPL $cpl with key $key (routing table size was ${await rt.size})');
    
    // Run the refresh query
    await _runRefreshDhtQuery(key);
    
    _logger.info('Finished refreshing CPL $cpl, routing table size is now ${await rt.size}');
  }
  
  /// Queries for self to refresh the routing table
  Future<void> _queryForSelf() async {
    await _runRefreshDhtQuery(dhtPeerId.toString());
  }
  
  /// Runs a DHT query for refreshing the routing table
  Future<void> _runRefreshDhtQuery(String key) async {
    _logger.info('Attempting refresh query for key "$key"');
    try {
      await refreshQueryFnc(key).timeout(refreshQueryTimeout);
      _logger.info('Refresh query for key "$key" completed (or was no-op).');
    } on TimeoutException {
      _logger.info('Refresh query for key "$key" timed out as expected by RtRefreshManager.');
    } catch (e, s) {
      _logger.severe('Refresh query for key "$key" failed with an unexpected error: $e\n$s');
      rethrow;
    }
  }
}

/// Returns the minimum of two integers
int min(int a, int b) => a <= b ? a : b;
