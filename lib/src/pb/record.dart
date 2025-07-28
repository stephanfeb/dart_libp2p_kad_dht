import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:meta/meta.dart';

/// Record represents a DHT record that contains a value
/// for a key. It contains a timestamp and public key that
/// is used to verify the record.
@immutable
class Record extends Equatable {
  /// The key that references this record
  final Uint8List key;

  /// The actual value this record is storing
  final Uint8List value;

  /// Time the record was created (milliseconds since epoch)
  final int timeReceived;

  /// Public key that created this record
  final Uint8List author;

  /// A signature of the key and value
  final Uint8List signature;

  /// Creates a new Record
  const Record({
    required this.key,
    required this.value,
    required this.timeReceived,
    required this.author,
    required this.signature,
  });

  /// Creates a Record from a map
  factory Record.fromJson(Map<String, dynamic> json) {
    // Helper to convert List<dynamic> (often List<int>) from JSON to Uint8List
    Uint8List _listToUint8List(dynamic list) {
      if (list is Uint8List) {
        return list;
      }
      if (list is List) {
        return Uint8List.fromList(list.cast<int>());
      }
      throw ArgumentError('Expected List or Uint8List for byte array field, got ${list.runtimeType}');
    }

    return Record(
      key: _listToUint8List(json['key']),
      value: _listToUint8List(json['value']),
      timeReceived: json['timeReceived'] as int,
      author: _listToUint8List(json['author']),
      signature: _listToUint8List(json['signature']),
    );
  }

  /// Converts this Record to a map
  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'value': value,
      'timeReceived': timeReceived,
      'author': author,
      'signature': signature,
    };
  }

  @override
  List<Object?> get props => [key, value, timeReceived, author, signature];

  @override
  String toString() {
    return 'Record{key: $key, value: $value, timeReceived: $timeReceived, author: $author, signature: $signature}';
  }
}
