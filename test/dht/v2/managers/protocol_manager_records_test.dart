import 'dart:typed_data';

import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/config/dht_config.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/errors/dht_errors.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/managers/protocol_manager.dart';
import 'package:dart_libp2p_kad_dht/src/pb/dht_message.dart';
import 'package:dart_libp2p_kad_dht/src/pb/record.dart';
import 'package:dart_libp2p_kad_dht/src/record/namespace_validator.dart';
import 'package:dart_libp2p_kad_dht/src/record/public_key_validator.dart';
import 'package:dart_libp2p_kad_dht/src/record/record_signer.dart';
import 'package:dart_libp2p_kad_dht/src/record/validator.dart';
import 'package:test/test.dart';

import 'protocol_manager_test.dart'
    show MockHost, MockRoutingManager, MockMetricsManager, MockProviderStore;

/// Test namespace: any value is valid; the value with the highest first
/// byte is best (whatever its timestamp).
class HighestByteValidator implements Validator {
  @override
  Future<void> validate(String key, Uint8List value) async {
    if (value.isEmpty) throw Exception('empty value');
  }

  @override
  Future<int> select(String key, List<Uint8List> values) async {
    var best = 0;
    for (var i = 1; i < values.length; i++) {
      if (values[i][0] > values[best][0]) best = i;
    }
    return best;
  }
}

class _Author {
  final KeyPair keyPair;
  final PeerId id;
  _Author(this.keyPair, this.id);

  static Future<_Author> create() async {
    final kp = await generateEd25519KeyPair();
    return _Author(kp, PeerId.fromPublicKey(kp.publicKey));
  }

  Future<Record> sign(String key, List<int> value) => RecordSigner.createSignedRecord(
        key: key,
        value: Uint8List.fromList(value),
        privateKey: keyPair.privateKey,
        peerId: id,
      );
}

Message _put(String key, Record record) => Message(
      type: MessageType.putValue,
      key: Uint8List.fromList(key.codeUnits),
      record: record,
    );

Message _get(String key) => Message(
      type: MessageType.getValue,
      key: Uint8List.fromList(key.codeUnits),
    );

String _pkKey(PeerId id) => '/pk/${String.fromCharCodes(id.toBytes())}';

void main() {
  late PeerId sender;
  late _Author alice;
  late _Author mallory;

  setUp(() async {
    sender = await PeerId.random();
    alice = await _Author.create();
    mallory = await _Author.create();
  });

  Future<ProtocolManager> startManager({
    bool allowUnvalidatedRecords = false,
    Duration maxRecordAge = const Duration(hours: 36),
  }) async {
    final pm = ProtocolManager(MockHost(await PeerId.random()));
    pm.initialize(
      routing: MockRoutingManager(),
      providerStore: MockProviderStore(),
      metrics: MockMetricsManager(),
      config: DHTConfigV2(
        bootstrapPeers: const [],
        allowUnvalidatedRecords: allowUnvalidatedRecords,
        maxRecordAge: maxRecordAge,
      ),
      validator: NamespacedValidator()
        ..['pk'] = PublicKeyValidator()
        ..['test'] = HighestByteValidator(),
    );
    await pm.start();
    addTearDown(pm.close);
    return pm;
  }

  group('PUT_VALUE validation', () {
    test('refuses a key whose namespace has no validator', () async {
      final pm = await startManager();
      final record = await alice.sign('my-key', [1]);
      await expectLater(pm.handlePutValue(sender, _put('my-key', record)),
          throwsA(isA<DHTProtocolException>()));
      expect(await pm.getRecordFromDatastore('my-key'), isNull);
    });

    test('refuses a record whose key differs from the message key', () async {
      final pm = await startManager();
      final record = await alice.sign('/test/a', [1]);
      await expectLater(pm.handlePutValue(sender, _put('/test/b', record)),
          throwsA(isA<DHTProtocolException>()));
    });

    test('refuses a record that the namespace validator refuses', () async {
      final pm = await startManager();
      // Mallory signs a /pk/ record for Alice's key with Mallory's key.
      final key = _pkKey(alice.id);
      final forged = await mallory.sign(key, mallory.keyPair.publicKey.marshal());
      await expectLater(pm.handlePutValue(sender, _put(key, forged)),
          throwsA(isA<DHTProtocolException>()));
      expect(await pm.getRecordFromDatastore(key), isNull);
    });

    test('accepts an unsigned /pk/ record (go-libp2p sends no author or signature)', () async {
      final pm = await startManager();
      final key = _pkKey(alice.id);
      final record = Record(
        key: Uint8List.fromList(key.codeUnits),
        value: alice.keyPair.publicKey.marshal(),
        timeReceived: 0,
        author: Uint8List(0),
        signature: Uint8List(0),
      );
      await pm.handlePutValue(sender, _put(key, record));
      expect(await pm.getRecordFromDatastore(key), isNotNull);
    });

    test('select() decides which record is kept, not the timestamp', () async {
      final pm = await startManager();
      const key = '/test/x';
      final good = await alice.sign(key, [9]);
      await pm.handlePutValue(sender, _put(key, good));

      // A worse value with a later timestamp does not replace it.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final worse = await mallory.sign(key, [1]);
      expect(worse.timeReceived, greaterThan(good.timeReceived));
      await pm.handlePutValue(sender, _put(key, worse));
      expect((await pm.getRecordFromDatastore(key))!.value, [9]);

      // A better value replaces it.
      final better = await mallory.sign(key, [10]);
      await pm.handlePutValue(sender, _put(key, better));
      expect((await pm.getRecordFromDatastore(key))!.value, [10]);
    });

    test('a forged signature is refused', () async {
      final pm = await startManager();
      const key = '/test/x';
      final r = await alice.sign(key, [1]);
      final tampered = Record(
        key: r.key,
        value: Uint8List.fromList([200]),
        timeReceived: r.timeReceived,
        author: r.author,
        signature: r.signature,
      );
      await expectLater(pm.handlePutValue(sender, _put(key, tampered)),
          throwsA(isA<DHTProtocolException>()));
    });
  });

  group('allowUnvalidatedRecords', () {
    test('another author cannot overwrite a stored record', () async {
      final pm = await startManager(allowUnvalidatedRecords: true);
      final first = await alice.sign('my-key', [1]);
      await pm.handlePutValue(sender, _put('my-key', first));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      final hijack = await mallory.sign('my-key', [2]);
      await pm.handlePutValue(sender, _put('my-key', hijack));
      expect((await pm.getRecordFromDatastore('my-key'))!.value, [1]);
    });

    test('the same author replaces its record with a newer one only', () async {
      final pm = await startManager(allowUnvalidatedRecords: true);
      final older = await alice.sign('my-key', [1]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final newer = await alice.sign('my-key', [2]);

      await pm.handlePutValue(sender, _put('my-key', newer));
      await pm.handlePutValue(sender, _put('my-key', older));
      expect((await pm.getRecordFromDatastore('my-key'))!.value, [2]);
    });

    test('an unsigned record is refused', () async {
      final pm = await startManager(allowUnvalidatedRecords: true);
      final record = Record(
        key: Uint8List.fromList('my-key'.codeUnits),
        value: Uint8List.fromList([1]),
        timeReceived: DateTime.now().millisecondsSinceEpoch,
        author: Uint8List(0),
        signature: Uint8List(0),
      );
      await expectLater(pm.handlePutValue(sender, _put('my-key', record)),
          throwsA(isA<DHTProtocolException>()));
    });

    test('selectRecord prefers the most common author, then the newest record', () async {
      final pm = await startManager(allowUnvalidatedRecords: true);
      final a1 = await alice.sign('my-key', [1]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final m1 = await mallory.sign('my-key', [2]);
      final a2 = await alice.sign('my-key', [3]);
      expect(await pm.selectRecord('my-key', [m1, a1, a2]), 2);
      // A tie goes to the author of the first record.
      expect(await pm.selectRecord('my-key', [a1, m1]), 0);
    });
  });

  group('record expiry', () {
    test('records older than maxRecordAge are not served and are pruned', () async {
      final pm = await startManager(maxRecordAge: const Duration(milliseconds: 200));
      const key = '/test/x';
      await pm.handlePutValue(sender, _put(key, await alice.sign(key, [1])));
      expect((await pm.handleGetValue(sender, _get(key))).record, isNotNull);

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect((await pm.handleGetValue(sender, _get(key))).record, isNull);
      expect(await pm.getRecordFromDatastore(key), isNull);
      expect(await pm.getDatastoreSize(), 0);
    });

    test('pruneExpiredRecords removes expired records', () async {
      final pm = await startManager(maxRecordAge: const Duration(milliseconds: 100));
      await pm.handlePutValue(sender, _put('/test/a', await alice.sign('/test/a', [1])));
      await pm.handlePutValue(sender, _put('/test/b', await alice.sign('/test/b', [1])));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(pm.pruneExpiredRecords(), 2);
    });

    test('a replaced record gets a new expiry', () async {
      final pm = await startManager(maxRecordAge: const Duration(milliseconds: 300));
      const key = '/test/x';
      await pm.handlePutValue(sender, _put(key, await alice.sign(key, [1])));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await pm.handlePutValue(sender, _put(key, await alice.sign(key, [2])));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect((await pm.getRecordFromDatastore(key))?.value, [2]);
    });

    test('default maxRecordAge is 36 hours', () {
      expect(const DHTConfigV2().maxRecordAge, const Duration(hours: 36));
      expect(const DHTConfigV2().allowUnvalidatedRecords, isFalse);
    });
  });
}
