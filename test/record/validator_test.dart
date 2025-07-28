import 'dart:typed_data';
import 'package:dart_libp2p_kad_dht/src/record/namespace_validator.dart';
import 'package:dart_libp2p_kad_dht/src/record/validator.dart';
import 'package:dart_libp2p_kad_dht/src/record/util.dart'; // For splitKey, assuming it's needed or used by NamespacedValidator implicitly
import 'package:test/test.dart';

// Mock Validator for testing purposes
class MockValidator implements Validator {
  int validateCalledCount = 0;
  String? lastValidateKey;
  Uint8List? lastValidateValue;

  int selectCalledCount = 0;
  String? lastSelectKey;
  List<Uint8List>? lastSelectValues;
  int selectReturnValue = 0; // Default to selecting the first element

  bool throwOnValidate = false;
  bool throwOnSelect = false;

  @override
  Future<void> validate(String key, Uint8List value) async {
    validateCalledCount++;
    lastValidateKey = key;
    lastValidateValue = value;
    if (throwOnValidate) {
      throw Exception('MockValidator: validate error');
    }
  }

  @override
  Future<int> select(String key, List<Uint8List> values) async {
    selectCalledCount++;
    lastSelectKey = key;
    lastSelectValues = values;
    if (throwOnSelect) {
      throw Exception('MockValidator: select error');
    }
    if (values.isEmpty) {
      throw Exception("MockValidator: can't select from no values");
    }
    return selectReturnValue < values.length ? selectReturnValue : 0;
  }

  void reset() {
    validateCalledCount = 0;
    lastValidateKey = null;
    lastValidateValue = null;
    selectCalledCount = 0;
    lastSelectKey = null;
    lastSelectValues = null;
    selectReturnValue = 0;
    throwOnValidate = false;
    throwOnSelect = false;
  }
}

void main() {
  group('NamespacedValidator Tests', () {
    late NamespacedValidator namespacedValidator;
    late MockValidator pkValidator;
    late MockValidator ipnsValidator;

    setUp(() {
      namespacedValidator = NamespacedValidator();
      pkValidator = MockValidator();
      ipnsValidator = MockValidator();

      // Use namespace keys as returned by splitKey (without leading/trailing slashes)
      namespacedValidator.addValidator('pk', pkValidator);
      namespacedValidator.addValidator('ipns', ipnsValidator);
    });

    test('validatorByKey should return correct validator for namespace', () {
      expect(namespacedValidator.validatorByKey('/pk/somekey'), equals(pkValidator));
      expect(namespacedValidator.validatorByKey('/ipns/otherkey'), equals(ipnsValidator));
      expect(namespacedValidator.validatorByKey('/unknown/key'), isNull);
    });

    test('validate should dispatch to correct sub-validator', () async {
      final pkKey = '/pk/peerid';
      final pkValue = Uint8List.fromList([1, 2, 3]);
      await namespacedValidator.validate(pkKey, pkValue);
      expect(pkValidator.validateCalledCount, equals(1));
      expect(pkValidator.lastValidateKey, equals(pkKey));
      expect(pkValidator.lastValidateValue, equals(pkValue));
      expect(ipnsValidator.validateCalledCount, equals(0));

      final ipnsKey = '/ipns/hash';
      final ipnsValue = Uint8List.fromList([4, 5, 6]);
      await namespacedValidator.validate(ipnsKey, ipnsValue);
      expect(ipnsValidator.validateCalledCount, equals(1));
      expect(ipnsValidator.lastValidateKey, equals(ipnsKey));
      expect(ipnsValidator.lastValidateValue, equals(ipnsValue));
      expect(pkValidator.validateCalledCount, equals(1)); // Should still be 1
    });

    test('select should dispatch to correct sub-validator', () async {
      final pkKey = '/pk/peerid';
      final pkValues = [Uint8List.fromList([1]), Uint8List.fromList([2])];
      pkValidator.selectReturnValue = 1; // Expect to select the second element
      final pkResult = await namespacedValidator.select(pkKey, pkValues);
      
      expect(pkValidator.selectCalledCount, equals(1));
      expect(pkValidator.lastSelectKey, equals(pkKey));
      expect(pkValidator.lastSelectValues, equals(pkValues));
      expect(pkResult, equals(1));
      expect(ipnsValidator.selectCalledCount, equals(0));

      final ipnsKey = '/ipns/hash';
      final ipnsValues = [Uint8List.fromList([3]), Uint8List.fromList([4])];
      ipnsValidator.selectReturnValue = 0; // Expect to select the first element
      final ipnsResult = await namespacedValidator.select(ipnsKey, ipnsValues);

      expect(ipnsValidator.selectCalledCount, equals(1));
      expect(ipnsValidator.lastSelectKey, equals(ipnsKey));
      expect(ipnsValidator.lastSelectValues, equals(ipnsValues));
      expect(ipnsResult, equals(0));
      expect(pkValidator.selectCalledCount, equals(1)); // Should still be 1
    });

    test('validate should throw InvalidRecordTypeError for unknown namespace', () async {
      expect(
        () async => namespacedValidator.validate('/foo/bar', Uint8List(0)),
        throwsA(isA<InvalidRecordTypeError>()),
      );
    });

    test('select should throw InvalidRecordTypeError for unknown namespace', () async {
      expect(
        () async => namespacedValidator.select('/foo/bar', [Uint8List(0)]),
        throwsA(isA<InvalidRecordTypeError>()),
      );
    });

    test('select should throw Exception if values list is empty', () async {
      // This tests the behavior of NamespacedValidator itself when it calls sub-validator's select
      // The sub-validator (MockValidator) also throws, but NamespacedValidator has its own check.
      // Let's ensure the NamespacedValidator's check is hit if the sub-validator didn't throw first.
      // However, the current implementation of NamespacedValidator.select calls validator.select(key, values)
      // and if values is empty, the sub-validator (MockValidator) will throw.
      // If we want to test NamespacedValidator's own empty check (if it had one before calling sub-validator),
      // we'd need a different setup. The current code relies on sub-validator for this.
      // The test as written will pass because MockValidator throws.
      expect(
        () async => namespacedValidator.select('/pk/somekey', []),
        throwsA(isA<Exception>()), // MockValidator throws "can't select from no values"
      );
    });
     test('validate should propagate exceptions from sub-validator', () async {
      pkValidator.throwOnValidate = true;
      expect(
        () async => namespacedValidator.validate('/pk/somekey', Uint8List(0)),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('MockValidator: validate error'))),
      );
    });

    test('select should propagate exceptions from sub-validator', () async {
      pkValidator.throwOnSelect = true;
      expect(
        () async => namespacedValidator.select('/pk/somekey', [Uint8List(0)]),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('MockValidator: select error'))),
      );
    });

  });
}
