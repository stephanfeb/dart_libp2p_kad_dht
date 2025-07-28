/// Routing Table Refresh implementation for libp2p-kbucket
/// 
/// This file contains the implementation of the refresh functionality for the routing table.

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:synchronized/synchronized.dart';

import '../bucket/bucket.dart';
import 'table.dart';
import '../keyspace/xor.dart';

/// maxCplForRefresh is the maximum cpl we support for refresh.
/// This limit exists because we can only generate 'maxCplForRefresh' bit prefixes for now.
const int maxCplForRefresh = 15;

final _cplRefreshLock = Lock();

/// Extension methods for the RoutingTable class to add refresh functionality
extension RoutingTableRefresh on RoutingTable {
  /// GetTrackedCplsForRefresh returns the Cpl's we are tracking for refresh.
  /// Caller is free to modify the returned list as it is a defensive copy.
  Future<List<DateTime>> getTrackedCplsForRefresh() async {
    final maxCommonPrefixValue = await maxCommonPrefix();
    final maxCpl = maxCommonPrefixValue > maxCplForRefresh ? maxCplForRefresh : maxCommonPrefixValue;

    return await _cplRefreshLock.synchronized( () async {
      final cpls = List<DateTime>.filled(maxCpl + 1, DateTime.fromMillisecondsSinceEpoch(0));
      for (var i = 0; i <= maxCpl; i++) {
        // Defaults to the zero value if we haven't refreshed it yet.
        cpls[i] = cplRefreshedAt[i] ?? DateTime.fromMillisecondsSinceEpoch(0);
      }
      return cpls;
    });
  }

  /// GenRandPeerID generates a random peerID for a given Cpl
  PeerId genRandPeerId(int targetCpl) {
    if (targetCpl > maxCplForRefresh) {
      throw Exception('cannot generate peer ID for Cpl greater than $maxCplForRefresh');
    }

    final randomKey = genRandomKey(targetCpl);
    
    // In a real implementation, this would create a proper peer ID from the key
    // For now, we'll create a simple peer ID from the hash of the key
    final hash = sha256.convert(Uint8List.fromList(randomKey)).bytes;
    return PeerId.fromBytes(Uint8List.fromList(hash));
  }

  /// GenRandomKey generates a random key matching a provided Common Prefix Length (Cpl)
  /// wrt. the local identity. The returned key matches the targetCpl first bits of the
  /// local key, the following bit is the inverse of the local key's bit at position
  /// targetCpl+1 and the remaining bits are randomly generated.
  List<int> genRandomKey(int targetCpl) {

    // Use the Kademlia ID of the local peer
    final localKadIdBytes = localKadId; // Accessing localKadId from RoutingTable instance

    if (targetCpl + 1 >= localKadIdBytes.length * 8) {
      throw Exception('cannot generate peer ID for Cpl greater than Kademlia key length');
    }
    
    final partialOffset = targetCpl ~/ 8;
    
    // Output contains the first partialOffset bytes of the local Kademlia key
    // and the remaining bytes are random
    final output = List<int>.filled(localKadIdBytes.length, 0);
    for (var i = 0; i < partialOffset; i++) {
      output[i] = localKadIdBytes[i];
    }
    
    // Fill the rest with random bytes
    final random = Random.secure();
    for (var i = partialOffset; i < output.length; i++) {
      output[i] = random.nextInt(256);
    }
    
    final remainingBits = 8 - targetCpl % 8;
    final orig = localKadIdBytes[partialOffset];
    
    final origMask = 0xFF << remainingBits;
    final randMask = ~origMask >> 1;
    final flippedBitOffset = remainingBits - 1;
    final flippedBitMask = 1 << flippedBitOffset;
    
    // Restore the remainingBits Most Significant Bits of orig
    // and flip the flippedBitOffset-th bit of orig
    output[partialOffset] = (orig & origMask) | 
                           ((orig & flippedBitMask) ^ flippedBitMask) | 
                           (output[partialOffset] & randMask);
    
    return output;
  }

  /// ResetCplRefreshedAtForID resets the refresh time for the Cpl of the given Kademlia ID.
  Future<void> resetCplRefreshedAtForID(Uint8List kadId, DateTime newTime) async { // Parameter is Uint8List Kademlia ID
    final cpl = commonPrefixLen(kadId, localKadId); // Use localKadId
    if (cpl > maxCplForRefresh) {
      return;
    }

    await _cplRefreshLock.synchronized(() async {
      cplRefreshedAt[cpl] = newTime;
    });
  }
}
