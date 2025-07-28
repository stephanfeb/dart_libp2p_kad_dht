/// Keyspace implementation for libp2p-kbucket
/// 
/// This file contains the core interfaces and classes for the keyspace functionality.

import 'dart:typed_data';
import 'package:pointycastle/api.dart';

/// Key represents an identifier in a KeySpace. It holds a reference to the
/// associated KeySpace, as well references to both the Original identifier,
/// as well as the new, KeySpace Bytes one.
class Key {
  /// Space is the KeySpace this Key is related to.
  final KeySpace space;

  /// Original is the original value of the identifier
  final Uint8List original;

  /// Bytes is the new value of the identifier, in the KeySpace.
  final Uint8List bytes;

  /// Constructor for Key
  Key({
    required this.space,
    required this.original,
    required this.bytes,
  });

  /// Equal returns whether this key is equal to another.
  bool equal(Key other) {
    if (space != other.space) {
      throw Exception('Keys not in same key space.');
    }
    return space.equal(this, other);
  }

  /// Less returns whether this key comes before another.
  bool less(Key other) {
    if (space != other.space) {
      throw Exception('Keys not in same key space.');
    }
    return space.less(this, other);
  }

  /// Distance returns this key's distance to another
  BigInt distance(Key other) {
    if (space != other.space) {
      throw Exception('Keys not in same key space.');
    }
    return space.distance(this, other);
  }
}

/// KeySpace is an object used to do math on identifiers. Each keyspace has its
/// own properties and rules. See XorKeySpace.
abstract class KeySpace {
  /// Key converts an identifier into a Key in this space.
  Key key(Uint8List id);

  /// Equal returns whether keys are equal in this key space
  bool equal(Key k1, Key k2);

  /// Distance returns the distance metric in this key space
  BigInt distance(Key k1, Key k2);

  /// Less returns whether the first key is smaller than the second.
  bool less(Key k1, Key k2);
}

/// Sorts a list of keys by their distance to a center key.
List<Key> sortByDistance(KeySpace space, Key center, List<Key> toSort) {
  // Create a copy of the list to avoid modifying the original
  final toSortCopy = List<Key>.from(toSort);
  
  // Sort the copy by distance to center
  toSortCopy.sort((a, b) {
    final distA = center.distance(a);
    final distB = center.distance(b);
    return distA.compareTo(distB);
  });
  
  return toSortCopy;
}