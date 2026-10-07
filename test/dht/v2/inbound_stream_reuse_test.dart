import 'dart:typed_data';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_mgr;
import 'package:dart_libp2p_kad_dht/src/amino/defaults.dart';
import 'package:dart_libp2p_kad_dht/src/dht/dht_options.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/dht_v2.dart';
import 'package:dart_libp2p_kad_dht/src/pb/dht_codec.dart';
import 'package:dart_libp2p_kad_dht/src/pb/dht_message.dart';
import 'package:dart_libp2p_kad_dht/src/pb/dht_message_reader.dart';
import 'package:dart_libp2p_kad_dht/src/pb/record.dart';
import 'package:dart_libp2p_kad_dht/src/providers/provider_store.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:test/test.dart';

import 'real_net_stack.dart';

/// The go-libp2p-kad-dht client sends several requests on one stream. These
/// tests do the same against an IpfsDHTv2 server.
void main() {
  group('DHT v2 server: several requests on one inbound stream', () {
    final hosts = <Host>[];
    IpfsDHTv2? server;

    tearDown(() async {
      await server?.close().timeout(const Duration(seconds: 5)).catchError((_) {});
      server = null;
      for (final host in hosts) {
        await host.close().timeout(const Duration(seconds: 5)).catchError((_) {});
      }
      hosts.clear();
    });

    Future<Host> newHost() async {
      final details = await createLibp2pNode(
        udxInstance: UDX(),
        resourceManager: NullResourceManager(),
        connManager: p2p_conn_mgr.ConnectionManager(),
        hostEventBus: p2p_event_bus.BasicBus(),
        userAgentPrefix: 'dht-stream-reuse-test',
      );
      hosts.add(details.host);
      return details.host;
    }

    Future<(Host, Host)> serverAndClient() async {
      final serverHost = await newHost();
      server = IpfsDHTv2(
        host: serverHost,
        providerStore: MemoryProviderStore(),
        options: const DHTOptions(mode: DHTMode.server, autoRefresh: false),
      );
      await server!.start();
      final client = await newHost();
      await client.connect(AddrInfo(serverHost.id, serverHost.addrs));
      return (serverHost, client);
    }

    String pkKey(Host host) => '/pk/${String.fromCharCodes(host.id.toBytes())}';

    test('FIND_NODE then PUT_VALUE on the same stream are both answered', () async {
      final (serverHost, client) = await serverAndClient();
      final stream = await client.newStream(serverHost.id, [AminoConstants.protocolID], Context());
      final reader = DhtMessageReader(stream);

      // Request 1: FIND_NODE
      await stream.write(encodeMessage(Message(
        type: MessageType.findNode,
        key: Uint8List.fromList(client.id.toBytes()),
      )));
      final r1 = await reader.next(timeout: const Duration(seconds: 10));
      expect(r1, isNotNull);
      expect(r1!.type, MessageType.findNode);

      // Request 2 on the same stream: PUT_VALUE of the client's /pk/ record
      final key = pkKey(client);
      final pubKey = (await client.peerStore.keyBook.pubKey(client.id))!.marshal();
      final record = Record(
        key: Uint8List.fromList(key.codeUnits),
        value: pubKey,
        timeReceived: DateTime.now().millisecondsSinceEpoch,
        author: Uint8List(0),
        signature: Uint8List(0),
      );
      await stream.write(encodeMessage(Message(
        type: MessageType.putValue,
        key: Uint8List.fromList(key.codeUnits),
        record: record,
      )));
      final r2 = await reader.next(timeout: const Duration(seconds: 10));
      expect(r2, isNotNull, reason: 'the second request must be answered');
      expect(r2!.type, MessageType.putValue);
      expect(r2.record?.value, equals(pubKey),
          reason: 'PUT_VALUE echoes the record, as go-libp2p-kad-dht checks');

      final stored = await server!.getRecordFromDatastore(key);
      expect(stored?.value, equals(pubKey));

      // Request 3: PING, then the client ends its side; the server closes.
      await stream.write(encodeMessage(Message(type: MessageType.ping)));
      final r3 = await reader.next(timeout: const Duration(seconds: 10));
      expect(r3!.type, MessageType.ping);
      await stream.closeWrite();
      expect(await reader.next(timeout: const Duration(seconds: 10)), isNull,
          reason: 'the server closes the stream after the client ends it');
      await stream.close();
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a message that is not valid ends the stream; new streams still work', () async {
      final (serverHost, client) = await serverAndClient();

      final bad = await client.newStream(serverHost.id, [AminoConstants.protocolID], Context());
      await bad.write(Uint8List.fromList([5, 0xff, 0xff, 0xff, 0xff, 0xff]));
      final reader = DhtMessageReader(bad);
      Object? outcome;
      try {
        outcome = await reader.next(timeout: const Duration(seconds: 10));
      } catch (e) {
        outcome = e;
      }
      expect(outcome is Message, isFalse, reason: 'no answer to a message that is not valid');
      try {
        await bad.close();
      } catch (_) {}

      // The server keeps serving: one request per stream, as the Dart
      // client sends them.
      final good = await client.newStream(serverHost.id, [AminoConstants.protocolID], Context());
      await good.write(encodeMessage(Message(type: MessageType.ping)));
      final r = await DhtMessageReader(good).next(timeout: const Duration(seconds: 10));
      expect(r?.type, MessageType.ping);
      await good.close();
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
