import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'keyspace.dart';
import 'xor.dart';

/// KadID represents a Kademlia ID in the DHT.
/// 
/// This is the Dart equivalent of kbucket.ID from the Go implementation.
/// It's essentially a wrapper around a byte array that represents a node's
/// position in the Kademlia keyspace.
class KadID {
  /// The underlying byte representation of the Kademlia ID
  final Uint8List _bytes;

  /// Creates a new KadID from a byte array
  KadID(this._bytes);

  /// Creates a KadID from a string key
  static KadID fromKey(String key) {
    final keyBytes = Uint8List.fromList(key.codeUnits);
    final hash = sha256.convert(keyBytes).bytes;
    return KadID(Uint8List.fromList(hash));
  }

  /// Creates a KadID from a PeerId by hashing its canonical byte representation.
  static KadID fromPeerId(PeerId peerId) {
    return KadID(getKademliaIdBytes(peerId));
  }

  /// Generates the Kademlia ID (SHA256 hash) from a PeerId's canonical byte representation.
  static Uint8List getKademliaIdBytes(PeerId peerId) {
    final peerIdBytes = peerId.toBytes(); // Use the canonical byte representation
    final hash = sha256.convert(peerIdBytes).bytes;
    return Uint8List.fromList(hash);
  }

  /// Returns the byte representation of this KadID (which is its Kademlia hash)
  Uint8List get bytes => _bytes;

  /// Returns a Key representation of this KadID in the XOR keyspace
  Key toKey() {
    return XorKeySpace.instance.key(_bytes);
  }

  /// Returns the distance between this KadID and another
  BigInt distance(KadID other) {
    return toKey().distance(other.toKey());
  }

  /// Returns a string representation of this KadID
  @override
  String toString() {
    return _bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
  }

  /// Returns whether this KadID is equal to another
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! KadID) return false;
    
    if (_bytes.length != other._bytes.length) return false;
    
    for (var i = 0; i < _bytes.length; i++) {
      if (_bytes[i] != other._bytes[i]) return false;
    }
    
    return true;
  }

  /// Returns a hash code for this KadID
  @override
  int get hashCode => Object.hashAll(_bytes);
}
