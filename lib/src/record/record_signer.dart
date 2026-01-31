import 'dart:typed_data';
import 'dart:convert';

import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:logging/logging.dart';

import '../pb/record.dart';
import 'validator.dart';

/// RecordSigner handles cryptographic signing and validation of DHT records
/// 
/// This class provides methods to:
/// - Create properly signed records
/// - Validate record signatures
/// - Verify record authenticity
class RecordSigner {
  static final Logger _logger = Logger('RecordSigner');
  
  /// Creates a signed record
  /// 
  /// [key] - The record key (will be UTF-8 encoded)
  /// [value] - The record value
  /// [privateKey] - The private key to sign with
  /// [peerId] - The peer ID of the author
  /// 
  /// Returns a properly signed Record
  static Future<Record> createSignedRecord({
    required String key,
    required Uint8List value,
    required PrivateKey privateKey,
    required PeerId peerId,
  }) async {
    final keyBytes = Uint8List.fromList(key.codeUnits);
    final timeReceived = DateTime.now().millisecondsSinceEpoch;
    final author = peerId.toBytes();
    
    // Create the data to sign
    final dataToSign = _createSignatureData(keyBytes, value, timeReceived, author);
    
    // Sign the data
    final signature = await privateKey.sign(dataToSign);
    
    _logger.fine('Created signed record for key: ${key}... (${signature.length} bytes signature)');
    
    return Record(
      key: keyBytes,
      value: value,
      timeReceived: timeReceived,
      author: author,
      signature: signature,
    );
  }
  
  /// Validates a record's signature
  /// 
  /// [record] - The record to validate
  /// [publicKey] - The public key to verify against (optional - will be derived from author if not provided)
  /// 
  /// Returns true if the signature is valid
  static Future<bool> validateRecordSignature(Record record, [PublicKey? publicKey]) async {
    try {
      // Get the public key if not provided
      PublicKey verificationKey;
      if (publicKey != null) {
        verificationKey = publicKey;
      } else {
        // Try to derive from the author (peer ID)
        final authorPeerId = PeerId.fromBytes(record.author);
        final derivedKey = await authorPeerId.extractPublicKey();
        if (derivedKey == null) {
          _logger.warning('Could not derive public key from author peer ID');
          return false;
        }
        verificationKey = derivedKey;
      }
      
      // Recreate the signed data
      final dataToSign = _createSignatureData(
        record.key,
        record.value,
        record.timeReceived,
        record.author,
      );
      
      // Verify the signature
      final isValid = await verificationKey.verify(dataToSign, record.signature);
      
      if (isValid) {
        _logger.fine('Record signature validation successful');
      } else {
        _logger.warning('Record signature validation failed');
      }
      
      return isValid;
    } catch (e) {
      _logger.warning('Error validating record signature: $e');
      return false;
    }
  }
  
  /// Creates the data that should be signed for a record
  /// 
  /// The signature data includes:
  /// - The record key
  /// - The record value  
  /// - The timestamp
  /// - The author peer ID
  /// 
  /// This ensures the signature covers all critical record data
  static Uint8List _createSignatureData(
    Uint8List key,
    Uint8List value,
    int timeReceived,
    Uint8List author,
  ) {
    final builder = BytesBuilder();
    
    // Add a prefix to prevent signature reuse in other contexts
    builder.add(utf8.encode('libp2p-record:'));
    
    // Add key length and key
    builder.add(_uint32ToBytes(key.length));
    builder.add(key);
    
    // Add value length and value
    builder.add(_uint32ToBytes(value.length));
    builder.add(value);
    
    // Add timestamp as 8-byte little-endian
    builder.add(_uint64ToBytes(timeReceived));
    
    // Add author length and author
    builder.add(_uint32ToBytes(author.length));
    builder.add(author);
    
    return builder.toBytes();
  }
  
  /// Converts a 32-bit unsigned integer to bytes (little-endian)
  static Uint8List _uint32ToBytes(int value) {
    final bytes = Uint8List(4);
    bytes[0] = value & 0xFF;
    bytes[1] = (value >> 8) & 0xFF;
    bytes[2] = (value >> 16) & 0xFF;
    bytes[3] = (value >> 24) & 0xFF;
    return bytes;
  }
  
  /// Converts a 64-bit unsigned integer to bytes (little-endian)
  static Uint8List _uint64ToBytes(int value) {
    final bytes = Uint8List(8);
    bytes[0] = value & 0xFF;
    bytes[1] = (value >> 8) & 0xFF;
    bytes[2] = (value >> 16) & 0xFF;
    bytes[3] = (value >> 24) & 0xFF;
    bytes[4] = (value >> 32) & 0xFF;
    bytes[5] = (value >> 40) & 0xFF;
    bytes[6] = (value >> 48) & 0xFF;
    bytes[7] = (value >> 56) & 0xFF;
    return bytes;
  }
}

/// DHT Record Validator that uses cryptographic signature verification
/// 
/// This validator implements the standard DHT record validation:
/// 1. Signature verification using the author's public key
/// 2. Timestamp validation (records should not be too old)
/// 3. Key-value consistency checks
class DHTRecordValidator implements Validator {
  static final Logger _logger = Logger('DHTRecordValidator');
  
  /// Maximum age for records (default: 24 hours)
  final Duration maxRecordAge;
  
  /// Creates a new DHT record validator
  /// 
  /// [maxRecordAge] - Maximum age for records before they're considered invalid
  DHTRecordValidator({
    this.maxRecordAge = const Duration(hours: 24),
  });
  
  @override
  Future<void> validate(String key, Uint8List value) async {
    try {
      // The value should be a serialized Record
      final record = Record.fromJson(jsonDecode(utf8.decode(value)));
      
      // Validate the record key matches the lookup key
      final recordKeyString = String.fromCharCodes(record.key);
      if (recordKeyString != key) {
        throw Exception('Record key mismatch: expected "$key", got "$recordKeyString"');
      }
      
      // Validate timestamp (not too old)
      final recordAge = DateTime.now().millisecondsSinceEpoch - record.timeReceived;
      if (recordAge > maxRecordAge.inMilliseconds) {
        throw Exception('Record is too old: ${Duration(milliseconds: recordAge)} > $maxRecordAge');
      }
      
      // Validate the signature
      final isValidSignature = await RecordSigner.validateRecordSignature(record);
      if (!isValidSignature) {
        throw Exception('Invalid record signature');
      }
      
      _logger.fine('Record validation successful for key: ${key}...');
    } catch (e) {
      _logger.warning('Record validation failed for key: ${key}...: $e');
      rethrow;
    }
  }
  
  @override
  Future<int> select(String key, List<Uint8List> values) async {
    if (values.isEmpty) {
      throw Exception("can't select from no values for key '$key'");
    }
    
    final validRecords = <(int, Record)>[];
    
    // Find all valid records
    for (int i = 0; i < values.length; i++) {
      try {
        final record = Record.fromJson(jsonDecode(utf8.decode(values[i])));
        
        // Validate the record
        await validate(key, values[i]);
        
        validRecords.add((i, record));
      } catch (e) {
        _logger.fine('Record at index $i failed validation: $e');
      }
    }
    
    if (validRecords.isEmpty) {
      throw Exception("No valid records found for key '$key'");
    }
    
    // Select the most recent valid record
    validRecords.sort((a, b) => b.$2.timeReceived.compareTo(a.$2.timeReceived));
    
    _logger.fine('Selected record at index ${validRecords.first.$1} (most recent) for key: ${key}...');
    return validRecords.first.$1;
  }
} 