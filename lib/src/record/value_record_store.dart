import 'package:logging/logging.dart';

import '../amino/defaults.dart';
import '../dht/v2/errors/dht_errors.dart';
import '../internal/util.dart' show truncateForLog;
import '../pb/record.dart';
import 'namespace_validator.dart';
import 'record_signer.dart';

/// The value records of one DHT node, with the rules for accepting them.
///
/// Both `IpfsDHTv2` (through its `ProtocolManager`) and the legacy
/// `IpfsDHT` use it, so they check, select and expire records in the same
/// way, as go-libp2p-kad-dht does:
///
/// - a record must be for its key, a signed record must have a valid
///   signature, and the validator of the key's namespace must accept it;
/// - a key with no validator is refused, unless [allowUnvalidatedRecords]
///   is set; such a record must then be signed by its author;
/// - the validator's `select()` decides between a stored and a new record;
/// - records expire [maxRecordAge] after they were stored.
///
/// Keys are strings with one character per byte (`String.fromCharCodes`).
class ValueRecordStore {
  static final Logger _logger = Logger('ValueRecordStore');

  /// Validators by key namespace. Null means no namespace has one.
  NamespacedValidator? validator;

  /// How long a record stays after it was stored.
  Duration maxRecordAge;

  /// Whether keys without a namespace validator are accepted (signed
  /// records only).
  bool allowUnvalidatedRecords;

  final Map<String, _StoredRecord> _records = {};

  ValueRecordStore({
    this.validator,
    this.maxRecordAge = AminoConstants.defaultMaxRecordAge,
    this.allowUnvalidatedRecords = false,
  });

  /// How often to call [pruneExpired]: [maxRecordAge], but at most 1 hour.
  Duration get pruneInterval =>
      maxRecordAge < const Duration(hours: 1) ? maxRecordAge : const Duration(hours: 1);

  /// Checks a value record for [key].
  ///
  /// - The record's key must be [key].
  /// - If the record carries an author or a signature, the signature must be
  ///   valid.
  /// - If the key's namespace has a validator, the validator must accept the
  ///   value.
  /// - If it has none, the record is refused, unless
  ///   [allowUnvalidatedRecords] is set (or [requireValidator] is false);
  ///   then the record must be signed by its author.
  ///
  /// Throws a [DHTProtocolException] when the record is not valid.
  Future<void> validateRecord(String key, Record record, {bool requireValidator = true}) async {
    if (!bytesEqual(record.key, key.codeUnits)) {
      throw DHTProtocolException('Record key does not match key ${truncateForLog(key)}...');
    }

    final signed = record.signature.isNotEmpty || record.author.isNotEmpty;
    if (signed && !await RecordSigner.validateRecordSignature(record)) {
      throw DHTProtocolException('Invalid record signature');
    }

    final v = validator?.validatorByKey(key);
    if (v != null) {
      try {
        await v.validate(key, record.value);
      } catch (e) {
        throw DHTProtocolException('Record refused by the namespace validator: $e', cause: e);
      }
      return;
    }

    if (requireValidator && !allowUnvalidatedRecords) {
      throw DHTProtocolException(
          'No validator for the namespace of key ${truncateForLog(key)}... '
          '(register one, or set allowUnvalidatedRecords)');
    }
    if (!signed) {
      throw DHTProtocolException('A record without a namespace validator must be signed by its author');
    }
  }

  /// Returns the index of the best record in [records] for [key].
  ///
  /// With a namespace validator, its `select()` decides. Without one (see
  /// [allowUnvalidatedRecords]), the author with the most records wins, ties
  /// going to the author of the earliest record in the list (callers put the
  /// local record first), and then the newest record of that author wins.
  Future<int> selectRecord(String key, List<Record> records) async {
    if (records.isEmpty) {
      throw ArgumentError('selectRecord needs at least one record');
    }
    if (records.length == 1) return 0;

    final v = validator?.validatorByKey(key);
    if (v != null) {
      return await v.select(key, records.map((r) => r.value).toList());
    }

    final counts = <String, int>{};
    final firstIndex = <String, int>{};
    for (var i = 0; i < records.length; i++) {
      final author = String.fromCharCodes(records[i].author);
      counts[author] = (counts[author] ?? 0) + 1;
      firstIndex.putIfAbsent(author, () => i);
    }
    String? bestAuthor;
    for (final author in counts.keys) {
      if (bestAuthor == null ||
          counts[author]! > counts[bestAuthor]! ||
          (counts[author] == counts[bestAuthor] && firstIndex[author]! < firstIndex[bestAuthor]!)) {
        bestAuthor = author;
      }
    }
    var best = -1;
    for (var i = 0; i < records.length; i++) {
      if (String.fromCharCodes(records[i].author) != bestAuthor) continue;
      if (best < 0 || records[i].timeReceived > records[best].timeReceived) best = i;
    }
    return best;
  }

  /// Whether [incoming] should replace [stored] for [key].
  Future<bool> isBetterThanStored(String key, Record stored, Record incoming) async {
    final v = validator?.validatorByKey(key);
    if (v != null) {
      // As go-libp2p-kad-dht: the received record goes first, and it is
      // kept unless select() prefers the stored one.
      try {
        final i = await v.select(key, [incoming.value, stored.value]);
        return i == 0;
      } catch (e) {
        _logger.fine('select() failed for key ${truncateForLog(key)}...: $e');
        return false;
      }
    }
    // No validator: only the author of the stored record can replace it,
    // and only with a newer record.
    if (!bytesEqual(stored.author, incoming.author)) return false;
    return incoming.timeReceived > stored.timeReceived;
  }

  /// Validates [record] (see [validateRecord]) and stores it if it is
  /// better than the stored one. Use the default [requireValidator] for a
  /// record a peer sent in `PUT_VALUE`. Returns whether it was stored.
  /// Throws a [DHTProtocolException] when the record is not valid.
  Future<bool> put(String key, Record record, {bool requireValidator = true}) async {
    await validateRecord(key, record, requireValidator: requireValidator);
    return await _storeIfBetter(key, record);
  }

  /// Stores a record written by the local node.
  ///
  /// The record must be signed with a valid signature, and the validator of
  /// the key's namespace (if any) must accept it; a key without a validator
  /// is not refused. A stored record is replaced only if the new record is
  /// better (see [isBetterThanStored]). Returns whether it was stored.
  /// Throws a [DHTProtocolException] when the record is not valid.
  Future<bool> putLocal(String key, Record record) async {
    if (!await RecordSigner.validateRecordSignature(record)) {
      throw DHTProtocolException('Cannot store record with invalid signature');
    }
    final v = validator?.validatorByKey(key);
    if (v != null) {
      try {
        await v.validate(key, record.value);
      } catch (e) {
        throw DHTProtocolException('Record refused by the namespace validator: $e', cause: e);
      }
    }
    return await _storeIfBetter(key, record);
  }

  Future<bool> _storeIfBetter(String key, Record record) async {
    final existing = get(key);
    if (existing != null && !await isBetterThanStored(key, existing, record)) {
      _logger.fine('Keeping stored record for key ${truncateForLog(key)}...: the new record is not better');
      return false;
    }
    _records[key] = _StoredRecord(record, DateTime.now());
    return true;
  }

  /// Returns the stored record for [key], or null when there is none or it
  /// is older than [maxRecordAge] (it is then removed).
  Record? get(String key) {
    final entry = _records[key];
    if (entry == null) return null;
    if (_isExpired(entry)) {
      _records.remove(key);
      return null;
    }
    return entry.record;
  }

  /// Removes the record for [key]. Returns whether there was one.
  bool remove(String key) => _records.remove(key) != null;

  /// Removes all records. Returns how many there were.
  int clear() {
    final count = _records.length;
    _records.clear();
    return count;
  }

  /// The keys of the records that have not expired.
  List<String> get keys {
    pruneExpired();
    return _records.keys.toList();
  }

  /// The records that have not expired.
  List<Record> get records {
    pruneExpired();
    return _records.values.map((e) => e.record).toList();
  }

  /// The number of records that have not expired.
  int get length {
    pruneExpired();
    return _records.length;
  }

  bool _isExpired(_StoredRecord entry) =>
      DateTime.now().difference(entry.storedAt) > maxRecordAge;

  /// Removes the records that are older than [maxRecordAge]. Returns how
  /// many were removed.
  int pruneExpired() {
    final expired = _records.entries.where((e) => _isExpired(e.value)).map((e) => e.key).toList();
    for (final key in expired) {
      _records.remove(key);
    }
    if (expired.isNotEmpty) {
      _logger.fine('Removed ${expired.length} expired record(s)');
    }
    return expired.length;
  }

  /// Whether [a] and [b] hold the same bytes.
  static bool bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A record and the time it was stored.
class _StoredRecord {
  final Record record;
  final DateTime storedAt;

  _StoredRecord(this.record, this.storedAt);
}
