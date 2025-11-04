/// Bucket implementation for libp2p-kbucket
/// 
/// This file contains the implementation of a bucket in the Kademlia DHT.

import 'dart:collection';
import 'dart:typed_data';

import 'package:dart_libp2p/core/peer/peer_id.dart';

import '../keyspace/xor.dart';

/// PeerInfo holds all related information for a peer in the K-Bucket.
class DhtPeerInfo {
  /// The peer ID
  final PeerId id;

  /// LastUsefulAt is the time instant at which the peer was last "useful" to us.
  /// Please see the DHT docs for the definition of usefulness.
  DateTime lastUsefulAt;

  /// LastSuccessfulOutboundQueryAt is the time instant at which we last got a
  /// successful query response from the peer.
  DateTime lastSuccessfulOutboundQueryAt;

  /// AddedAt is the time this peer was added to the routing table.
  final DateTime addedAt;

  /// ID of the peer in the DHT XOR keyspace
  final List<int> dhtId;

  /// If a bucket is full, this peer can be replaced to make space for a new peer.
  bool replaceable;


  @override
  String toString() {
    return id.toString();
  }

  /// Constructor for PeerInfo
  DhtPeerInfo({
    required this.id,
    required this.lastUsefulAt,
    required this.lastSuccessfulOutboundQueryAt,
    required this.addedAt,
    required this.dhtId,
    required this.replaceable,
  });

  /// Creates a copy of this PeerInfo
  DhtPeerInfo copy() {
    return DhtPeerInfo(
      id: id,
      lastUsefulAt: lastUsefulAt,
      lastSuccessfulOutboundQueryAt: lastSuccessfulOutboundQueryAt,
      addedAt: addedAt,
      dhtId: List<int>.from(dhtId),
      replaceable: replaceable,
    );
  }
}

/// Bucket holds a list of peers.
/// We synchronize on the Routing Table lock for all access to the bucket
/// and so do not need any locks in the bucket.
/// If we want/need to avoid locking the table for accessing a bucket in the future,
/// it WILL be the caller's responsibility to synchronize all access to a bucket.
class Bucket {
  /// The linked list of peers in this bucket
  final LinkedList<PeerInfoEntry> _list = LinkedList<PeerInfoEntry>();

  /// Creates a new bucket
  Bucket();

  /// Returns all peers in the bucket
  /// It is safe for the caller to modify the returned objects as it is a defensive copy
  List<DhtPeerInfo> peers() {
    final ps = <DhtPeerInfo>[];
    if (_list.isEmpty) {
      return ps;
    }
    for (PeerInfoEntry? e = _list.first; e != null; e = e.next) {
      ps.add(e.peerInfo.copy());
    }
    return ps;
  }

  /// Returns the "minimum" peer in the bucket based on the `lessThan` comparator passed to it.
  /// It is NOT safe for the comparator to mutate the given `PeerInfo`
  /// as we pass in a pointer to it.
  /// It is NOT safe to modify the returned value.
  DhtPeerInfo? min(bool Function(DhtPeerInfo p1, DhtPeerInfo p2) lessThan) {
    if (_list.isEmpty) {
      return null;
    }

    var minVal = _list.first.peerInfo;

    for (var e = _list.first.next; e != null; e = e.next) {
      if (lessThan(e.peerInfo, minVal)) {
        minVal = e.peerInfo;
      }
    }

    return minVal;
  }

  /// Updates all the peers in the bucket by applying the given update function.
  void updateAllWith(void Function(DhtPeerInfo p) updateFnc) {
    for (PeerInfoEntry? e = _list.first; e != null; e = e.next) {
      updateFnc(e.peerInfo);
    }
  }

  /// Returns the IDs of all the peers in the bucket.
  List<PeerId> peerIds() {
    final ps = <PeerId>[];
    for (PeerInfoEntry? e = _list.first; e != null; e = e.next) {
      ps.add(e.peerInfo.id);
    }
    return ps;
  }

  /// Returns the peer with the given ID if it exists
  /// Returns null if the peerId does not exist
  DhtPeerInfo? getPeer(PeerId p) {
    if (_list.isEmpty) {
      return null;
    }
    for (PeerInfoEntry? e = _list.first; e != null; e = e.next) {
      if (e.peerInfo.id == p) {
        return e.peerInfo;
      }
    }
    return null;
  }

  /// Removes the peer with the given ID from the bucket.
  /// Returns true if successful, false otherwise.
  bool remove(PeerId id) {
    if (_list.isEmpty) {
      return false;
    }
    
    for (PeerInfoEntry? e = _list.first; e != null; e = e.next) {
      if (e.peerInfo.id == id) {
        e.unlink();
        return true;
      }
    }
    return false;
  }

  /// Adds a peer to the front of the bucket
  void pushFront(DhtPeerInfo p) {
    _list.addFirst(PeerInfoEntry(p));
  }

  /// Returns the number of peers in the bucket
  int get length => _list.length;

  /// Splits a bucket's peers into two buckets, the methods receiver will have
  /// peers with CPL equal to cpl, the returned bucket will have peers with CPL
  /// greater than cpl (returned bucket has closer peers)
  Bucket split(int cpl, List<int> target) {
    final newBucket = Bucket();
    final entriesToMove = <PeerInfoEntry>[];

    for (PeerInfoEntry? e = _list.first; e != null; e = e.next) {
      final pDhtId = e.peerInfo.dhtId;
      final peerCPL = commonPrefixLen(pDhtId, target);
      if (peerCPL > cpl) {
        entriesToMove.add(e);
      }
    }

    // Remove entries from this bucket and add to new bucket
    for (var e in entriesToMove) {
      e.unlink();
      newBucket._list.add(PeerInfoEntry(e.peerInfo));
    }

    return newBucket;
  }

  /// Returns the maximum common prefix length between any peer in
  /// the bucket with the target ID.
  int maxCommonPrefix(List<int> target) {
    var maxCpl = 0;
    for (PeerInfoEntry? e = _list.first; e != null; e = e.next) {
      final cpl = commonPrefixLen(e.peerInfo.dhtId, target);
      if (cpl > maxCpl) {
        maxCpl = cpl;
      }
    }
    return maxCpl;
  }
}

/// Helper class to store PeerInfo in a LinkedList
base class PeerInfoEntry extends LinkedListEntry<PeerInfoEntry> {
  final DhtPeerInfo peerInfo;

  PeerInfoEntry(this.peerInfo);
}

/// Returns the common prefix length of two IDs
int commonPrefixLen(List<int> a, List<int> b) {
  return zeroPrefixLen(Uint8List.fromList(xor(Uint8List.fromList(a), Uint8List.fromList(b))));
}

// /// XOR two byte arrays together
// List<int> xor(List<int> a, List<int> b) {
//   final length = a.length < b.length ? a.length : b.length;
//   final result = List<int>.filled(length, 0);
//
//   for (var i = 0; i < length; i++) {
//     result[i] = a[i] ^ b[i];
//   }
//
//   return result;
// }
