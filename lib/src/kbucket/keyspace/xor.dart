/// XOR Keyspace implementation for libp2p-kbucket
/// 
/// This file contains the XOR keyspace implementation, which normalizes identifiers
/// using SHA-256 and measures distance by XORing keys together.

import 'dart:typed_data';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:convert/convert.dart';
import 'keyspace.dart';

/// XORKeySpace is a KeySpace which:
/// - normalizes identifiers using a cryptographic hash (sha256)
/// - measures distance by XORing keys together
class XorKeySpace implements KeySpace {
  /// Singleton instance of XorKeySpace
  static final XorKeySpace instance = XorKeySpace._();

  /// Private constructor for singleton pattern
  XorKeySpace._();

  /// Key converts an identifier into a Key in this space.
  @override
  Key key(Uint8List id) {
    final hash = sha256.convert(id).bytes;
    return Key(
      space: this,
      original: id,
      bytes: Uint8List.fromList(hash),
    );
  }

  /// Equal returns whether keys are equal in this key space
  @override
  bool equal(Key k1, Key k2) {
    if (k1.bytes.length != k2.bytes.length) {
      return false;
    }
    
    for (var i = 0; i < k1.bytes.length; i++) {
      if (k1.bytes[i] != k2.bytes[i]) {
        return false;
      }
    }
    
    return true;
  }

  /// Distance returns the distance metric in this key space
  @override
  BigInt distance(Key k1, Key k2) {
    // XOR the keys
    final xorResult = xor(k1.bytes, k2.bytes);
    
    // Convert to BigInt
    return BigInt.parse(hex.encode(xorResult), radix: 16);
  }

  /// Less returns whether the first key is smaller than the second.
  @override
  bool less(Key k1, Key k2) {
    final len = math.min(k1.bytes.length, k2.bytes.length);
    
    for (var i = 0; i < len; i++) {
      if (k1.bytes[i] != k2.bytes[i]) {
        return k1.bytes[i] < k2.bytes[i];
      }
    }
    
    return k1.bytes.length < k2.bytes.length;
  }
}

/// XOR two byte arrays together
Uint8List xor(Uint8List a, Uint8List b) {
  final length = math.min(a.length, b.length);
  final result = Uint8List(length);
  
  for (var i = 0; i < length; i++) {
    result[i] = a[i] ^ b[i];
  }
  
  return result;
}

/// ZeroPrefixLen returns the number of consecutive zeroes in a byte slice.
int zeroPrefixLen(Uint8List id) {
  var zeroes = 0;
  
  for (var i = 0; i < id.length; i++) {
    if (id[i] == 0) {
      zeroes += 8;
    } else {
      // Count leading zeroes in this byte
      var b = id[i];
      var count = 0;
      for (var j = 7; j >= 0; j--) {
        if ((b & (1 << j)) == 0) {
          count++;
        } else {
          break;
        }
      }
      zeroes += count;
      break;
    }
  }
  
  return zeroes;
}