import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/routing/options.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_mgr;
import 'package:dart_libp2p_kad_dht/src/dht/dht_options.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/dht_v2.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/errors/dht_errors.dart';
import 'package:dart_libp2p_kad_dht/src/providers/provider_store.dart';
import 'package:dart_libp2p_kad_dht/src/record/namespace_validator.dart';
import 'package:dart_libp2p_kad_dht/src/record/record_signer.dart';
import 'package:dart_libp2p_kad_dht/src/record/validator.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:test/test.dart';

import 'real_net_stack.dart';

/// Test namespace: the value with the highest first byte is best.
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

void main() {
  group('DHT v2 value records over the network', () {
    final hosts = <Host>[];
    final dhts = <IpfsDHTv2>[];

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

    Future<IpfsDHTv2> node(List<MultiAddr> bootstrapPeers) async {
      final details = await createLibp2pNode(
        udxInstance: UDX(),
        resourceManager: NullResourceManager(),
        connManager: p2p_conn_mgr.ConnectionManager(),
        hostEventBus: p2p_event_bus.BasicBus(),
        userAgentPrefix: 'dht-value-records-test',
      );
      hosts.add(details.host);
      final dht = IpfsDHTv2(
        host: details.host,
        providerStore: MemoryProviderStore(),
        validator: NamespacedValidator()..['test'] = HighestByteValidator(),
        options: DHTOptions(
          mode: DHTMode.server,
          bootstrapPeers: bootstrapPeers,
          autoRefresh: false,
          resiliency: 3,
        ),
      );
      dhts.add(dht);
      await dht.start();
      return dht;
    }

    MultiAddr addrOf(Host host) {
      final udx = host.addrs.firstWhere((a) => a.hasProtocol('udx'));
      return MultiAddr('$udx/p2p/${host.id.toBase58()}');
    }

    Future<void> storeLocally(IpfsDHTv2 dht, String key, List<int> value) async {
      final host = dht.host();
      final record = await RecordSigner.createSignedRecord(
        key: key,
        value: Uint8List.fromList(value),
        privateKey: (await host.peerStore.keyBook.privKey(host.id))!,
        peerId: host.id,
      );
      await dht.putRecordToDatastore(record);
    }

    test('getValue asks the network and selects over local and remote records', () async {
      final server = await node([]);
      final client = await node([addrOf(hosts[0])]);
      await client.bootstrap();

      const key = '/test/greeting';
      await storeLocally(client, key, [1]); // local copy, worse
      await storeLocally(server, key, [7]); // remote copy, better

      final value = await client.getValue(key);
      expect(value, equals([7]),
          reason: 'getValue must not return the local copy alone');

      // Offline reads use the local datastore only.
      expect(await client.getValue(key, RoutingOptions()..offline = true), equals([1]));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('putValue stores on the server, which validates the record', () async {
      final server = await node([]);
      final client = await node([addrOf(hosts[0])]);
      await client.bootstrap();

      const key = '/test/put';
      await client.putValue(key, Uint8List.fromList([5]));
      final stored = await server.getRecordFromDatastore(key);
      expect(stored, isNotNull);
      expect(stored.value, equals([5]));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('putValue refuses a key without a namespace validator by default', () async {
      final dht = await node([]);
      await expectLater(
        dht.putValue('my-key', Uint8List.fromList(utf8.encode('my-value'))),
        throwsA(isA<DHTProtocolException>()),
      );
      expect(await dht.getValue('my-key'), isNull);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
