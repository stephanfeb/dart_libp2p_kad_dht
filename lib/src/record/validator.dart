/// Validator interfaces and implementations for the record package.
import 'dart:typed_data';
import 'util.dart';

/// Error thrown when a better record is found.
class BetterRecordError implements Exception {
  /// The key associated with the record.
  final String key;
  
  /// The best value that was found, according to the record's validator.
  final Uint8List value;
  
  BetterRecordError(this.key, this.value);
  
  @override
  String toString() => 'BetterRecordError: found better value for "$key"';
}

/// Interface that should be implemented by record validators.
abstract class Validator {
  /// Validates the given record, returning an error if it's invalid
  /// (e.g., expired, signed by the wrong key, etc.).
  Future<void> validate(String key, Uint8List value);

  /// Selects the best record from the set of records (e.g., the newest).
  ///
  /// Decisions made by select should be stable.
  /// Returns the index of the best value.
  Future<int> select(String key, List<Uint8List> values);
}


