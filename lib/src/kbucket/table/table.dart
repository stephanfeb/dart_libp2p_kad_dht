/// Routing Table implementation for libp2p-kbucket
/// 
/// This file contains the implementation of a routing table in the Kademlia DHT.

import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:dart_libp2p/core/peer/peer_id.dart';
// Ensure logging is imported
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';

import '../bucket/bucket.dart'; // commonPrefixLen is here
import '../peerdiversity/filter.dart';
import '../keyspace/xor.dart'; // xor is here, used by commonPrefixLen indirectly
import '../keyspace/kad_id.dart'; // For KadID.getKademliaIdBytes

// Logger for the routing table
// final _log = Logger('routingTable'); // Will use instance logger or specific logger for class

/// Error thrown when a peer is rejected due to high latency
class PeerRejectedHighLatencyError implements Exception {
  @override
  String toString() => 'Peer rejected; latency too high';
}

/// Error thrown when a peer is rejected due to insufficient capacity
class PeerRejectedNoCapacityError implements Exception {
  @override
  String toString() => 'Peer rejected; insufficient capacity';
}

/// A metrics interface for peer latency
abstract class PeerLatencyMetrics {
  /// Returns the exponentially weighted moving average latency for a peer
  Duration latencyEWMA(PeerId peerId);
}

/// RoutingTable defines the routing table.
class RoutingTable {
  static final _log = Logger('RoutingTable'); // Class-level logger

  /// ID of the local peer
  final PeerId localPeerId;
  /// Kademlia ID (hash) of the local peer
  final Uint8List localKadId;

  /// Mutex for table operations
  final _tableLock = Lock();

  /// Latency metrics
  final PeerLatencyMetrics metrics;

  /// Maximum acceptable latency for peers in this cluster
  final Duration maxLatency;

  /// kBuckets define all the fingers to other nodes.
  final List<Bucket> _buckets;
  final int bucketSize;

  /// Mutex for CPL refresh operations
  final _cplRefreshLock = Object();
  final Map<int, DateTime> cplRefreshedAt = {};

  /// Notification functions
  void Function(PeerId)? peerRemoved;
  void Function(PeerId)? peerAdded;

  /// Usefulness grace period for peers
  final Duration usefulnessGracePeriod;

  /// Diversity filter
  final Filter? df;

  /// Creates a new routing table with a given bucketsize, local ID, and latency tolerance.
  RoutingTable({
    required PeerId local, // Renamed parameter to avoid conflict
    required this.bucketSize,
    required this.maxLatency,
    required this.metrics,
    required this.usefulnessGracePeriod,
    this.df,
    this.peerRemoved,
    this.peerAdded,
  })  : localPeerId = local, // Initialize localPeerId
        localKadId = KadID.getKademliaIdBytes(local), // Initialize localKadId
        _buckets = [Bucket()];

  /// Returns the number of peers we have for a given CPL
  Future<int> nPeersForCpl(int cpl) async {
    _log.info('[nPeersForCpl] Called for CPL $cpl. Current _buckets.length: ${_buckets.length}');
    return await _tableLock.synchronized(() async {
      if (cpl < 0) return 0; // Basic sanity check

      // If cpl implies it's in the "catch-all" last bucket or a bucket that should exist
      // The condition `cpl >= _buckets.length - 1` means:
      // - If cpl is large and points beyond current number of specific CPL buckets, it checks the last bucket.
      // - If cpl is small but _buckets array hasn't grown to that cpl index yet (e.g. cpl=2, buckets.length=1),
      //   it also checks the last bucket.
      if (_buckets.isEmpty) {
        _log.warning('[nPeersForCpl] Buckets list is empty for CPL $cpl.');
        return 0;
      }

      if (cpl >= _buckets.length - 1 && _buckets.isNotEmpty) {
        _log.finer('[nPeersForCpl] Checking last bucket (index ${_buckets.length - 1}) for CPL $cpl.');
        var count = 0;
        final b = _buckets[_buckets.length - 1];
        final peersInBucket = b.peers();
        _log.finer('[nPeersForCpl] Peers in last bucket: ${peersInBucket.length}');
        for (final pInfo in peersInBucket) {
          final peerKadId = Uint8List.fromList(pInfo.dhtId);
          final actualCpl = commonPrefixLen(localKadId, peerKadId);
          _log.finest('[nPeersForCpl] Peer ${pInfo.id.toBase58()} in last bucket. Actual CPL with local: $actualCpl. Target CPL: $cpl');
          if (actualCpl == cpl) {
            count++;
            if (cpl == 7 && count > 0) {
              _log.warning('[nPeersForCpl DEBUG CPL 7] Peer ${pInfo.id.toBase58()} (KadId: ${peerKadId.map((b) => b.toRadixString(16).padLeft(2, '0')).join('')}) counted for CPL 7 in last bucket scan. LocalKadId: ${localKadId.map((b) => b.toRadixString(16).padLeft(2, '0')).join('')}');
            }
          }
        }
        _log.info('[nPeersForCpl] Count for CPL $cpl (from last bucket scan): $count');
        return count;
      } else {
        // This means cpl < _buckets.length - 1, so a dedicated bucket for this CPL should exist.
        final bucketLength = _buckets[cpl].length;
        if (cpl == 7 && bucketLength > 0) {
           _log.warning('[nPeersForCpl DEBUG CPL 7] Dedicated bucket _buckets[7] has length $bucketLength. Peers: ${_buckets[cpl].peers().map((pi) => pi.id.toBase58()).toList()}');
        }
        _log.info('[nPeersForCpl] Returning length of dedicated bucket _buckets[$cpl].length for CPL $cpl. Length: $bucketLength');
        return bucketLength;
      }
    });
  }

  /// UsefulNewPeer verifies whether the given peer.ID would be a good fit for the
  /// routing table.
  Future<bool> usefulNewPeer(PeerId p) async {
    return await _tableLock.synchronized(()async {
      final remoteKadId = KadID.getKademliaIdBytes(p);
      // Bucket corresponding to p's Kademlia ID
      final bucketId = _bucketIdForKadId(remoteKadId); // To be added: _bucketIdForKadId
      final bucket = _buckets[bucketId];

      if (bucket.getPeer(p) != null) {
        // Peer already exists in the routing table, so it isn't useful
        return false;
      }

      // Bucket isn't full
      if (bucket.length < bucketSize) {
        return true;
      }

      // Bucket is full, check if it contains replaceable peers
      for (final peerInfo in bucket.peers()) { // Iterate PeerInfo
        if (peerInfo.replaceable) {
          // At least 1 peer is replaceable
          return true;
        }
      }

      // The last bucket potentially contains peer ids with different CPL,
      // and can be split in 2 buckets if needed
      if (bucketId == _buckets.length - 1) {
        final cplOfNewPeer = commonPrefixLen(localKadId, remoteKadId);
        for (final peerInfo in bucket.peers()) { // Iterate PeerInfo
          // If at least 2 peers have a different CPL, the new peer is
          // useful and will trigger a bucket split
          // peerInfo.dhtId will be Kademlia ID
          if (commonPrefixLen(localKadId, Uint8List.fromList(peerInfo.dhtId)) != cplOfNewPeer) {
            return true;
          }
        }
      }

      // The appropriate bucket is full of non replaceable peers
      return false;
    });
  }

  /// TryAddPeer tries to add a peer to the Routing table.
  /// Returns a boolean value set to true if the peer was newly added to the Routing Table, false otherwise.
  /// It also returns any error that occurred while adding the peer to the Routing Table.
  Future<bool> tryAddPeer(PeerId p, {bool queryPeer = false, bool isReplaceable = false}) async {
    final id = localPeerId.toBase58();
    final logPrefix = '[${id.substring(id.length - 6)}.RoutingTable.tryAddPeer]';
    final peerShortIdForLog = p.toBase58().substring(p.toBase58().length -6);
    _log.fine('$logPrefix Attempting to add peer $peerShortIdForLog (queryPeer: $queryPeer, isReplaceable: $isReplaceable)');
    _log.finer('$logPrefix About to acquire _tableLock for peer $peerShortIdForLog.');
    return await _tableLock.synchronized(() async {
      _log.finer('$logPrefix Acquired _tableLock for peer $peerShortIdForLog. Inside synchronized block.');
      try {
        _log.finer('$logPrefix Before calling _addPeer for $peerShortIdForLog.');
        final added = await _addPeer(p, queryPeer, isReplaceable);
        _log.finer('$logPrefix After calling _addPeer for $peerShortIdForLog. Result: $added.');
        // Synchronous log before any other await
        _log.info('$logPrefix SYNCHRONOUS LOG: _addPeer returned $added for $peerShortIdForLog. About to log RT size.'); 
        final currentSize = _rawSize(); // Use non-locking version
        _log.info('$logPrefix Peer ${peerShortIdForLog} add attempt. Result: $added. RT Size: $currentSize');
        return added;
      } catch (e) {
        final currentSizeOnError = _rawSize(); // Use non-locking version
        _log.warning('$logPrefix Error adding peer ${peerShortIdForLog}: $e. RT Size: $currentSizeOnError');
        // Depending on desired behavior, you might rethrow or return false.
        // The original code rethrows, so we'll keep that.
        rethrow;
      }
    });
  }

  // Internal helper to get bucket ID for a Kademlia ID
  int _bucketIdForKadId(Uint8List kadId) {
    final cpl = commonPrefixLen(kadId, localKadId); // Use localKadId
    var bucketID = cpl;
    if (bucketID >= _buckets.length) {
      bucketID = _buckets.length - 1;
    }
    return bucketID;
  }

  /// Internal method to add a peer to the routing table
  Future<bool> _addPeer(PeerId p, bool queryPeer, bool isReplaceable) async {
    final id = localPeerId.toBase58();
    final logPrefix = '[${id.substring(id.length -6)}.RoutingTable._addPeer]';
    final peerShortId = p.toBase58().substring(p.toBase58().length -6);

    // Prevent adding the local peer to its own routing table.
    if (p == localPeerId) {
      _log.fine('$logPrefix Attempted to add local peer $peerShortId to routing table. Ignoring.');
      return false;
    }
    _log.finer('$logPrefix Processing peer $peerShortId.');

    final remoteKadId = KadID.getKademliaIdBytes(p);
    final bucketId = _bucketIdForKadId(remoteKadId); // Use Kademlia ID for bucket lookup
    final bucket = _buckets[bucketId];

    final now = DateTime.now();
    var lastUsefulAt = queryPeer ? now : DateTime.fromMillisecondsSinceEpoch(0);

    // Peer already exists in the Routing Table.
    final peerInfo = bucket.getPeer(p);
    if (peerInfo != null) {
      _log.fine('$logPrefix Peer $peerShortId already in bucket $bucketId. Updating usefulness if applicable.');
      if (peerInfo.lastUsefulAt.millisecondsSinceEpoch == 0 && queryPeer) {
        peerInfo.lastUsefulAt = lastUsefulAt;
        _log.finer('$logPrefix Updated lastUsefulAt for existing peer $peerShortId.');
      }
      return false; // Not newly added
    }

    final latency = metrics.latencyEWMA(p);
    if (latency > maxLatency) {
      _log.warning('$logPrefix Peer $peerShortId rejected; latency ${latency.inMilliseconds}ms > maxLatency ${maxLatency.inMilliseconds}ms.');
      throw PeerRejectedHighLatencyError();
    }

    if (df != null) {
      _log.finer('$logPrefix Attempting to add peer $peerShortId to diversity filter.');
      if (! await df!.tryAdd(p)) {
        _log.warning('$logPrefix Peer $peerShortId rejected by diversity filter.');
        throw Exception('peer rejected by the diversity filter');
      }
      _log.finer('$logPrefix Peer $peerShortId added to diversity filter.');
    }

    if (bucket.length < bucketSize) {
      _log.fine('$logPrefix Bucket $bucketId has space (${bucket.length}/$bucketSize). Adding peer $peerShortId.');
      bucket.pushFront(DhtPeerInfo(
        id: p,
        lastUsefulAt: lastUsefulAt,
        lastSuccessfulOutboundQueryAt: now,
        addedAt: now,
        dhtId: remoteKadId.toList(),
        replaceable: isReplaceable,
      ));
      peerAdded?.call(p);
      _log.info('$logPrefix Peer $peerShortId added to bucket $bucketId. New bucket length: ${bucket.length}.');
      return true;
    }
    _log.fine('$logPrefix Bucket $bucketId is full (${bucket.length}/$bucketSize).');

    if (bucketId == _buckets.length - 1) {
      _log.fine('$logPrefix Bucket $bucketId is the last bucket. Attempting to split.');
      _nextBucket(); // This might log internally
      final newBucketId = _bucketIdForKadId(remoteKadId);
      final newBucket = _buckets[newBucketId];
      _log.fine('$logPrefix After split, peer $peerShortId maps to bucket $newBucketId (length ${newBucket.length}/$bucketSize).');

      if (newBucket.length < bucketSize) {
        _log.fine('$logPrefix New bucket $newBucketId has space. Adding peer $peerShortId.');
        newBucket.pushFront(DhtPeerInfo(
          id: p,
          lastUsefulAt: lastUsefulAt,
          lastSuccessfulOutboundQueryAt: now,
          addedAt: now,
          dhtId: remoteKadId.toList(),
          replaceable: isReplaceable,
        ));
        peerAdded?.call(p);
        _log.info('$logPrefix Peer $peerShortId added to new bucket $newBucketId after split. New bucket length: ${newBucket.length}.');
        return true;
      }
      _log.fine('$logPrefix New bucket $newBucketId is also full after split.');
    }

    _log.fine('$logPrefix Bucket $bucketId is full. Searching for a replaceable peer.');
    DhtPeerInfo? replaceablePeerInfo;
    for (final pInfo in bucket.peers()) {
      if (pInfo.replaceable) {
        replaceablePeerInfo = pInfo;
        _log.finer('$logPrefix Found replaceable peer ${replaceablePeerInfo.id.toBase58().substring(0,6)} in bucket $bucketId.');
        break;
      }
    }

    if (replaceablePeerInfo != null) {
      final oldPeerShortId = replaceablePeerInfo.id.toBase58().substring(0,6);
      _log.info('$logPrefix Replacing peer $oldPeerShortId with $peerShortId in bucket $bucketId.');

      bucket.pushFront(DhtPeerInfo(
        id: p,
        lastUsefulAt: lastUsefulAt,
        lastSuccessfulOutboundQueryAt: now,
        addedAt: now,
        dhtId: remoteKadId.toList(),
        replaceable: isReplaceable,
      ));
      
      final oldPeerId = replaceablePeerInfo.id;
      final oldPeerKadId = KadID.getKademliaIdBytes(oldPeerId);
      _internalRemovePeer(oldPeerId, oldPeerKadId); // This will call peerRemoved

      peerAdded?.call(p); // Call peerAdded for the new peer
      _log.info('$logPrefix Peer $peerShortId added by replacing $oldPeerShortId in bucket $bucketId.');
      return true;
    }

    _log.warning('$logPrefix Bucket $bucketId full, no replaceable peer found for $peerShortId.');
    if (df != null) {
      _log.finer('$logPrefix Removing peer $peerShortId from diversity filter as it could not be added to table.');
      df!.remove(p);
    }
    throw PeerRejectedNoCapacityError();
  }

  /// MarkAllPeersIrreplaceable marks all peers in the routing table as irreplaceable
  Future<void> markAllPeersIrreplaceable() async {
    await _tableLock.synchronized(() async {
      for (final b in _buckets) {
        b.updateAllWith((p) {
          p.replaceable = false;
        });
      }
    });
  }

  /// GetPeerInfos returns the peer information that we've stored in the buckets
  Future<List<DhtPeerInfo>> getPeerInfos() async {
    return await _tableLock.synchronized( () async {
      final pis = <DhtPeerInfo>[];
      for (final b in _buckets) {
        pis.addAll(b.peers());
      }
      return pis;
    });
  }

  /// UpdateLastSuccessfulOutboundQueryAt updates the LastSuccessfulOutboundQueryAt time of the peer.
  Future<bool> updateLastSuccessfulOutboundQueryAt(PeerId p, DateTime t) async {
    return await _tableLock.synchronized(() async {
      final bucketId = _bucketIdForPeer(p);
      final bucket = _buckets[bucketId];

      final pc = bucket.getPeer(p);
      if (pc != null) {
        pc.lastSuccessfulOutboundQueryAt = t;
        return true;
      }
      return false;
    });
  }

  /// UpdateLastUsefulAt updates the LastUsefulAt time of the peer.
  Future<bool> updateLastUsefulAt(PeerId p, DateTime t) async {
    return await _tableLock.synchronized(() async {
      // _bucketIdForPeer now correctly uses Kademlia ID internally
      final bucketId = _bucketIdForPeer(p);
      final bucket = _buckets[bucketId];

      final pc = bucket.getPeer(p); // Bucket.getPeer still uses PeerId
      if (pc != null) {
        pc.lastUsefulAt = t;
        return true;
      }
      return false;
    });
  }

  /// RemovePeer should be called when the caller is sure that a peer is not useful for queries.
  Future<void> removePeer(PeerId p) async {
    final logPrefix = '[${localPeerId.toBase58().substring(0,6)}.RoutingTable.removePeer]';
    final peerShortId = p.toBase58().substring(0,6);
    _log.info('$logPrefix Attempting to remove peer $peerShortId.');
    await _tableLock.synchronized(() async {
      print('[DEBUG] RoutingTable.removePeer called for $p');
      final removed = _internalRemovePeer(p, KadID.getKademliaIdBytes(p));
      if (removed) {
        print('[DEBUG] Peer $p was successfully removed from the routing table.');
        _log.info('$logPrefix Peer $peerShortId successfully removed. RT Size: ${_rawSize()}');
      } else {
        print('[DEBUG] Peer $p was not found in the routing table for removal.');
        _log.warning('$logPrefix Peer $peerShortId not found for removal or already removed.');
      }
    });
  }

  /// Internal method to remove a peer from the routing table
  bool _internalRemovePeer(PeerId p, Uint8List remoteKadId) {
    final logPrefix = '[${localPeerId.toBase58().substring(0,6)}.RoutingTable._internalRemovePeer]';
    final peerShortId = p.toBase58().substring(0,6);

    final bucketId = _bucketIdForKadId(remoteKadId);
    _log.finer('$logPrefix Peer $peerShortId maps to bucket $bucketId for removal.');
    final bucket = _buckets[bucketId];

    if (bucket.remove(p)) {
      _log.fine('$logPrefix Peer $peerShortId removed from bucket $bucketId.');
      if (df != null) {
        _log.finer('$logPrefix Removing $peerShortId from diversity filter.');
        df!.remove(p);
      }

      // Consolidate buckets if necessary
      while (true) {
        final lastBucketIndex = _buckets.length - 1;
        if (_buckets.length > 1 && _buckets[lastBucketIndex].length == 0) {
          _log.finer('$logPrefix Last bucket $lastBucketIndex is empty and not the only bucket. Removing it.');
          _buckets.removeLast();
        } else if (_buckets.length >= 2 && _buckets[lastBucketIndex - 1].length == 0) {
          _log.finer('$logPrefix Second to last bucket ${lastBucketIndex - 1} is empty. Replacing it with last bucket $lastBucketIndex and removing last.');
          _buckets[lastBucketIndex - 1] = _buckets[lastBucketIndex];
          _buckets.removeLast();
        } else {
          break;
        }
      }
      _log.finer('$logPrefix Bucket consolidation after removing $peerShortId finished. Number of buckets: ${_buckets.length}');

      peerRemoved?.call(p);
      return true;
    }
    _log.finer('$logPrefix Peer $peerShortId not found in bucket $bucketId for removal.');
    return false;
  }

  /// Creates a new bucket when the last bucket needs to be split
  void _nextBucket() {
    final logPrefix = '[${localPeerId.toBase58().substring(0,6)}.RoutingTable._nextBucket]';
    _log.fine('$logPrefix Splitting last bucket (index ${_buckets.length - 1}). Current buckets: ${_buckets.length}');
    
    final bucket = _buckets[_buckets.length - 1];
    final newBucket = bucket.split(_buckets.length - 1, localKadId);
    _buckets.add(newBucket);
    _log.info('$logPrefix Split last bucket. New number of buckets: ${_buckets.length}. New bucket CPL: ${_buckets.length -1}, length: ${newBucket.length}');

    if (newBucket.length >= bucketSize) {
      _log.fine('$logPrefix Newly formed bucket (index ${_buckets.length - 1}) is still full (length ${newBucket.length}/$bucketSize). Recursively splitting.');
      _nextBucket();
    }
  }

  /// Find a specific peer by PeerId or return null
  Future<PeerId?> find(PeerId p) async { // Parameter is PeerId
    final targetKadId = KadID.getKademliaIdBytes(p);
    // nearestPeers now expects a Kademlia ID (Uint8List)
    final srch = await nearestPeers(targetKadId, 1);
    if (srch.isEmpty || srch[0] != p) { // Compare original PeerId
      return null;
    }
    return srch[0];
  }

  /// NearestPeer returns a single peer that is nearest to the given Kademlia ID
  Future<PeerId?> nearestPeer(Uint8List targetKadId) async { // Parameter is Kademlia ID
    final peers = await nearestPeers(targetKadId, 1);
    if (peers.isNotEmpty) {
      return peers[0];
    }

    _log.fine('NearestPeer: Returning null, table size = ${size()}');
    return null;
  }

  /// NearestPeers returns a list of the 'count' closest peers to the given Kademlia ID (targetKadId)
  Future<List<PeerId>> nearestPeers(Uint8List targetKadId, int count) async { // Parameter is Kademlia ID
    // This is the number of bits the targetKadId shares with our localKadId.
    final cplWithLocal = commonPrefixLen(targetKadId, localKadId);

    return await _tableLock.synchronized(() async {
      // Get bucket index or last bucket
      var bucketIndex = cplWithLocal;
      if (bucketIndex >= _buckets.length) {
        bucketIndex = _buckets.length - 1;
      }

      // _PeerDistanceSorter's target should be a Kademlia ID (Uint8List)
      final pds = _PeerDistanceSorter(target: targetKadId);

      // Peers in PeerInfo have dhtId as Kademlia ID (hash)
      // Ensure peer.dhtId is Uint8List if _PeerDistanceSorter expects that.
      // PeerInfo.dhtId is List<int>, needs conversion for pds.appendPeer.
      for (final peerInfo in _buckets[bucketIndex].peers()) {
        pds.appendPeer(peerInfo.id, Uint8List.fromList(peerInfo.dhtId));
      }

      // If we're short, add peers from all buckets to the right.
      if (pds.length < count) {
        for (var i = bucketIndex + 1; i < _buckets.length; i++) {
          for (final peerInfo in _buckets[i].peers()) {
            pds.appendPeer(peerInfo.id, Uint8List.fromList(peerInfo.dhtId));
          }
        }
      }

      // If we're still short, add in buckets that share _fewer_ bits.
      for (var i = bucketIndex - 1; i >= 0 && pds.length < count; i--) {
        for (final peerInfo in _buckets[i].peers()) {
          pds.appendPeer(peerInfo.id, Uint8List.fromList(peerInfo.dhtId));
        }
      }

      // Sort by distance to target
      pds.sort();

      // Truncate to requested count
      if (count < pds.length) {
        pds.peers = pds.peers.sublist(0, count);
      }

      // Convert to list of peer IDs
      return pds.peers.map((pd) => pd.peerId).toList();
    });
  }

  /// Internal method to calculate size without acquiring the lock.
  /// Assumes the lock is already held by the caller.
  int _rawSize() {
    var tot = 0;
    for (final buck in _buckets) {
      tot += buck.length;
    }
    return tot;
  }

  /// Size returns the total number of peers in the routing table
  Future<int> size() async {
    return await _tableLock.synchronized(() async {
      return _rawSize();
    });
  }

  /// ListPeers takes a RoutingTable and returns a list of all peers from all buckets in the table.
  Future<List<DhtPeerInfo>> listPeers() async {
    return await _tableLock.synchronized(() async {
      final peers = <DhtPeerInfo>[];
      for (final buck in _buckets) {
        peers.addAll(buck.peers());
      }
      return peers;
    });
  }

  /// Print prints a descriptive statement about the provided RoutingTable
  Future<void> printTable() async {
    print('Routing Table, bs = $bucketSize, Max latency = $maxLatency');
    await _tableLock.synchronized(() async {
      for (var i = 0; i < _buckets.length; i++) {
        final b = _buckets[i];
        print('\tbucket: $i');

        for (final p in b.peers()) {
          print('\t\t- ${p.id} ${metrics.latencyEWMA(p.id)}');
        }
      }
    });
  }

  /// GetDiversityStats returns the diversity stats for the Routing Table if a diversity Filter
  /// is configured.
  List<CplDiversityStats>? getDiversityStats() {
    if (df != null) {
      return df!.getDiversityStats();
    }
    return null;
  }

  /// Returns the bucket ID for a given peer (uses its Kademlia ID)
  int _bucketIdForPeer(PeerId p) {
    final remoteKadId = KadID.getKademliaIdBytes(p);
    return _bucketIdForKadId(remoteKadId);
  }

  /// maxCommonPrefix returns the maximum common prefix length between any peer in
  /// the table and the current peer's Kademlia ID.
  Future<int> maxCommonPrefix() async {
    return await _tableLock.synchronized(() async {
      for (var i = _buckets.length - 1; i >= 0; i--) {
        if (_buckets[i].length > 0) {
          // Bucket.maxCommonPrefix should also operate on Kademlia IDs (Uint8List)
          return _buckets[i].maxCommonPrefix(localKadId); // Use localKadId
        }
      }
      return 0;
    });
  }

  // Helper to compare two byte lists (Uint8List implements List<int>)
  bool _areEqualBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Generates a random PeerId whose Kademlia ID has the specified Common Prefix Length (CPL)
  /// with the local node's Kademlia ID. This is primarily a testing utility.
  Future<PeerId> genRandomPeerIdWithCpl(int cpl) async {
    // Use localKadId (the hash) for CPL calculations
    final idLengthInBits = localKadId.length * 8; // Kademlia ID length (e.g., 256 for SHA256)

    _log.warning('[genRandomPeerIdWithCpl ENTRY] Target CPL=$cpl, Kademlia ID LengthBits=$idLengthInBits, Kademlia ID ByteLength=${localKadId.length}');

    if (cpl < 0 || cpl > idLengthInBits) {
      _log.severe('[genRandomPeerIdWithCpl] CPL $cpl is out of bounds (0-$idLengthInBits for Kademlia ID).');
      throw ArgumentError('CPL must be between 0 and $idLengthInBits (Kademlia ID bit length), inclusive. Got $cpl');
    }

    const maxAttempts = 50000; 
    int attempts = 0;

    // Loop until a PeerId with the correct CPL is found
    while (attempts < maxAttempts) {
      attempts++;
      late PeerId randomOriginalPeerId;
      try {
        randomOriginalPeerId = await PeerId.random();
      } catch (e, s) {
        _log.severe('[genRandomPeerIdWithCpl attempt $attempts] Error during PeerId.random(): $e \nStack: $s');
        rethrow;
      }
      
      final randomKadId = KadID.getKademliaIdBytes(randomOriginalPeerId);

      if (attempts == 1 || attempts % 10000 == 0) { 
        _log.info('[genRandomPeerIdWithCpl attempt $attempts] Target CPL $cpl. RandomKadIdByteLength=${randomKadId.length}');
      }

      // Compare Kademlia IDs. Ensure it's not the local Kademlia ID itself,
      // unless CPL implies identity (max CPL).
      if (cpl < idLengthInBits && _areEqualBytes(randomKadId, localKadId)) {
        continue; // Try another random peer
      }
      
      final calculatedCpl = commonPrefixLen(localKadId, randomKadId);

      if (cpl == 10 && attempts % 100 == 0) { // Log calculated CPL frequently for target CPL 10
        _log.info('[genRandomPeerIdWithCpl attempt $attempts] Target CPL 10, Calculated Kademlia CPL: $calculatedCpl');
      }

      if (calculatedCpl == cpl) {
        _log.warning('[genRandomPeerIdWithCpl SUCCESS] Found peer with Target Kademlia CPL $cpl (Calculated: $calculatedCpl) in $attempts attempts. Original PeerId: ${randomOriginalPeerId.toBase58()}');
        return randomOriginalPeerId; // Return the original PeerId
      }
    }
    _log.severe('[genRandomPeerIdWithCpl FAILURE] Failed to find peer with Target Kademlia CPL $cpl after $maxAttempts attempts.');
    throw Exception('Failed to generate PeerId whose Kademlia ID has CPL $cpl after $maxAttempts attempts.');
  }
}

/// Helper class for sorting peers by distance
class _PeerDistance {
  final PeerId peerId;
  final Uint8List dhtId; // Changed to Uint8List to match Kademlia ID type

  _PeerDistance({required this.peerId, required this.dhtId});
}

/// Helper class for sorting peers by distance to a target
class _PeerDistanceSorter {
  List<_PeerDistance> peers = [];
  final Uint8List target; // Target is a Kademlia ID (Uint8List)

  _PeerDistanceSorter({required this.target});

  void appendPeer(PeerId peerId, Uint8List dhtId) { // dhtId is Uint8List
    peers.add(_PeerDistance(peerId: peerId, dhtId: dhtId));
  }

  int get length => peers.length;

  void sort() {
    peers.sort((a, b) {
      final dA = xor(Uint8List.fromList(a.dhtId), Uint8List.fromList(target));
      final dB = xor(Uint8List.fromList(b.dhtId),  Uint8List.fromList(target));

      // Compare the XOR distances byte by byte
      final len = math.min(dA.length, dB.length);
      for (var i = 0; i < len; i++) {
        if (dA[i] != dB[i]) {
          return dA[i].compareTo(dB[i]);
        }
      }

      // If all bytes are equal, the shorter one is closer
      return dA.length.compareTo(dB.length);
    });
  }
}
