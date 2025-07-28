// Ported from go-libp2p-kad-dht/internal/logging.go

import 'dart:convert';
import 'dart:typed_data';
import 'package:multibase/multibase.dart' as mb;

/// Encodes a byte array using multibase Base32 encoding.
String multibaseB32Encode(List<int> data) {
  try {
    final codec = mb.MultibaseCodec(encodeBase: mb.Multibase.base32);
    return codec.encode(Uint8List.fromList(data));
  } catch (e) {
    // Should be unreachable
    throw Exception('Failed to encode using multibase Base32: $e');
  }
}

/// Tries to format a record key for logging.
/// 
/// Returns a formatted string if successful, or throws an exception if the key
/// cannot be formatted.
String tryFormatLoggableRecordKey(String key) {
  if (key.isEmpty) {
    throw Exception('LoggableRecordKey is empty');
  }
  
  if (key[0] == '/') {
    // It's a path (probably)
    final protoEnd = key.indexOf('/', 1);
    if (protoEnd < 0) {
      final encoded = multibaseB32Encode(utf8.encode(key));
      throw Exception('LoggableRecordKey starts with \'/\' but is not a path: $encoded');
    }
    
    final proto = key.substring(1, protoEnd);
    final cstr = key.substring(protoEnd + 1);
    
    final encStr = multibaseB32Encode(utf8.encode(cstr));
    return '/$proto/$encStr';
  }
  
  final encoded = multibaseB32Encode(utf8.encode(key));
  throw Exception('LoggableRecordKey is not a path: $encoded');
}

/// A wrapper for string record keys that provides safe logging.
class LoggableRecordKeyString {
  final String key;
  
  /// Creates a new loggable record key from a string.
  LoggableRecordKeyString(this.key);
  
  @override
  String toString() {
    try {
      return tryFormatLoggableRecordKey(key);
    } catch (e) {
      return e.toString();
    }
  }
}

/// A wrapper for byte record keys that provides safe logging.
class LoggableRecordKeyBytes {
  final List<int> key;
  
  /// Creates a new loggable record key from bytes.
  LoggableRecordKeyBytes(this.key);
  
  @override
  String toString() {
    try {
      return tryFormatLoggableRecordKey(utf8.decode(key));
    } catch (e) {
      return e.toString();
    }
  }
}

/// A wrapper for provider record bytes that provides safe logging.
class LoggableProviderRecordBytes {
  final List<int> key;
  
  /// Creates a new loggable provider record from bytes.
  LoggableProviderRecordBytes(this.key);
  
  @override
  String toString() {
    try {
      return tryFormatLoggableProviderKey(key);
    } catch (e) {
      return e.toString();
    }
  }
}

/// Tries to format a provider key for logging.
/// 
/// Returns a formatted string if successful, or throws an exception if the key
/// cannot be formatted.
String tryFormatLoggableProviderKey(List<int> key) {
    if (key.isEmpty) {
      throw Exception('LoggableProviderKey is empty');
    }
    return multibaseB32Encode(key);
}