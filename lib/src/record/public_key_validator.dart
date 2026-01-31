import 'dart:typed_data';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/crypto/keys.dart' as p2pkeys;
import 'package:dart_libp2p/core/crypto/pb/crypto.pb.dart' as libp2p_crypto_pb;
import 'package:dart_libp2p_kad_dht/src/record/pb/crypto.pb.dart' as record_pb;
import 'package:dart_libp2p_kad_dht/src/record/validator.dart';

// Custom Error Classes
class InvalidRecordKeyError implements Exception {
  final String message;
  InvalidRecordKeyError(this.message);
  @override
  String toString() => 'InvalidRecordKeyError: $message';
}

class PublicKeyMismatchError implements Exception {
  final String message;
  PublicKeyMismatchError(this.message);
  @override
  String toString() => 'PublicKeyMismatchError: $message';
}

class InvalidPublicKeyProtoError implements Exception {
  final String message;
  InvalidPublicKeyProtoError(this.message);
  @override
  String toString() => 'InvalidPublicKeyProtoError: $message';
}


class PublicKeyValidator implements Validator {
  static const String keyPrefix = '/pk/';

  @override
  Future<void> validate(String key, Uint8List value) async {
    // 1. Validate the key format and extract the peer ID portion
    if (!key.startsWith(keyPrefix)) {
      throw InvalidRecordKeyError('Key does not start with prefix "$keyPrefix"');
    }
    final peerIdPart = key.substring(keyPrefix.length);
    if (peerIdPart.isEmpty) {
      throw InvalidRecordKeyError('Key is missing PeerId part');
    }

    // The peer ID portion may be either:
    // a) A base58/CID-encoded PeerId string (as used by some Dart callers)
    // b) Raw multihash bytes (as used by Go and the spec — binary key)
    //
    // Try base58 string first (more specific), then raw bytes.
    PeerId expectedPeerId;
    try {
      expectedPeerId = PeerId.fromString(peerIdPart);
    } catch (_) {
      // Fall back to interpreting as raw multihash bytes (spec-compliant binary key).
      // Go DHT embeds raw multihash bytes directly after /pk/.
      try {
        final rawBytes = Uint8List.fromList(peerIdPart.codeUnits);
        expectedPeerId = PeerId.fromBytes(rawBytes);
      } catch (e) {
        throw InvalidRecordKeyError(
            'PeerId part in key is neither valid PeerId string nor raw multihash bytes: $e');
      }
    }

    // 2. Deserialize the public key from the value
    record_pb.PublicKey recordPubKeyProto;
    try {
      recordPubKeyProto = record_pb.PublicKey.fromBuffer(value);
    } catch (e) {
      throw InvalidPublicKeyProtoError('Failed to parse record PublicKey protobuf: $e');
    }

    // 3. Construct a libp2p PublicKey
    p2pkeys.PublicKey p2pLibp2pPubKey;
    try {
      final libp2pProtoKey = libp2p_crypto_pb.PublicKey();
      libp2pProtoKey.data = recordPubKeyProto.data;

      switch (recordPubKeyProto.type) {
        case record_pb.KeyType.RSA:
          libp2pProtoKey.type = libp2p_crypto_pb.KeyType.RSA;
          break;
        case record_pb.KeyType.Ed25519:
          libp2pProtoKey.type = libp2p_crypto_pb.KeyType.Ed25519;
          break;
        case record_pb.KeyType.Secp256k1:
          libp2pProtoKey.type = libp2p_crypto_pb.KeyType.Secp256k1;
          break;
        case record_pb.KeyType.ECDSA:
          libp2pProtoKey.type = libp2p_crypto_pb.KeyType.ECDSA;
          break;
        default:
          throw InvalidPublicKeyProtoError(
              'Unsupported PublicKey type: ${recordPubKeyProto.type}');
      }

      p2pLibp2pPubKey = p2pkeys.publicKeyFromProto(libp2pProtoKey);
    } catch (e) {
      if (e is InvalidPublicKeyProtoError) rethrow;
      throw InvalidPublicKeyProtoError(
          'Failed to construct libp2p PublicKey from record proto: $e');
    }

    // 4. Derive PeerId from the public key
    PeerId derivedPeerId;
    try {
      derivedPeerId = PeerId.fromPublicKey(p2pLibp2pPubKey);
    } catch (e) {
      throw InvalidPublicKeyProtoError('Failed to derive PeerId from PublicKey: $e');
    }

    // 5. Compare derived PeerId with the one from the key
    if (derivedPeerId.toBase58() != expectedPeerId.toBase58()) {
      throw PublicKeyMismatchError(
          'PublicKey does not match PeerId in key. '
          'Expected: "${expectedPeerId.toBase58()}", Got: "${derivedPeerId.toBase58()}"');
    }
  }

  @override
  Future<int> select(String key, List<Uint8List> values) async {
    if (values.isEmpty) {
      throw Exception("can't select from no values for key '$key'");
    }

    for (int i = 0; i < values.length; i++) {
      try {
        await validate(key, values[i]);
        return i;
      } catch (e) {
        // This value is invalid, try the next one.
      }
    }

    throw Exception(
        "No valid public key record found for key '$key' among ${values.length} candidate(s)");
  }
}
