
import 'dart:typed_data';

import 'package:dart_libp2p_kad_dht/src/record/util.dart';
import 'package:dart_libp2p_kad_dht/src/record/validator.dart';

/// A validator that delegates to sub-validators by namespace.
class NamespacedValidator implements Validator {
  final Map<String, Validator> _validators = {};

  /// Creates a new namespaced validator with the given validators.
  NamespacedValidator([Map<String, Validator>? validators]) {
    if (validators != null) {
      _validators.addAll(validators);
    }
  }

  /// Adds a validator for the given namespace.
  void addValidator(String namespace, Validator validator) {
    _validators[namespace] = validator;
  }

  /// Gets a validator by namespace.
  Validator? operator [](String namespace) => _validators[namespace];

  /// Sets a validator for a namespace.
  void operator []=(String namespace, Validator validator) {
    _validators[namespace] = validator;
  }

  /// Gets the validator for the given namespace.
  Validator? getValidator(String namespace) {
    return _validators[namespace];
  }

  /// Returns the number of validators.
  int get length => _validators.length;

  /// Looks up the validator responsible for validating the given key.
  Validator? validatorByKey(String key) {
    try {
      final (namespace, _) = splitKey(key);
      return _validators[namespace];
    } catch (e) {
      return null;
    }
  }

  @override
  Future<void> validate(String key, Uint8List value) async {
    final validator = validatorByKey(key);
    if (validator == null) {
      throw InvalidRecordTypeError();
    }
    await validator.validate(key, value);
  }

  @override
  Future<int> select(String key, List<Uint8List> values) async {
    if (values.isEmpty) {
      throw Exception("can't select from no values");
    }

    final validator = validatorByKey(key);
    if (validator == null) {
      throw InvalidRecordTypeError();
    }

    return await validator.select(key, values);
  }
}
