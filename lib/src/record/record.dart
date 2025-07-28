/// Functions for working with records.
import 'dart:typed_data';
import '../pb/record.pb.dart';

/// Creates a record for the given key/value pair.
///
/// This is the Dart equivalent of the Go MakePutRecord function.
Record makePutRecord(String key, Uint8List value) {
  return Record()
    ..key = Uint8List.fromList(key.codeUnits)
    ..value = value;
}

/// Creates a record for the given key/value pair with a timestamp.
///
/// This is an extension of the Go MakePutRecord function that also sets the timeReceived field.
Record makePutRecordWithTime(String key, Uint8List value, String timeReceived) {
  return Record()
    ..key = Uint8List.fromList(key.codeUnits)
    ..value = value
    ..timeReceived = timeReceived;
}