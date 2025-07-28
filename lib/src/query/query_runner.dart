import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';

import 'qpeerset.dart';

/// A function that queries a peer and returns a list of closer peers.
/// 
/// This function is called for each peer that needs to be queried during
/// the lookup process. It should:
/// - Send a query message to the specified peer
/// - Return a list of peers that are closer to the target key
/// - Throw an exception if the query fails
/// 
/// Example:
/// ```dart
/// Future<List<AddrInfo>> queryFunction(PeerId peer) async {
///   try {
///     final response = await dht.sendFindNodeQuery(peer, targetKey);
///     return response.closerPeers;
///   } catch (e) {
///     throw Exception('Failed to query peer $peer: $e');
///   }
/// }
/// ```
typedef QueryFunction = Future<List<AddrInfo>> Function(PeerId peer);

/// A function that determines when a query should stop.
/// 
/// This function is called after each round of queries to determine if
/// the lookup should terminate successfully. It receives the current
/// peerset state and should return true to stop the query.
/// 
/// Common stop conditions:
/// - Found enough peers: `peerset.getClosestInStates([PeerState.queried]).length >= k`
/// - Found specific peer: `peerset.getClosestInStates([PeerState.queried]).contains(targetPeer)`
/// - Reached convergence: No new closer peers discovered in recent rounds
/// 
/// Example:
/// ```dart
/// bool stopFunction(QueryPeerset peerset) {
///   // Stop when we have queried at least 20 peers
///   return peerset.getClosestInStates([PeerState.queried]).length >= 20;
/// }
/// ```
typedef StopFunction = bool Function(QueryPeerset peerset);

/// Represents the result of a completed query operation.
/// 
/// Contains the final state of the peer set, termination reason, and any
/// errors that occurred during the query process.
class QueryResult {
  /// The set of peers discovered and queried during the lookup.
  /// 
  /// This contains all peers in various states:
  /// - `PeerState.queried`: Successfully queried peers
  /// - `PeerState.unreachable`: Peers that failed to respond
  /// - `PeerState.heard`: Discovered but not yet queried peers
  /// - `PeerState.waiting`: Peers currently being queried (rare in final result)
  final QueryPeerset peerset;
  
  /// The reason why the query terminated.
  /// 
  /// Possible values:
  /// - `Success`: Stop function returned true
  /// - `Timeout`: Query exceeded the specified timeout duration
  /// - `Cancelled`: Query was explicitly cancelled via cancel()
  /// - `NoMorePeers`: No more peers available to query
  final QueryTerminationReason reason;
  
  /// List of exceptions that occurred during peer queries.
  /// 
  /// Each exception represents a failed query attempt. The query continues
  /// despite individual failures, collecting all errors for analysis.
  final List<Exception> errors;

  QueryResult({
    required this.peerset,
    required this.reason,
    this.errors = const [],
  });
}

/// Base class for all events emitted during a query operation.
/// 
/// Events are emitted in real-time as the query progresses, allowing
/// applications to monitor query progress, handle failures, and react
/// to discoveries immediately.
/// 
/// Subscribe to events via `QueryRunner.events` stream:
/// ```dart
/// runner.events.listen((event) {
///   if (event is PeerQueried) {
///     print('Successfully queried ${event.peer}');
///   } else if (event is PeerQueryFailed) {
///     print('Failed to query ${event.peer}: ${event.error}');
///   }
/// });
/// ```
abstract class QueryEvent {}

/// Event emitted when a peer is successfully queried.
/// 
/// This event indicates that:
/// - The peer responded to the query
/// - The peer has been marked as `PeerState.queried`
/// - Any closer peers returned by this peer have been added to the peerset
class PeerQueried extends QueryEvent {
  /// The peer that was successfully queried.
  final PeerId peer;
  
  /// The list of closer peers returned by the queried peer.
  /// 
  /// These peers are automatically added to the peerset in `PeerState.heard`
  /// state and may be queried in subsequent rounds.
  final List<AddrInfo> closerPeers;

  PeerQueried({required this.peer, required this.closerPeers});
}

/// Event emitted when a query to a peer fails.
/// 
/// This event indicates that:
/// - The peer did not respond or returned an error
/// - The peer has been marked as `PeerState.unreachable`
/// - The error has been added to the query's error list
class PeerQueryFailed extends QueryEvent {
  /// The peer that failed to respond to the query.
  final PeerId peer;
  
  /// The exception that caused the query failure.
  /// 
  /// This could be a network error, timeout, protocol error, or any
  /// exception thrown by the QueryFunction.
  final Exception error;

  PeerQueryFailed({required this.peer, required this.error});
}

/// Event emitted when the query terminates.
/// 
/// This is always the final event in the stream and contains the
/// complete query result. After this event, no more events will be emitted.
class QueryTerminated extends QueryEvent {
  /// The final result of the query operation.
  final QueryResult result;

  QueryTerminated({required this.result});
}

/// Enumeration of possible query termination reasons.
/// 
/// Each reason indicates why the query stopped executing:
enum QueryTerminationReason {
  /// The query terminated successfully because the stop function returned true.
  /// 
  /// This indicates the query found what it was looking for or reached
  /// a satisfactory state as determined by the StopFunction.
  Success,
  
  /// The query exceeded the specified timeout duration.
  /// 
  /// The query was forcibly terminated to prevent indefinite execution.
  /// Some peers may still be in `PeerState.waiting` state.
  Timeout,
  
  /// The query was explicitly cancelled via the cancel() method.
  /// 
  /// This can happen while the query is running or before it starts.
  /// Ongoing peer queries are interrupted when possible.
  Cancelled,
  
  /// The query ran out of peers to query.
  /// 
  /// All discovered peers have been either successfully queried or
  /// marked as unreachable, and no new peers remain to be queried.
  NoMorePeers,
}

/// A robust, event-driven query runner for Kademlia DHT lookups.
/// 
/// The QueryRunner implements the core Kademlia lookup algorithm with support for:
/// - **Concurrent queries**: Configurable alpha parameter for simultaneous peer queries
/// - **Event streaming**: Real-time progress monitoring via event stream
/// - **Cancellation**: Graceful query termination with proper cleanup
/// - **Timeout handling**: Automatic termination of long-running queries
/// - **Error resilience**: Continues operation despite individual peer failures
/// 
/// ## Basic Usage
/// 
/// ```dart
/// // Define how to query a peer
/// Future<List<AddrInfo>> queryFunction(PeerId peer) async {
///   final response = await dht.sendFindNodeQuery(peer, targetKey);
///   return response.closerPeers;
/// }
/// 
/// // Define when to stop the query
/// bool stopFunction(QueryPeerset peerset) {
///   return peerset.getClosestInStates([PeerState.queried]).length >= 20;
/// }
/// 
/// // Create and run the query
/// final runner = QueryRunner(
///   target: targetKey,
///   queryFn: queryFunction,
///   stopFn: stopFunction,
///   initialPeers: bootstrapPeers,
///   alpha: 3,
///   timeout: Duration(minutes: 2),
/// );
/// 
/// // Monitor progress (optional)
/// runner.events.listen((event) {
///   if (event is PeerQueried) {
///     print('Found ${event.closerPeers.length} closer peers from ${event.peer}');
///   }
/// });
/// 
/// // Execute the query
/// final result = await runner.run();
/// print('Query completed: ${result.reason}');
/// print('Found ${result.peerset.getClosestInStates([PeerState.queried]).length} peers');
/// 
/// // Clean up
/// await runner.dispose();
/// ```
/// 
/// ## Query Lifecycle
/// 
/// 1. **Initialization**: Initial peers are added to the peerset in `heard` state
/// 2. **Query Rounds**: Up to `alpha` peers are queried simultaneously each round
/// 3. **Peer Discovery**: Successful queries add new peers to the peerset
/// 4. **State Transitions**: Peers move through heard → waiting → queried/unreachable
/// 5. **Termination**: Query stops when stop condition is met, timeout occurs, or no more peers
/// 
/// ## Concurrency Control
/// 
/// The `alpha` parameter controls how many peers are queried simultaneously:
/// - Higher alpha = faster queries but more network load
/// - Lower alpha = slower queries but less network load
/// - Typical values: 3-10 depending on network conditions
/// 
/// ## Error Handling
/// 
/// Individual peer query failures don't stop the overall query:
/// - Failed peers are marked as `unreachable`
/// - Errors are collected in the final result
/// - Query continues with remaining peers
/// 
/// ## Resource Management
/// 
/// Always call `dispose()` when done to:
/// - Cancel any running timers
/// - Close the event stream
/// - Free associated resources
class QueryRunner {
  final Uint8List _target;
  final QueryFunction _queryFn;
  final StopFunction _stopFn;
  final QueryPeerset _peerset;
  final int _alpha;
  final Duration timeout;
  final StreamController<QueryEvent> _eventController = StreamController<QueryEvent>.broadcast();

  /// Creates a new QueryRunner for performing Kademlia DHT lookups.
  /// 
  /// Parameters:
  /// - [target]: The target key being searched for (typically a hash)
  /// - [queryFn]: Function to query individual peers and get closer peers
  /// - [stopFn]: Function to determine when the query should terminate successfully
  /// - [initialPeers]: List of peers to start the query with (bootstrap peers)
  /// - [alpha]: Number of peers to query simultaneously (default: 3)
  /// - [timeout]: Maximum duration for the entire query (default: 60 seconds)
  /// 
  /// Throws [AssertionError] if alpha <= 0 or timeout <= 0.
  QueryRunner({
    required Uint8List target,
    required QueryFunction queryFn,
    required StopFunction stopFn,
    required List<PeerId> initialPeers,
    int alpha = 3,
    this.timeout = const Duration(seconds: 60),
  })  : assert(alpha > 0, 'Alpha must be positive'),
        assert(timeout.inMilliseconds > 0, 'Timeout must be positive'),
        _target = target,
        _queryFn = queryFn,
        _stopFn = stopFn,
        _peerset = QueryPeerset(target),
        _alpha = alpha {
    for (final peer in initialPeers) {
      _peerset.tryAdd(peer, peer);
    }
  }

  bool _running = false;
  bool _cancelled = false;
  final List<Exception> _errors = [];
  Completer<QueryResult>? _resultCompleter;
  Completer<void>? _timeoutCompleter;

  /// Stream of events emitted during query execution.
  /// 
  /// Events are emitted in real-time as the query progresses:
  /// - [PeerQueried]: When a peer responds successfully
  /// - [PeerQueryFailed]: When a peer query fails
  /// - [QueryTerminated]: When the query completes (final event)
  /// 
  /// The stream is broadcast, so multiple listeners are supported.
  /// The stream closes when the QueryRunner is disposed.
  Stream<QueryEvent> get events => _eventController.stream;

  /// Cancels the currently running query.
  /// 
  /// If the query is running:
  /// - Sets the cancelled state
  /// - Interrupts ongoing peer queries when possible
  /// - Terminates the query with [QueryTerminationReason.Cancelled]
  /// - Completes the run() future with the cancelled result
  /// 
  /// If the query is not running:
  /// - Sets the cancelled state for future run() calls
  /// - Returns a cancelled result immediately
  /// 
  /// Returns the [QueryResult] representing the cancelled state.
  /// This method is safe to call multiple times.
  QueryResult cancel() {
    _cancelled = true;  // Set cancelled state regardless of running state
    
    if (!_running) {
      return QueryResult(
        peerset: _peerset,
        reason: QueryTerminationReason.Cancelled,
        errors: _errors,
      );
    }
    
    final result = _terminate(QueryTerminationReason.Cancelled);
    
    // Complete the result completer if it hasn't been completed yet
    if (_resultCompleter != null && !_resultCompleter!.isCompleted) {
      _resultCompleter!.complete(result);
    }
    
    return result;
  }

  /// Whether the query is currently executing.
  /// 
  /// Returns true from when run() is called until the query terminates
  /// (successfully, by timeout, cancellation, or running out of peers).
  bool get isRunning => _running;

  /// Whether the query has been cancelled.
  /// 
  /// Returns true after cancel() has been called, regardless of whether
  /// the query was running at the time. Once cancelled, subsequent
  /// run() calls will immediately return with cancelled status.
  bool get isCancelled => _cancelled;

  /// Disposes of the QueryRunner and releases all resources.
  /// 
  /// This method:
  /// - Cancels any running timeout operations
  /// - Closes the event stream (no more events will be emitted)
  /// - Frees internal resources
  /// 
  /// Should be called when the QueryRunner is no longer needed.
  /// Safe to call multiple times. After disposal, the QueryRunner
  /// should not be used for new queries.
  Future<void> dispose() async {
    _timeoutCompleter?.complete();
    _timeoutCompleter = null;
    if (!_eventController.isClosed) {
      await _eventController.close();
    }
  }

  /// Executes the query and returns the result.
  /// 
  /// The query process:
  /// 1. Validates that no query is currently running
  /// 2. Sets up timeout handling and initializes state
  /// 3. Executes query rounds until termination condition is met
  /// 4. Returns the final [QueryResult]
  /// 
  /// Query rounds:
  /// - Select up to `alpha` peers in `heard` state (closest to target)
  /// - Query all selected peers concurrently
  /// - Add discovered peers to the peerset
  /// - Check stop condition after each round
  /// - Continue until stopped, timed out, cancelled, or no more peers
  /// 
  /// Termination conditions:
  /// - [QueryTerminationReason.Success]: Stop function returned true
  /// - [QueryTerminationReason.Timeout]: Query exceeded timeout duration
  /// - [QueryTerminationReason.Cancelled]: Query was cancelled via cancel()
  /// - [QueryTerminationReason.NoMorePeers]: No more peers available to query
  /// 
  /// Throws [StateError] if a query is already running.
  /// 
  /// The QueryRunner can be reused after a query completes by calling
  /// run() again (unless it has been cancelled or disposed).
  Future<QueryResult> run() async {
    if (_running) {
      throw StateError('Query is already running');
    }
    
    _running = true;
    _cancelled = false;
    _resultCompleter = Completer<QueryResult>();
    _timeoutCompleter = Completer<void>();

    // Start timeout handling using Future.delayed instead of Timer
    _startTimeoutHandler();

    try {
      if (_peerset.getClosestNInStates(1, [PeerState.heard]).isEmpty) {
        final result = _terminate(QueryTerminationReason.NoMorePeers);
        if (!_resultCompleter!.isCompleted) {
          _resultCompleter!.complete(result);
        }
        return result;
      }

      // Start the query loop asynchronously
      _runQueryLoop();

      // Return the result when completed
      return await _resultCompleter!.future;
    } catch (e) {
      // Ensure cleanup on unexpected errors
      final result = _terminate(QueryTerminationReason.Cancelled);
      if (!_resultCompleter!.isCompleted) {
        _resultCompleter!.complete(result);
      }
      rethrow;
    }
  }

  /// Starts the timeout handler using Future.delayed instead of Timer.
  /// This prevents unhandled exceptions that can occur with Timer callbacks.
  void _startTimeoutHandler() async {
    try {
      await Future.any([
        Future.delayed(timeout),
        _timeoutCompleter!.future,
      ]);
      
      // If we reach here and the query is still running, it means timeout occurred
      if (_running && !_cancelled && !_resultCompleter!.isCompleted) {
        final result = _terminate(QueryTerminationReason.Timeout);
        _resultCompleter!.complete(result);
      }
    } catch (e) {
      // Handle any errors in timeout handling gracefully
      if (_running && !_cancelled && !_resultCompleter!.isCompleted) {
        final result = _terminate(QueryTerminationReason.Cancelled);
        _resultCompleter!.complete(result);
      }
    }
  }

  /// Main query execution loop that runs asynchronously.
  /// 
  /// This method implements the core Kademlia lookup algorithm:
  /// 1. Selects up to `alpha` closest peers in `heard` state
  /// 2. Queries all selected peers concurrently
  /// 3. Waits for all queries in the round to complete
  /// 4. Checks the stop condition after each round
  /// 5. Repeats until termination condition is met
  /// 
  /// The loop terminates when:
  /// - Stop function returns true (Success)
  /// - No more peers to query (NoMorePeers)
  /// - Query is cancelled (Cancelled)
  /// - An unexpected error occurs (Cancelled)
  void _runQueryLoop() async {
    try {
      while (_running && !_cancelled && !_resultCompleter!.isCompleted) {
        // Select the closest unqueried peers for this round
        final peersToQuery = _peerset.getClosestNInStates(_alpha, [PeerState.heard]);
        if (peersToQuery.isEmpty) {
          final result = _terminate(QueryTerminationReason.NoMorePeers);
          if (!_resultCompleter!.isCompleted) {
            _resultCompleter!.complete(result);
          }
          return;
        }

        // Start concurrent queries for all selected peers
        final futures = <Future>[];
        for (final peer in peersToQuery) {
          _peerset.setState(peer, PeerState.waiting);
          futures.add(_queryPeerWithTimeout(peer));
        }
        
        // Wait for all queries in this round to complete
        await Future.wait(futures);
        
        // Check if the stop condition is satisfied
        if (_stopFn(_peerset)) {
          final result = _terminate(QueryTerminationReason.Success);
          if (!_resultCompleter!.isCompleted) {
            _resultCompleter!.complete(result);
          }
          return;
        }
      }

      // If we exit the loop without terminating, it means we were cancelled
      if (!_resultCompleter!.isCompleted) {
        final result = _terminate(QueryTerminationReason.Cancelled);
        _resultCompleter!.complete(result);
      }
    } catch (e) {
      // Handle unexpected errors by terminating with cancelled status
      final result = _terminate(QueryTerminationReason.Cancelled);
      if (!_resultCompleter!.isCompleted) {
        _resultCompleter!.complete(result);
      }
    }
  }

  /// Queries a single peer and handles the response or failure.
  /// 
  /// This method:
  /// 1. Checks if the query is still active before and after the async call
  /// 2. Calls the user-provided query function
  /// 3. On success: marks peer as queried, adds discovered peers, emits PeerQueried event
  /// 4. On failure: marks peer as unreachable, collects error, emits PeerQueryFailed event
  /// 
  /// The method includes cancellation checks to avoid unnecessary work if the
  /// query has been terminated while the async operation was in progress.
  Future<void> _queryPeerWithTimeout(PeerId peer) async {
    // Early return if query is no longer active
    if (!_running || _cancelled || _resultCompleter!.isCompleted) {
      return;
    }
    
    try {
      // Execute the user-provided query function
      final closerPeers = await _queryFn(peer);
      
      // Check again after async operation in case query was terminated
      if (!_running || _cancelled || _resultCompleter!.isCompleted) {
        return;
      }
      
      // Process successful query result
      _peerset.setState(peer, PeerState.queried);
      for (final closerPeer in closerPeers) {
        _peerset.tryAdd(closerPeer.id, peer);
      }
      _eventController.add(PeerQueried(peer: peer, closerPeers: closerPeers));
    } on Exception catch (e) {
      // Check again after async operation in case query was terminated
      if (!_running || _cancelled || _resultCompleter!.isCompleted) {
        return;
      }
      
      // Process query failure
      _peerset.setState(peer, PeerState.unreachable);
      _errors.add(e);
      _eventController.add(PeerQueryFailed(peer: peer, error: e));
    }
  }

  /// Terminates the query with the specified reason and performs cleanup.
  /// 
  /// This method:
  /// 1. Sets the running state to false
  /// 2. Cancels the timeout operations
  /// 3. Creates the final QueryResult
  /// 4. Emits the QueryTerminated event
  /// 5. Returns the result
  /// 
  /// The method is safe to call multiple times and handles the case where
  /// the query is not currently running.
  /// 
  /// Returns the [QueryResult] representing the final state of the query.
  QueryResult _terminate(QueryTerminationReason reason) {
    // Handle case where query is not running (e.g., already terminated)
    if (!_running) {
      return QueryResult(peerset: _peerset, reason: reason, errors: _errors);
    }
    
    // Perform cleanup
    _running = false;
    _timeoutCompleter?.complete();
    _timeoutCompleter = null;

    // Create final result
    final result = QueryResult(
      peerset: _peerset,
      reason: reason,
      errors: _errors,
    );
    
    // Emit termination event synchronously to ensure it's the last event
    if (!_eventController.isClosed) {
      _eventController.add(QueryTerminated(result: result));
    }
    
    return result;
  }
}
