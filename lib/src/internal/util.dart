// Ported from go-libp2p-kad-dht/internal/util.go

import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dart_multihash/dart_multihash.dart';

/// Hash is the global IPFS hash function. Uses SHA-256.
/// 
/// This is a port of the Go implementation which uses multihash SHA2_256.
Uint8List hash(List<int> data) {
  try {
    // Create a SHA-256 hash
    final digest = sha256.convert(data);
    
    // Encode as multihash
    final mh = Multihash.encode('sha2-256', Uint8List.fromList(digest.bytes));
    return mh.toBytes();
  } catch (e) {
    // This error should not happen with valid hash function selection
    throw Exception('Multihash failed to hash using SHA2_256: $e');
  }
}

/// Parses an RFC3339Nano-formatted time stamp and returns the UTC time.
DateTime parseRFC3339(String s) {
  final dt = DateTime.parse(s);
  return dt.toUtc();
}

/// Returns the string representation of the UTC value of the given time in RFC3339Nano format.
String formatRFC3339(DateTime t) {
  return t.toUtc().toIso8601String();
}