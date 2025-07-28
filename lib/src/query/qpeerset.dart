
import 'dart:math' as math;

import 'package:dart_libp2p/core/peer/peer_id.dart';


/// PeerState describes the state of a peer ID during the lifecycle of an individual lookup.
enum PeerState {
  /// PeerHeard is applied to peers which have not been queried yet.
  heard,

  /// PeerWaiting is applied to peers that are currently being queried.
  waiting,

  /// PeerQueried is applied to peers who have been queried and a response was retrieved successfully.
  queried,

  /// PeerUnreachable is applied to peers who have been queried and a response was not retrieved successfully.
  unreachable,
}

/// QueryPeerset maintains the state of a Kademlia asynchronous lookup.
/// The lookup state is a set of peers, each labeled with a peer state.
class QueryPeerset {
  /// The key being searched for
  final List<int> key;

  /// All known peers
  final List<_QueryPeerState> _all = [];

  /// Whether the peers are currently sorted by distance
  bool _sorted = false;

  /// Creates a new empty set of peers.
  /// [key] is the target key of the lookup that this peer set is for.
  QueryPeerset(this.key);

  /// Finds the index of a peer in the set
  int _find(PeerId p) {
    for (var i = 0; i < _all.length; i++) {
      if (_bytesEqual(_all[i].id.toBytes(), p.toBytes())) {
        return i;
      }
    }
    return -1;
  }

  /// Calculates the XOR distance between a peer ID and the target key
  BigInt _distanceToKey(PeerId p) {
    return _xorDistance(p.toBytes(), key);
  }

  /// Calculates the XOR distance between two byte arrays
  BigInt _xorDistance(List<int> a, List<int> b) {
    final result = List<int>.filled(math.max(a.length, b.length), 0);
    
    for (var i = 0; i < result.length; i++) {
      final aVal = i < a.length ? a[i] : 0;
      final bVal = i < b.length ? b[i] : 0;
      result[i] = aVal ^ bVal;
    }
    
    return _bytesToBigInt(result);
  }

  /// Converts a byte array to a BigInt
  BigInt _bytesToBigInt(List<int> bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }

  /// Helper method to compare byte arrays
  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Tries to add the peer [p] to the peer set.
  /// If the peer is already present, no action is taken.
  /// Otherwise, the peer is added with state set to [PeerState.heard].
  /// Returns true if the peer was not already present.
  bool tryAdd(PeerId p, PeerId referredBy) {
    if (_find(p) >= 0) {
      return false;
    } else {
      _all.add(_QueryPeerState(
        id: p,
        distance: _distanceToKey(p),
        state: PeerState.heard,
        referredBy: referredBy,
      ));
      _sorted = false;
      return true;
    }
  }

  /// Sorts the peers by their distance to the target key
  void _sort() {
    if (_sorted) {
      return;
    }
    _all.sort((a, b) => a.distance.compareTo(b.distance));
    _sorted = true;
  }

  /// Sets the state of peer [p] to [s].
  /// Throws if [p] is not in the peerset.
  void setState(PeerId p, PeerState s) {
    final index = _find(p);
    if (index < 0) {
      throw ArgumentError('Peer not found in peerset');
    }
    _all[index].state = s;
  }

  /// Gets the state of peer [p].
  /// Throws if [p] is not in the peerset.
  PeerState getState(PeerId p) {
    final index = _find(p);
    if (index < 0) {
      throw ArgumentError('Peer not found in peerset');
    }
    return _all[index].state;
  }

  /// Gets the peer that referred us to the peer [p].
  /// Throws if [p] is not in the peerset.
  PeerId getReferrer(PeerId p) {
    final index = _find(p);
    if (index < 0) {
      throw ArgumentError('Peer not found in peerset');
    }
    return _all[index].referredBy;
  }

  /// Gets the closest [n] peers to the key that are in one of the given [states].
  /// Returns fewer peers if fewer peers meet the condition.
  /// The returned peers are sorted in ascending order by their distance to the key.
  List<PeerId> getClosestNInStates(int n, List<PeerState> states) {
    _sort();
    final stateSet = Set<PeerState>.from(states);
    final result = <PeerId>[];

    for (final p in _all) {
      if (stateSet.contains(p.state)) {
        result.add(p.id);
      }
    }

    if (result.length > n) {
      return result.sublist(0, n);
    }
    return result;
  }

  /// Gets all peers that are in one of the given [states].
  /// The returned peers are sorted in ascending order by their distance to the key.
  List<PeerId> getClosestInStates(List<PeerState> states) {
    return getClosestNInStates(_all.length, states);
  }

  /// Returns the number of peers in state [PeerState.heard].
  int numHeard() {
    return getClosestInStates([PeerState.heard]).length;
  }

  /// Returns the number of peers in state [PeerState.waiting].
  int numWaiting() {
    return getClosestInStates([PeerState.waiting]).length;
  }
}

/// Internal class to represent the state of a peer in a query
class _QueryPeerState {
  /// The ID of the peer
  final PeerId id;

  /// The distance from this peer to the target key
  final BigInt distance;

  /// The current state of this peer in the query
  PeerState state;

  /// The peer that referred us to this peer
  final PeerId referredBy;

  _QueryPeerState({
    required this.id,
    required this.distance,
    required this.state,
    required this.referredBy,
  });
}