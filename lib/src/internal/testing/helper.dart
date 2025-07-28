// Ported from go-libp2p-kad-dht/internal/testing/helper.go

import 'dart:convert';
import 'dart:typed_data';
import 'package:collection/collection.dart';

/// A test validator implementation for DHT records.
class TestValidator {
  /// Selects the best record from a list of records.
  /// 
  /// Prefers "newer" records, then "valid" records.
  /// Returns -1 if no valid record is found.
  int select(String key, List<Uint8List> values) {
    int index = -1;
    
    for (int i = 0; i < values.length; i++) {
      final bytes = values[i];
      
      if (const ListEquality<int>().equals(bytes, utf8.encode('newer'))) {
        index = i;
      } else if (const ListEquality<int>().equals(bytes, utf8.encode('valid'))) {
        if (index == -1) {
          index = i;
        }
      }
    }
    
    if (index == -1) {
      throw Exception('no rec found');
    }
    
    return index;
  }
  
  /// Validates a record.
  /// 
  /// Returns null if the record is valid, or an error if it's invalid.
  void validate(String key, Uint8List value) {
    if (const ListEquality<int>().equals(value, utf8.encode('expired'))) {
      throw Exception('expired');
    }
  }
}
