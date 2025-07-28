

import 'dart:typed_data';

import 'package:dart_libp2p_kad_dht/src/record/validator.dart';

/// A validator for generic values, typically used for the '/v/' namespace.
class GenericValidator implements Validator {
  @override
  Future<void> validate(String key, Uint8List value) async {
    // For generic values, we don't have specific validation rules beyond basic well-formedness,
    // which is assumed if the record was created.
    return Future<void>.value();
  }

  @override
  Future<int> select(String key, List<Uint8List> values) async {
    if (values.isEmpty) {
      throw Exception("can't select from no values");
    }
    // For generic values, select the first one as "best"
    return Future<int>.value(0);
  }
}
