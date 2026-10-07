import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/routing/options.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_mgr;
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/errors/dht_errors.dart';
import 'package:dart_libp2p_kad_dht/src/record/namespace_validator.dart';
import 'package:dart_libp2p_kad_dht/src/record/record_signer.dart';
import 'package:dart_libp2p_kad_dht/src/record/validator.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:test/test.dart';

import '../real_net_stack.dart';

/// Test namespace: the value with the highest first byte is best; a value
/// whose first byte is 0 is refused when [refuseZero] is set.
class HighestByteValidator implements Validator {
  final bool refuseZero;
  HighestByteValidator({this.refuseZero = false});

  @override
  Future<void> validate(String key, Uint8List value) async {
    if (value.isEmpty) throw Exception('empty value');
    if (refuseZero && value[0] == 0) throw Exception('zero value');
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

/// The legacy IpfsDHT applies the same value record rules as IpfsDHTv2.
void main() {
  group('IpfsDHT (v1) value records', () {
    final hosts = <Host>[];
    final dhts = <IpfsDHT>[];

    tearDown(() async {
      for (final dht in dhts) {
        await dht.close().timeout(const Duration(seconds: 5)).catchError((_) {});
      }
      for (final host in hosts) {
        await host.close().timeout(const Duration(seconds: 5)).catchError((_) {});
      }
      hosts.clear();
      dhts.clear();
    });

    Future<IpfsDHT> node({
      NamespacedValidator? validator,
      Duration? maxRecordAge,
      bool allowUnvalidatedRecords = false,
    }) async {
      final details = await createLibp2pNode(
        udxInstance: UDX(),
        resourceManager: NullResourceManager(),
        connManager: p2p_conn_mgr.ConnectionManager(),
        hostEventBus: p2p_event_bus.BasicBus(),
      );
      hosts.add(details.host);
      final dht = IpfsDHT(
        host: details.host,
        providerStore: MemoryProviderStore(),
        validator: validator ?? (NamespacedValidator()..['test'] = HighestByteValidator()),
        options: DHTOptions(
          mode: DHTMode.server,
          maxRecordAge: maxRecordAge ?? AminoConstants.defaultMaxRecordAge,
          allowUnvalidatedRecords: allowUnvalidatedRecords,
        ),
      );
      dhts.add(dht);
      await dht.start();
      return dht;
    }

    Uint8List bytesOf(String key) => Uint8List.fromList(key.codeUnits);

    Record unsigned(String key, List<int> value) => Record(
          key: bytesOf(key),
          value: Uint8List.fromList(value),
          timeReceived: DateTime.now().millisecondsSinceEpoch,
          author: Uint8List(0),
          signature: Uint8List(0),
        );

    Future<Record> signedBy(IpfsDHT dht, String key, List<int> value) async {
      final host = dht.host();
      return RecordSigner.createSignedRecord(
        key: key,
        value: Uint8List.fromList(value),
        privateKey: (await host.peerStore.keyBook.privKey(host.id))!,
        peerId: host.id,
      );
    }

    Message putMessage(String key, Record record) =>
        Message(type: MessageType.putValue, key: bytesOf(key), record: record);

    String pkKey(Host host) => '/pk/${String.fromCharCodes(host.id.toBytes())}';

    test('PUT_VALUE stores a valid unsigned /pk/ record and echoes it', () async {
      final dht = await node();
      final sender = await node();
      final key = pkKey(sender.host());
      final pubKey = (await sender.host().peerStore.keyBook.pubKey(sender.host().id))!.marshal();

      final response = await dht.handlers
          .handlePutValue(sender.host().id, putMessage(key, unsigned(key, pubKey)));
      expect(response.type, MessageType.putValue);
      expect(response.record?.value, equals(pubKey), reason: 'the answer echoes the record');
      expect((await dht.checkLocalDatastore(bytesOf(key)))?.value, equals(pubKey));
    });

    test('PUT_VALUE refuses a record that its namespace validator refuses', () async {
      final dht = await node();
      final sender = await node();
      // A /pk/ record whose value is not the key's public key.
      final key = pkKey(sender.host());
      await expectLater(
        dht.handlers.handlePutValue(sender.host().id, putMessage(key, unsigned(key, [1, 2, 3]))),
        throwsArgumentError,
      );
      expect(await dht.checkLocalDatastore(bytesOf(key)), isNull);
    });

    test('PUT_VALUE refuses a key without a namespace validator', () async {
      final dht = await node();
      final sender = await node();
      final record = await signedBy(sender, 'my-key', utf8.encode('my-value'));
      await expectLater(
        dht.handlers.handlePutValue(sender.host().id, putMessage('my-key', record)),
        throwsArgumentError,
      );
      expect(await dht.checkLocalDatastore(bytesOf('my-key')), isNull);
    });

    test('PUT_VALUE refuses a record for another key', () async {
      final dht = await node();
      final sender = await node();
      await expectLater(
        dht.handlers.handlePutValue(
            sender.host().id,
            Message(type: MessageType.putValue, key: bytesOf('/test/a'), record: unsigned('/test/b', [1]))),
        throwsArgumentError,
      );
    });

    test('the validator select() decides, not the timestamp', () async {
      final dht = await node();
      final sender = await node();
      const key = '/test/x';
      await dht.handlers.handlePutValue(sender.host().id, putMessage(key, unsigned(key, [7])));
      // A newer but worse record does not replace the stored one.
      final worse = unsigned(key, [3]);
      await dht.handlers.handlePutValue(sender.host().id, putMessage(key, worse));
      expect((await dht.checkLocalDatastore(bytesOf(key)))!.value, equals([7]));
      // A better one does.
      await dht.handlers.handlePutValue(sender.host().id, putMessage(key, unsigned(key, [9])));
      expect((await dht.checkLocalDatastore(bytesOf(key)))!.value, equals([9]));
    });

    test('records expire after maxRecordAge', () async {
      final dht = await node(maxRecordAge: const Duration(milliseconds: 200));
      final sender = await node();
      const key = '/test/expiring';
      await dht.handlers.handlePutValue(sender.host().id, putMessage(key, unsigned(key, [1])));
      expect(await dht.checkLocalDatastore(bytesOf(key)), isNotNull);
      await Future.delayed(const Duration(milliseconds: 400));
      expect(await dht.checkLocalDatastore(bytesOf(key)), isNull);
    });

    test('putValue refuses a key without a namespace validator by default', () async {
      final dht = await node();
      await expectLater(
        dht.putValue('my-key', Uint8List.fromList(utf8.encode('my-value'))),
        throwsA(isA<DHTProtocolException>()),
      );
      expect(await dht.getValue('my-key', RoutingOptions()..offline = true), isNull);
    });

    test('allowUnvalidatedRecords: signed records only, and only their author replaces them', () async {
      final dht = await node(allowUnvalidatedRecords: true);
      final a = await node();
      final b = await node();

      await dht.putValue('my-key', Uint8List.fromList([1]), options: RoutingOptions()..offline = true);
      expect(await dht.getValue('my-key', RoutingOptions()..offline = true), equals([1]));

      // Unsigned: refused.
      await expectLater(
        dht.handlers.handlePutValue(a.host().id, putMessage('other', unsigned('other', [1]))),
        throwsArgumentError,
      );
      // Signed by a: stored. A newer record of b does not replace it.
      await dht.putRecordToDatastore(await signedBy(a, 'other', [1]));
      await dht.putRecordToDatastore(await signedBy(b, 'other', [2]));
      expect((await dht.checkLocalDatastore(bytesOf('other')))!.value, equals([1]));
    });

    test('getValue ignores records that fail validation and selects the best', () async {
      // The server accepts any value; the client refuses the value 0.
      final server = await node(
          validator: NamespacedValidator()..['test'] = HighestByteValidator());
      final client = await node(
          validator: NamespacedValidator()..['test'] = HighestByteValidator(refuseZero: true));
      await client.host().connect(AddrInfo(server.host().id, server.host().addrs));
      await client.routingTable.tryAddPeer(server.host().id, queryPeer: false);

      await server.putRecordToDatastore(await signedBy(server, '/test/bad', [0]));
      expect(await client.getValue('/test/bad', RoutingOptions()), isNull,
          reason: 'a record that the validator refuses is ignored');

      await server.putRecordToDatastore(await signedBy(server, '/test/good', [8]));
      await client.putRecordToDatastore(await signedBy(client, '/test/good', [2]));
      expect(await client.getValue('/test/good', RoutingOptions()), equals([8]),
          reason: 'the network record is better than the local one');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
