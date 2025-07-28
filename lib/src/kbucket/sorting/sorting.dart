/// Sorting implementation for libp2p-kbucket
/// 
/// This file contains functionality for sorting peers by their XOR distance from a target.

import 'dart:typed_data';


import 'package:dart_libp2p/core/peer/peer_id.dart';

import '../keyspace/xor.dart';

/// A helper class to store a peer and its distance from a target
class PeerDistance {
  /// The peer ID
  final PeerId peerId;
  
  /// The distance from the target
  final Uint8List distance;

  /// Creates a new PeerDistance
  PeerDistance({
    required this.peerId,
    required this.distance,
  });
}

/// A helper class to sort peers by their distance to a target
class PeerDistanceSorter {
  /// The list of peers and their distances
  List<PeerDistance> peers = [];
  
  /// The target ID
  final Uint8List target;

  /// Creates a new PeerDistanceSorter with the given target
  PeerDistanceSorter({
    required this.target,
  });

  /// Adds a peer to the sorter
  void appendPeer(PeerId peerId, Uint8List dhtId) {
    peers.add(PeerDistance(
      peerId: peerId,
      distance: xor(target, dhtId),
    ));
  }

  /// Sorts the peers by their distance to the target
  void sort() {
    peers.sort((a, b) {
      // Compare the XOR distances byte by byte
      final len = a.distance.length < b.distance.length 
          ? a.distance.length 
          : b.distance.length;
      
      for (var i = 0; i < len; i++) {
        if (a.distance[i] != b.distance[i]) {
          return a.distance[i].compareTo(b.distance[i]);
        }
      }
      
      // If all bytes are equal, the shorter one is closer
      return a.distance.length.compareTo(b.distance.length);
    });
  }
}

/// Sorts the given peers by their ascending distance from the target.
/// Returns a new list containing the sorted peers.
List<PeerId> sortClosestPeers(List<PeerId> peers, Uint8List target) {
  final sorter = PeerDistanceSorter(target: target);
  
  for (final peer in peers) {
    // Convert peer ID to DHT ID
    final dhtId = _convertPeerId(peer);
    sorter.appendPeer(peer, dhtId);
  }
  
  sorter.sort();
  
  return sorter.peers.map((p) => p.peerId).toList();
}

/// Converts a PeerId to a Uint8List for DHT operations
Uint8List _convertPeerId(PeerId peerId) {
  // In a real implementation, this would hash the peer ID
  // For now, we'll use a simple conversion
  return Uint8List.fromList(peerId.toBytes().toList());
}