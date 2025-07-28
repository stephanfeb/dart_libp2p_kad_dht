import 'dart:convert'; // For utf8
import 'dart:typed_data';

import 'package:convert/convert.dart'; // For hex
import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:dart_libp2p/core/crypto/pb/crypto.pb.dart' as crypto_pb;
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'pb/ipns.pb.dart'; // Generated from local lib/src/record/pb/ipns.proto
import 'package:dart_libp2p/core/peerstore.dart'; // For Peerstore
// key_generator may not be needed directly in this file.
// import 'package:dart_libp2p/p2p/crypto/key_generator.dart'; 
import 'package:dart_libp2p/core/crypto/keys.dart' as p2pkeys; // For libp2p PublicKey for verification
import 'validator.dart'; // Imports Validator interface

// Custom error types for IPNS validation
class InvalidIpnsRecordError implements Exception {
  final String message;
  InvalidIpnsRecordError(this.message);
  @override
  String toString() => 'InvalidIpnsRecordError: $message';
}

class IpnsRecordExpiredError extends InvalidIpnsRecordError {
  IpnsRecordExpiredError(String message) : super(message);
}

class IpnsSignatureError extends InvalidIpnsRecordError {
  IpnsSignatureError(String message) : super(message);
}

class IpnsValidator implements Validator {
  final Peerstore? peerstore;

  /// Creates a new IPNS validator.
  IpnsValidator([this.peerstore]);

  @override
  Future<void> validate(String key, Uint8List value) async {
    // 1. Deserialize 'value' into an IPNS Entry protobuf object.
    IpnsEntry entry;
    try {
      entry = IpnsEntry.fromBuffer(value);
    } catch (e) {
      throw InvalidIpnsRecordError('Failed to deserialize IPNS entry: $e');
    }

    // 2. Extract Peer ID from the IPNS key (e.g., /ipns/<peerID>)
    if (!key.startsWith('/ipns/')) {
      throw InvalidIpnsRecordError('Invalid IPNS key format: $key');
    }
    final parts = key.split('/');
    if (parts.length < 3 || parts[2].isEmpty) {
      throw InvalidIpnsRecordError('Could not extract PeerId from IPNS key: $key');
    }
    final peerIdStr = parts[2];
    PeerId peerId;
    try {
      peerId = PeerId.fromString(peerIdStr);
    } catch (e) {
      throw InvalidIpnsRecordError('Invalid PeerId string in IPNS key "$peerIdStr": $e');
    }

    // 3. Public Key Retrieval
    p2pkeys.PublicKey? verificationPubKey;

    // Attempt 1: From embedded public key in the IPNS entry
    if (entry.hasPubKey() && entry.pubKey.isNotEmpty) {
      try {
        final crypto_pb.PublicKey embeddedProtoKey = crypto_pb.PublicKey.fromBuffer(entry.pubKey);
        if (embeddedProtoKey.hasData() && embeddedProtoKey.hasType()) {
          verificationPubKey = p2pkeys.publicKeyFromProto(embeddedProtoKey);
        } else {
          print('IpnsValidator: Embedded PublicKey in IPNS entry is missing type or data.');
        }
      } catch (e) {
        print('IpnsValidator: Failed to deserialize or process embedded PublicKey: $e');
      }
    }
    
    // Attempt 2: From Peerstore's KeyBook, if not found above and peerstore is available
    if (verificationPubKey == null && peerstore != null) {
      try {
        final p2pkeys.PublicKey? keyFromBook = await peerstore!.keyBook.pubKey(peerId);
        if (keyFromBook != null) {
          verificationPubKey = keyFromBook;
        } else {
          // Key not found in keyBook, this is an expected null return.
          print('IpnsValidator: PublicKey for $peerId not found in peerstore.keyBook. Will try extracting from PeerId.');
        }
      } catch (e) {
        // Catch any other unexpected errors during the async operation itself.
        print('IpnsValidator: Error during peerstore.keyBook.pubKey call for $peerId: $e. Will try extracting from PeerId.');
      }
    }

    // Attempt 3: From PeerId itself (e.g., for inline keys), if not found above
    if (verificationPubKey == null) {
      try {
        // Assuming peerId.extractPublicKey() also returns Future<PublicKey?>
        verificationPubKey = await peerId.extractPublicKey(); 
      } catch (idError) {
        print('IpnsValidator: Error extracting public key from PeerId $peerId: $idError');
      }
    }

    // Final check before signature verification. This replaces the previous, simpler null check.
    if (verificationPubKey == null) {
      print('IpnsValidator: Could not get PublicKey for $peerId from embedded data, peerstore, or PeerId extraction.');
      throw IpnsSignatureError('Cannot verify IPNS signature; public key not found or derived for $peerId.');
    }

    // 4. Signature Verification
    if (!entry.hasSignatureV2() && !entry.hasSignatureV1()) {
      throw IpnsSignatureError('IPNS entry is missing both V1 and V2 signatures.');
    }

    // The explicit 'if (verificationPubKey == null)' check that was here previously
    // is now effectively handled by the more comprehensive "Final check" block above.

    bool sigVerified = false;
    if (entry.hasSignatureV2()) {
      try {
        final dataToVerify = _getSignatureDataV2(entry);
        sigVerified = await verificationPubKey.verify(dataToVerify, Uint8List.fromList(entry.signatureV2));
        if (!sigVerified) {
          throw IpnsSignatureError('IPNS entry V2 signature verification failed.');
        }
      } catch (e) {
        if (e is IpnsSignatureError || e is InvalidIpnsRecordError) {
          rethrow; // Rethrow the original error
        }
        // Catch specific crypto errors if possible, or rethrow as IpnsSignatureError
        throw IpnsSignatureError('Error during V2 signature verification: $e');
      }
    } else if (entry.hasSignatureV1()) {
      // V2 not present, try V1
      try {
        final dataToVerify = _getSignatureDataV1(entry); // Potentially different data for V1
        sigVerified = await verificationPubKey.verify(dataToVerify, Uint8List.fromList(entry.signatureV1));
         if (!sigVerified) {
          throw IpnsSignatureError('IPNS entry V1 signature verification failed.');
        }
      } catch (e) {
        if (e is IpnsSignatureError || e is InvalidIpnsRecordError) {
          rethrow; // Rethrow the original error
        }
        throw IpnsSignatureError('Error during V1 signature verification: $e');
      }
    }

    if (!sigVerified) {
      // This case should ideally be caught by the specific V1/V2 checks throwing.
      // If it reaches here, it means neither signature was present and verified,
      // but the initial check for presence should have caught it.
      // However, as a safeguard:
      throw IpnsSignatureError('IPNS entry signature verification failed (neither V1 nor V2 succeeded).');
    }

    // 5. Validity Check (EOL)
    if (entry.hasValidityType() && entry.validityType == IpnsEntry_ValidityType.EOL) {
      if (!entry.hasValidity() || entry.validity.isEmpty) {
        throw InvalidIpnsRecordError('IPNS entry has EOL validity type but missing validity data.');
      }
      try {
        final validityStr = utf8.decode(entry.validity);
        final eolTime = DateTime.parse(validityStr); // Assumes RFC3339 format
        if (DateTime.now().isAfter(eolTime)) {
          throw IpnsRecordExpiredError('IPNS entry has expired. EOL: $validityStr');
        }
      } catch (e) {
        if (e is IpnsRecordExpiredError || e is InvalidIpnsRecordError) {
          rethrow; // Rethrow the original error
        }
        throw InvalidIpnsRecordError('Failed to parse EOL validity data: "${utf8.decode(entry.validity, allowMalformed: true)}". Error: $e');
      }
    }

    // 6. Sequence Number (basic check)
    // The sequence number is crucial for selecting the latest record.
    // It's a uint64, so non-negativity is implied by the type if parsed correctly.
    // We just need to ensure it's present.
    if (!entry.hasSequence()) {
      throw InvalidIpnsRecordError('IPNS entry is missing sequence number.');
    }

    // All checks passed if no exception was thrown
    print('IpnsValidator: Record for key "$key" passed validation. PeerId: ${peerId.toBase58()}, Seq: ${entry.sequence}');
  }

  @override
  Future<int> select(String key, List<Uint8List> values) async {
    if (values.isEmpty) {
      throw Exception("can't select from no values for IPNS key '$key'");
    }

    IpnsEntry? bestEntrySoFar;
    int? bestIndex;

    for (int i = 0; i < values.length; i++) {
      final rawValue = values[i];
      IpnsEntry currentEntry;

      try {
        currentEntry = IpnsEntry.fromBuffer(rawValue);
        // Validate the current entry.
        // Note: `validate` can throw, so this also filters out invalid records.
        await validate(key, rawValue); 
      } catch (e) {
        // print('IpnsValidator.select: Record at index $i for key "$key" is invalid: $e');
        continue; // Skip invalid record
      }

      // If this is the first valid record found
      if (bestEntrySoFar == null) {
        bestEntrySoFar = currentEntry;
        bestIndex = i;
        continue;
      }

      // Compare with the current best record
      // 1. Higher sequence number is better
      if (currentEntry.hasSequence() && bestEntrySoFar.hasSequence()) {
        if (currentEntry.sequence > bestEntrySoFar.sequence) {
          bestEntrySoFar = currentEntry;
          bestIndex = i;
          continue;
        }
        if (currentEntry.sequence < bestEntrySoFar.sequence) {
          continue; // Current is older, stick with bestEntrySoFar
        }
        // If sequence numbers are equal, proceed to EOL comparison
      } else if (currentEntry.hasSequence() && !bestEntrySoFar.hasSequence()) {
        // current has sequence, best doesn't - current is better
        bestEntrySoFar = currentEntry;
        bestIndex = i;
        continue;
      } else if (!currentEntry.hasSequence() && bestEntrySoFar.hasSequence()) {
        // current doesn't have sequence, best does - stick with bestEntrySoFar
        continue;
      }
      // If neither has sequence (or both are equal and we are here), they are equivalent by sequence.

      // 2. If sequence numbers are equal, compare EOL (later EOL is better)
      // This part only runs if sequences are equal or both are missing (effectively equal).
      bool currentHasEOL = currentEntry.hasValidityType() &&
                           currentEntry.validityType == IpnsEntry_ValidityType.EOL &&
                           currentEntry.hasValidity();
      bool bestHasEOL = bestEntrySoFar.hasValidityType() &&
                        bestEntrySoFar.validityType == IpnsEntry_ValidityType.EOL &&
                        bestEntrySoFar.hasValidity();

      if (currentHasEOL && bestHasEOL) {
        try {
          final currentEolTime = DateTime.parse(utf8.decode(currentEntry.validity));
          final bestEolTime = DateTime.parse(utf8.decode(bestEntrySoFar.validity));
          if (currentEolTime.isAfter(bestEolTime)) {
            bestEntrySoFar = currentEntry;
            bestIndex = i;
          }
          // If EOLs are equal, or current is not after best, stick with current best (tie-break: first one)
        } catch (e) {
          // Error parsing EOL, treat as non-comparable or one without EOL as worse.
          // If currentEntry's EOL parsing failed, it's not better.
          // If bestEntrySoFar's EOL parsing failed (shouldn't happen if it was set),
          // and current's is fine, current might be better.
          // For simplicity, if parsing fails, we don't update.
        }
      } else if (currentHasEOL && !bestHasEOL) {
        // Current has EOL, best doesn't: current is better
        bestEntrySoFar = currentEntry;
        bestIndex = i;
      }
      // If current doesn't have EOL and best does, stick with best.
      // If neither has EOL, they are equivalent by EOL.

      // 3. Tie-breaking with value (lexicographically larger is better)
      // This is a common tie-breaker if sequence and EOL are equivalent.
      // This part only runs if sequence and EOL are considered equivalent.
      if (bestEntrySoFar != null && currentEntry.hasValue() && bestEntrySoFar.hasValue()) {
        // Compare Uint8List lexicographically
        final valComparison = _compareUint8Lists(
          Uint8List.fromList(currentEntry.value), 
          Uint8List.fromList(bestEntrySoFar.value)
        );
        if (valComparison > 0) { // currentEntry.value is greater
          bestEntrySoFar = currentEntry;
          bestIndex = i;
        }
      }
    }

    if (bestIndex == null) {
      throw Exception("No valid IPNS records found for key '$key' among ${values.length} candidates");
    }

    return bestIndex;
  }

  // Helper to compare two Uint8Lists lexicographically
  // Returns > 0 if a > b, < 0 if a < b, 0 if a == b
  int _compareUint8Lists(Uint8List a, Uint8List b) {
    final len = a.length < b.length ? a.length : b.length;
    for (int i = 0; i < len; i++) {
      if (a[i] > b[i]) return 1;
      if (a[i] < b[i]) return -1;
    }
    if (a.length > b.length) return 1;
    if (a.length < b.length) return -1;
    return 0;
  }

  // Helper to construct data for V2 signature
  // IMPORTANT: The exact fields and their order/serialization must match the IPNS specification.
  // This is a common representation based on go-libp2p specs.
  Uint8List _getSignatureDataV2(IpnsEntry entry) {
    // For V2, the data to sign is: "ipns-signature:" + entry.Data
    // entry.Data is expected to be the CBOR-encoded map of fields.
    // This method assumes entry.Data is already correctly populated.

    final prefix = utf8.encode('ipns-signature:');
    
    var builder = BytesBuilder();
    builder.add(prefix);
    
    // entry.data is List<int> in the protobuf definition.
    // If entry.data is not set or empty, this will just sign the prefix.
    // The Go implementation's Validate function checks for empty entry.Data later,
    // but for signature creation/verification, it's used as is.
    if (entry.hasData() && entry.data.isNotEmpty) {
      builder.add(entry.data);
    } else {
      // This situation is unusual for a valid V2 record being validated,
      // as `Create` in Go always populates `Data`.
      // However, to match Go's `ipnsEntryDataForSigV2` which appends `e.Data`
      // (which could be empty if not set, though `Create` sets it),
      // we append it if present. If not, we sign just the prefix.
      // A signature mismatch will occur if the signer used non-empty data.
      print('IpnsValidator: Warning: entry.data is missing or empty for V2 signature payload construction. Signing prefix only.');
    }
    
    return builder.toBytes();
  }

  // Helper to construct data for V1 signature
  // V1 data is: entry.Value + entry.Validity + string(entry.ValidityType)
  Uint8List _getSignatureDataV1(IpnsEntry entry) {
    var builder = BytesBuilder();

    // entry.value is List<int>. If not set, it's an empty list.
    builder.add(entry.value);
    
    // entry.validity is List<int>. If not set, it's an empty list.
    builder.add(entry.validity);
    
    // entry.validityType is an enum. We need its integer value as a string, then UTF-8 bytes.
    // entry.validityType will have a default value (e.g., EOL with int value 0) if not explicitly set.
    final validityTypeStr = entry.validityType.value.toString();
    builder.add(utf8.encode(validityTypeStr));
    
    return builder.toBytes();
  }

}
