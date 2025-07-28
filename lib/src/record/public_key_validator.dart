import 'dart:typed_data';
import 'package:convert/convert.dart'; // For hex encoding if needed for debugging
import 'package:dart_libp2p/core/peer/peer_id.dart'; 
import 'package:dart_libp2p/core/crypto/keys.dart' as p2pkeys; 
import 'package:dart_libp2p/core/crypto/pb/crypto.pb.dart' as libp2p_crypto_pb; // Import for libp2p's own crypto proto
import 'package:dart_libp2p_kad_dht/src/record/pb/crypto.pb.dart' as record_pb; // Protobuf for this project's record structure
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
    // 1. Validate the key format and extract PeerId string
    if (!key.startsWith(keyPrefix)) {
      throw InvalidRecordKeyError('Key "$key" does not start with prefix "$keyPrefix"');
    }
    final expectedPeerIdStr = key.substring(keyPrefix.length);
    if (expectedPeerIdStr.isEmpty) {
      throw InvalidRecordKeyError('Key "$key" is missing PeerId part');
    }
    // Validate if expectedPeerIdStr is a valid PeerId.
    // PeerId.fromString will throw if it's not a valid multihash.
    try {
      PeerId.fromString(expectedPeerIdStr);
    } catch (e) {
      throw InvalidRecordKeyError('PeerId part "$expectedPeerIdStr" in key "$key" is invalid: ${e.toString()}');
    }

    // 2. Deserialize the public key from the value (using this project's record_pb.PublicKey)
    record_pb.PublicKey recordPubKeyProto;
    try {
      recordPubKeyProto = record_pb.PublicKey.fromBuffer(value);
    } catch (e) {
      throw InvalidPublicKeyProtoError('Failed to parse record PublicKey protobuf for key "$key": ${e.toString()}');
    }

    // 3. Construct a libp2p p2pkeys.PublicKey
    p2pkeys.PublicKey p2pLibp2pPubKey;
    try {
      // Create an instance of libp2p's own crypto_pb.PublicKey
      final libp2pProtoKey = libp2p_crypto_pb.PublicKey();
      libp2pProtoKey.data = recordPubKeyProto.data;

      // Map KeyType from record_pb to libp2p_crypto_pb
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
          throw InvalidPublicKeyProtoError('Unsupported PublicKey type in record proto: ${recordPubKeyProto.type}');
      }
      
      p2pLibp2pPubKey = p2pkeys.publicKeyFromProto(libp2pProtoKey);

    } catch (e) {
      throw InvalidPublicKeyProtoError('Failed to construct libp2p PublicKey from record proto for key "$key": ${e.toString()}');
    }

    // 4. Derive PeerId from the libp2p PublicKey
    PeerId derivedPeerId; // Use PeerId directly
    try {
      derivedPeerId = PeerId.fromPublicKey(p2pLibp2pPubKey);
    } catch (e) {
      throw InvalidPublicKeyProtoError('Failed to derive PeerId from libp2p PublicKey for key "$key": ${e.toString()}');
    }

    // 5. Compare derived PeerId with the one from the key
    if (derivedPeerId.toString() != expectedPeerIdStr) {
      throw PublicKeyMismatchError(
          'PublicKey in record for key "$key" does not match PeerId. Expected: "$expectedPeerIdStr", Got: "${derivedPeerId.toString()}"');
    }
    // If all checks pass, validation is successful.
  }

  @override
  Future<int> select(String key, List<Uint8List> values) async {
    if (values.isEmpty) {
      throw Exception("can't select from no values for key '$key'");
    }

    int? firstValidIndex;

    for (int i = 0; i < values.length; i++) {
      try {
        // Validate the current value.
        await validate(key, values[i]); // Added await
        
        // If validation passes, this is a candidate.
        // For public keys, the first valid one is generally considered the best/only one.
        firstValidIndex = i;
        break; // Found a valid record, no need to check further for basic selection.
      } catch (e) {
        // This value is invalid, log or ignore and try the next one.
        // print('DEBUG: Record at index $i for key "$key" is invalid: $e');
      }
    }

    if (firstValidIndex != null) {
      return firstValidIndex;
    }

    // If no valid record was found in the list.
    throw Exception("No valid public key record found for key '$key' among ${values.length} candidate(s)");
  }
}
