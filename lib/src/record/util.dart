/// Utility functions for the record package.

/// Error thrown when a record type is invalid.
class InvalidRecordTypeError implements Exception {
  final String message;
  
  InvalidRecordTypeError([this.message = 'Invalid record type']);
  
  @override
  String toString() => 'InvalidRecordTypeError: $message';
}

/// Splits a key in the form `/$namespace/$path` into `$namespace` and `$path`.
/// 
/// Returns a tuple of (namespace, path).
/// Throws [InvalidRecordTypeError] if the key format is invalid.
(String, String) splitKey(String key) {
  if (key.isEmpty || key[0] != '/') {
    throw InvalidRecordTypeError();
  }

  // Remove the leading slash
  key = key.substring(1);

  final i = key.indexOf('/');
  if (i <= 0) {
    throw InvalidRecordTypeError();
  }

  return (key.substring(0, i), key.substring(i + 1));
}