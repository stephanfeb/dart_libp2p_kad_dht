import 'dart:typed_data';
import 'package:dart_libp2p/p2p/crypto/key_generator.dart';
import 'package:test/test.dart';
import 'package:dart_libp2p_kad_dht/src/record/public_key_validator.dart';
import 'package:dart_libp2p_kad_dht/src/record/pb/crypto.pb.dart' as record_pb;
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/crypto/keys.dart' as p2pkeys;
import 'package:dart_libp2p/core/crypto/pb/crypto.pb.dart' as libp2p_crypto_pb; // For KeyType enum if needed by generateKeyPair

void main() {
  group('PublicKeyValidator', () {
    late PublicKeyValidator validator;
    late p2pkeys.PrivateKey samplePrivKey;
    late p2pkeys.PublicKey samplePubKey;
    late PeerId samplePeerId;
    late String validRecordKey;
    late Uint8List validRecordValueBytes;

    setUp(() async {
      validator = PublicKeyValidator();
      // Try as top-level functions if exported from keys.dart
      final kp = await generateEd25519KeyPair();
      samplePrivKey = kp.privateKey;;
      samplePubKey = kp.publicKey;
      samplePeerId = PeerId.fromPublicKey(samplePubKey);
      validRecordKey = '/pk/${samplePeerId.toString()}';

      // samplePubKey.marshal() returns the bytes of a libp2p_crypto_pb.PublicKey message
      final marshaledLibp2pPb = samplePubKey.marshal();
      // We need the .data field from that protobuf message for our record_pb.PublicKey
      final libp2pPbInstance = libp2p_crypto_pb.PublicKey.fromBuffer(marshaledLibp2pPb);
      final rawPublicKeyBytes = libp2pPbInstance.data;

      final recordPubKeyProto = record_pb.PublicKey()
        ..type = record_pb.KeyType.Ed25519 
        ..data = rawPublicKeyBytes; // Use the extracted raw public key bytes
      validRecordValueBytes = recordPubKeyProto.writeToBuffer();
    });

    group('validate', () {
      test('should successfully validate a matching PublicKey record and key', () {
        expect(
          () => validator.validate(validRecordKey, validRecordValueBytes),
          returnsNormally,
        );
      });

      test('should throw InvalidPublicKeyProtoError for malformed protobuf data', () {
        final bytes = Uint8List.fromList([1, 2, 3, 4, 5]); // Malformed
        expect(
          () => validator.validate(validRecordKey, bytes),
          throwsA(isA<InvalidPublicKeyProtoError>()),
        );
      });

      test('should throw InvalidPublicKeyProtoError if PublicKey data is missing in proto', () async {
        // Protobuf required fields mean fromBuffer will fail.
        final incompletePublicKey = record_pb.PublicKey()..type = record_pb.KeyType.Ed25519; // Data not set
        final incompleteBytes = incompletePublicKey.writeToBuffer();
        expect(
          () => validator.validate(validRecordKey, incompleteBytes),
          throwsA(isA<InvalidPublicKeyProtoError>()),
        );
      });

      test('should throw InvalidPublicKeyProtoError if PublicKey type is missing in proto', () async {
        final incompletePublicKey = record_pb.PublicKey()..data = Uint8List.fromList([1,2,3]); // Type not set
        final incompleteBytes = incompletePublicKey.writeToBuffer();
        expect(
          () => validator.validate(validRecordKey, incompleteBytes),
          throwsA(isA<InvalidPublicKeyProtoError>()),
        );
      });
      
      test('should throw PublicKeyMismatchError if key PeerId does not match PublicKey in record', () async {
        final otherPrivKey = await generateEd25519KeyPair(); 
        final otherPeerId = await PeerId.fromPublicKey(otherPrivKey.publicKey);
        final mismatchedKey = '/pk/${otherPeerId.toString()}';

        expect(
          () => validator.validate(mismatchedKey, validRecordValueBytes),
          throwsA(isA<PublicKeyMismatchError>()),
        );
      });

      test('should throw InvalidRecordKeyError for key with wrong prefix', () {
        final badKey = '/wrongprefix/${samplePeerId.toString()}';
        expect(
          () => validator.validate(badKey, validRecordValueBytes),
          throwsA(isA<InvalidRecordKeyError>().having((e) => e.message, 'message', contains('does not start with prefix'))),
        );
      });

      test('should throw InvalidRecordKeyError for key missing PeerId part', () {
        const badKey = '/pk/';
        expect(
          () => validator.validate(badKey, validRecordValueBytes),
          throwsA(isA<InvalidRecordKeyError>().having((e) => e.message, 'message', contains('missing PeerId part'))),
        );
      });

      test('should throw InvalidRecordKeyError for key with invalid PeerId string', () {
        const badKey = '/pk/notAValidPeerIdString';
        expect(
          () => validator.validate(badKey, validRecordValueBytes),
          throwsA(isA<InvalidRecordKeyError>().having((e) => e.message, 'message', contains('neither valid PeerId string nor raw multihash bytes'))),
        );
      });
    });

    group('select', () {
      late p2pkeys.PrivateKey samplePrivKey2;
      late p2pkeys.PublicKey samplePubKey2;
      late Uint8List validRecordValueBytes2; 

      setUp(() async {
        final kp = await generateEd25519KeyPair();
        samplePrivKey2 = kp.privateKey;
        samplePubKey2 = kp.publicKey;
        
        final marshaledLibp2pPb2 = samplePubKey2.marshal();
        final libp2pPbInstance2 = libp2p_crypto_pb.PublicKey.fromBuffer(marshaledLibp2pPb2);
        final rawPublicKeyBytes2 = libp2pPbInstance2.data;

        final recordPubKeyProto2 = record_pb.PublicKey()
          ..type = record_pb.KeyType.Ed25519
          ..data = rawPublicKeyBytes2; // Use extracted raw bytes
        validRecordValueBytes2 = recordPubKeyProto2.writeToBuffer(); 
      });

      final malformedBytes = Uint8List.fromList([255, 254, 253]);

      test('should throw if values list is empty', () {
        expect(
          () => validator.select(validRecordKey, []),
          throwsA(predicate((e) => e is Exception && e.toString().contains("can't select from no values"))),
        );
      });

      test('should select the first valid record if multiple are present and match the key', () async {
        final values = [validRecordValueBytes, validRecordValueBytes]; 
        expect(await validator.select(validRecordKey, values), equals(0));
      });
      
      test('should select the first valid and matching record', () async {
        final values = [malformedBytes, validRecordValueBytes2, validRecordValueBytes, malformedBytes];
        expect(await validator.select(validRecordKey, values), equals(2));
      });

      test('should select the only valid and matching record', () async {
        final values = [malformedBytes, validRecordValueBytes2, validRecordValueBytes];
        expect(await validator.select(validRecordKey, values), equals(2));
      });
      
      test('should throw if no valid records matching the key are found', () {
        final values = [malformedBytes, validRecordValueBytes2];
        expect(
          () => validator.select(validRecordKey, values),
          throwsA(predicate((e) => e is Exception && e.toString().contains('No valid public key record found'))),
        );
      });

       test('should throw if all records are valid protobufs but none match the key', () async {
         final kp = await generateEd25519KeyPair();
        final otherPrivKey3 = kp.privateKey;
        final otherPubKey3 = kp.publicKey;
        
        final marshaledLibp2pPb3 = otherPubKey3.marshal();
        final libp2pPbInstance3 = libp2p_crypto_pb.PublicKey.fromBuffer(marshaledLibp2pPb3);
        final rawPublicKeyBytes3 = libp2pPbInstance3.data;
        
        final otherPubKey3Proto = (record_pb.PublicKey()
          ..type=record_pb.KeyType.Ed25519
          ..data=rawPublicKeyBytes3); // Use extracted raw bytes
        final otherPubKey3BytesValue = otherPubKey3Proto.writeToBuffer();
        
        final values = [validRecordValueBytes2, otherPubKey3BytesValue];
        expect(
          () => validator.select(validRecordKey, values),
          throwsA(predicate((e) => e is Exception && e.toString().contains('No valid public key record found'))),
        );
      });
    });
  });
}
