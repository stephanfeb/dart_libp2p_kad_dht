import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dcid/dcid.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_kad_dht/src/kbucket/table/table_refresh.dart';
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';

import '../kbucket/keyspace/kad_id.dart';
import '../netsize/netsize.dart';
import '../pb/dht_message.dart';
import '../query/legacy_types.dart';
import '../query/qpeerset.dart';
import 'dht.dart';
import 'events.dart';
import 'lookup.dart';

/// Logger for the lookup optimization component
final _logger = Logger('dht/lookup_optim');

/// Constants for optimistic provider record storage
class OptimisticProviderConstants {
  /// Private constructor to prevent instantiation
  OptimisticProviderConstants._();

  /// Describes how sure we want to be that an individual peer that
  /// we find during walking the DHT actually belongs to the k-closest peers based on the current network size
  /// estimation.
  static const double individualThresholdCertainty = 0.9;

  /// Describes the probability that the set of closest peers is actually further
  /// away then the calculated set threshold. Put differently, what is the probability that we are too strict and
  /// don't terminate the process early because we can't find any closer peers.
  static const double setThresholdStrictness = 0.1;

  /// Corresponds to how many ADD_PROVIDER RPCs must have completed (regardless of success)
  /// before we return to the user. The ratio of 0.75 equals 15 RPC as it is based on the Kademlia bucket size.
  static const double returnRatio = 0.75;
}

/// State of an ADD_PROVIDER RPC
enum AddProviderRPCState {
  /// The RPC has been scheduled but not yet completed
  scheduled,

  /// The RPC completed successfully
  success,

  /// The RPC failed
  failure,
}

/// Optimistic state for provider record storage
class OptimisticState {
  /// Reference to the DHT
  final IpfsDHT dht;

  /// The key to provide
  final String key;

  /// The key to provide transformed into the Kademlia key space
  final BigInt ksKey;

  /// The most recent network size estimation
  final int networkSize;

  /// A channel indicating when an ADD_PROVIDER RPC completed (successful or not)
  final StreamController<void> doneChan;

  /// Tracks which peers we have stored the provider records with
  final Map<PeerId, AddProviderRPCState> peerStates = {};

  /// Lock for accessing peerStates
  final Lock peerStatesLock = Lock();

  /// Distance threshold for individual peers. If peers are closer than this number we store
  /// the provider records right away.
  final double individualThreshold;

  /// Distance threshold for the set of bucketSize closest peers. If the average distance of the bucketSize
  /// closest peers is below this number we stop the DHT walk and store the remaining provider records.
  final double setThreshold;

  /// Number of completed (regardless of success) ADD_PROVIDER RPCs before we return control back to the user.
  final int returnThreshold;

  /// Counts the ADD_PROVIDER RPCs that have completed (successful and unsuccessful)
  int putProvDone = 0;

  /// Creates a new optimistic state
  OptimisticState({
    required this.dht,
    required this.key,
    required this.networkSize,
    required this.individualThreshold,
    required this.setThreshold,
    required this.returnThreshold,
  }) : 
    ksKey = XORKeySpace.key(Uint8List.fromList(key.codeUnits)),
    doneChan = StreamController<void>.broadcast();

  /// Determines whether to stop the DHT walk based on the current state
  bool stopFn(QueryPeerset qps) {
    // This is a simplified version that always returns false
    // In a real implementation, this would check various conditions
    return false;
  }

  /// Stores a provider record with the given peer
  void putProviderRecord(PeerId pid) {
    // In a real implementation, this would call the protocol messenger's PutProviderAddrs method
    // For now, we'll simulate this with a Future.delayed
    Future.delayed(Duration(milliseconds: 100), () {
      peerStatesLock.synchronized(() {
        // Simulate success or failure
        final success = math.Random().nextBool();
        if (success) {
          peerStates[pid] = AddProviderRPCState.success;
        } else {
          peerStates[pid] = AddProviderRPCState.failure;
        }

        // Indicate that this ADD_PROVIDER RPC has completed
        doneChan.add(null);
      });
    });
  }

  /// Waits for a subset of ADD_PROVIDER RPCs to complete and then acquire a lease on
  /// a bound channel to return early back to the user and prevent unbound asynchronicity.
  Future<void> waitForRPCs() async {
    final rpcCount = await peerStatesLock.synchronized(() => peerStates.length);

    // returnThreshold can't be larger than the total number issued RPCs
    final actualReturnThreshold = math.min(returnThreshold, rpcCount);

    // Wait until returnThreshold ADD_PROVIDER RPCs have returned
    var completed = 0;

    // Create a completer to track when enough RPCs have completed
    final completer = Completer<void>();

    // Listen for RPC completions
    doneChan.stream.listen((_) {
      completed++;
      if (completed >= actualReturnThreshold && !completer.isCompleted) {
        completer.complete();
      }
    });

    // Wait for the completer to complete
    await completer.future;

    // At this point only a subset of all ADD_PROVIDER RPCs have completed.
    // We want to give control back to the user as soon as possible because
    // it is highly likely that at least one of the remaining RPCs will time
    // out and thus slow down the whole processes.

    // For the remaining ADD_PROVIDER RPCs, we'll just let them complete in the background
    // In a real implementation, we would need to manage these background tasks more carefully
  }
}

/// Extension methods for DHT to handle optimistic provider record storage
extension OptimisticProvideExtension on IpfsDHT {
  /// Creates a new optimistic state for provider record storage
  Future<OptimisticState?> newOptimisticState(String key) async {
    // Get network size and err out if there is no reasonable estimate
    int networkSize;
    try {
      networkSize = await nsEstimator.networkSize();
    } catch (e) {
      _logger.warning('Failed to get network size estimate: $e');
      return null;
    }

    // Calculate thresholds based on network size and bucket size
    // In a real implementation, we would use the GammaIncRegInv function from a math library
    // For now, we'll use simplified calculations
    final individualThreshold = 1.0 / networkSize;
    final setThreshold = 0.5 / networkSize;
    final returnThreshold = (this.options.bucketSize * OptimisticProviderConstants.returnRatio).ceil();

    return OptimisticState(
      dht: this,
      key: key,
      networkSize: networkSize,
      individualThreshold: individualThreshold,
      setThreshold: setThreshold,
      returnThreshold: returnThreshold,
    );
  }

  /// Optimistically provides the given key to the network
  Future<void> optimisticProvide(Uint8List keyMH) async {
    final key = String.fromCharCodes(keyMH);

    if (key.isEmpty) {
      throw ArgumentError('Cannot lookup empty key');
    }

    // --- Self-registration as provider ---
    // Regardless of whether optimistic state is created or not, the node calling provide
    // should itself become a provider for the content.
    try {
      final selfCid = CID.fromBytes(keyMH); // Using core CID from dart_libp2p/core/routing/routing.dart
      // 'this' refers to the IpfsDHT instance from the extension.
      // Access host via host() method, then .id and .addrs. Access providerManager via getter (to be added to IpfsDHT).
      await this.providerManager.addProvider(selfCid, AddrInfo(this.host().id, this.host().addrs));
      _logger.fine('Self-registered as provider for key $key via optimisticProvide path.');
    } catch (e) {
      _logger.warning('Error self-registering provider for key $key during optimisticProvide: $e');
      // Depending on policy, might want to rethrow or handle. For now, just log.
    }

    // Create optimistic state
    final es = await newOptimisticState(key);
    if (es == null) {
      _logger.warning('Optimistic state creation failed for key $key. Optimistic announcements to other peers will be skipped.');
      // Self-registration already attempted above. No further action for optimistic part.
      return;
    }

    // --- If optimistic state IS created (es != null), proceed with optimistic announcements ---
    _logger.fine('Optimistic state created for key $key. Proceeding with optimistic announcements.');
    // Run lookup with followup
    // Use a simple stopFn that never stops early
    bool neverStop(QueryPeerset peerset) => false;

    final lookupRes = await runLookupWithFollowup(
      target: keyMH,
      queryFn: (peer) => pmGetClosestPeers(peer, key),
      stopFn: neverStop,
    );

    // Store the provider records with all the closest peers we haven't already contacted/scheduled interaction with
    await es.peerStatesLock.synchronized(() {
      for (final p in lookupRes.peers) {
        if (es.peerStates.containsKey(p)) {
          continue;
        }

        es.putProviderRecord(p);
        es.peerStates[p] = AddProviderRPCState.scheduled;
      }
    });

    // Wait until a threshold number of RPCs have completed
    await es.waitForRPCs();

    if (lookupRes.terminationReason != LookupTerminationReason.cancelled) {
      // Track lookup results for network size estimator
      try {
        // In a real implementation, we would track the lookup results for network size estimation
        // For now, just log a message
        _logger.fine('Network size estimator: tracking lookup results for key $key');
      } catch (e) {
        _logger.warning('Network size estimator track peers: $e');
      }

      // Refresh the cpl for this key as the query was successful
      this.routingTable.resetCplRefreshedAtForID(KadID.fromKey(key).bytes, DateTime.now());
    }
  }

  /// Gets the closest peers to the given key
  Future<List<AddrInfo>> pmGetClosestPeers(PeerId p, String key) async {
    // For DHT query event
    RoutingNotifier.publishQueryEvent(RoutingQueryEvent(
      type: QueryEventType.sendingQuery,
      id: p,
    ));

    try {
      // In the Go implementation, this would call the protocol messenger's GetClosestPeers method
      // For now, we'll simulate this by creating a message and sending it
      final message = Message(
        type: MessageType.findNode,
        key: Uint8List.fromList(key.codeUnits),
      );

      // Send the message to the peer
      final response = await this.sendMessage(p, message);

      // Convert the response to AddrInfo objects
      final peers = response.closerPeers.map((p) => AddrInfo(
        PeerId.fromBytes(p.id),
        p.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList(),
      )).toList();

      // For DHT query event
      RoutingNotifier.publishQueryEvent(RoutingQueryEvent(
        type: QueryEventType.peerResponse,
        id: p,
        responses: peers,
      ));

      return peers;
    } catch (e) {
      // Log the error
      _logger.warning('Error getting closer peers: $e');

      // For DHT query event
      RoutingNotifier.publishQueryEvent(RoutingQueryEvent(
        type: QueryEventType.queryError,
        id: p,
        extra: e.toString(),
      ));

      // Rethrow the error
      rethrow;
    }
  }
}
