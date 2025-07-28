import 'dart:typed_data';

import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:test/test.dart';

void main() {
  group('Record', () {
    test('Record can be created and serialized', () {
      final key = Uint8List.fromList([1, 2, 3]);
      final value = Uint8List.fromList([4, 5, 6]);
      final author = Uint8List.fromList([7, 8, 9]);
      final signature = Uint8List.fromList([10, 11, 12]);

      final record = Record(
        key: key,
        value: value,
        timeReceived: 123456789,
        author: author,
        signature: signature,
      );

      expect(record.key, equals(key));
      expect(record.value, equals(value));
      expect(record.timeReceived, equals(123456789));
      expect(record.author, equals(author));
      expect(record.signature, equals(signature));

      final json = record.toJson();
      final recordFromJson = Record.fromJson(json);

      expect(recordFromJson, equals(record));
    });
  });

  group('DHT Message', () {
    test('MessageType enum has correct values', () {
      expect(MessageType.putValue.value, equals(0));
      expect(MessageType.getValue.value, equals(1));
      expect(MessageType.addProvider.value, equals(2));
      expect(MessageType.getProviders.value, equals(3));
      expect(MessageType.findNode.value, equals(4));
      expect(MessageType.ping.value, equals(5));

      expect(MessageType.fromValue(0), equals(MessageType.putValue));
      expect(MessageType.fromValue(1), equals(MessageType.getValue));
      expect(MessageType.fromValue(2), equals(MessageType.addProvider));
      expect(MessageType.fromValue(3), equals(MessageType.getProviders));
      expect(MessageType.fromValue(4), equals(MessageType.findNode));
      expect(MessageType.fromValue(5), equals(MessageType.ping));
    });

    test('ConnectionType enum has correct values', () {
      expect(ConnectionType.notConnected.value, equals(0));
      expect(ConnectionType.connected.value, equals(1));
      expect(ConnectionType.canConnect.value, equals(2));
      expect(ConnectionType.cannotConnect.value, equals(3));

      expect(ConnectionType.fromValue(0), equals(ConnectionType.notConnected));
      expect(ConnectionType.fromValue(1), equals(ConnectionType.connected));
      expect(ConnectionType.fromValue(2), equals(ConnectionType.canConnect));
      expect(ConnectionType.fromValue(3), equals(ConnectionType.cannotConnect));
    });

    test('Peer can be created and serialized', () {
      final id = Uint8List.fromList([1, 2, 3]);
      final addr1 = Uint8List.fromList([4, 5, 6]);
      final addr2 = Uint8List.fromList([7, 8, 9]);

      final peer = Peer(
        id: id,
        addrs: [addr1, addr2],
        connection: ConnectionType.connected,
      );

      expect(peer.id, equals(id));
      expect(peer.addrs, equals([addr1, addr2]));
      expect(peer.connection, equals(ConnectionType.connected));

      final json = peer.toJson();
      final peerFromJson = Peer.fromJson(json);

      expect(peerFromJson, equals(peer));
    });

    test('Message can be created and serialized', () {
      final key = Uint8List.fromList([1, 2, 3]);
      final record = Record(
        key: Uint8List.fromList([4, 5, 6]),
        value: Uint8List.fromList([7, 8, 9]),
        timeReceived: 123456789,
        author: Uint8List.fromList([10, 11, 12]),
        signature: Uint8List.fromList([13, 14, 15]),
      );

      final peer1 = Peer(
        id: Uint8List.fromList([16, 17, 18]),
        addrs: [Uint8List.fromList([19, 20, 21])],
      );

      final peer2 = Peer(
        id: Uint8List.fromList([22, 23, 24]),
        addrs: [Uint8List.fromList([25, 26, 27])],
        connection: ConnectionType.connected,
      );

      final message = Message(
        type: MessageType.getValue,
        key: key,
        record: record,
        closerPeers: [peer1],
        providerPeers: [peer2],
      );

      expect(message.type, equals(MessageType.getValue));
      expect(message.key, equals(key));
      expect(message.record, equals(record));
      expect(message.closerPeers, equals([peer1]));
      expect(message.providerPeers, equals([peer2]));

      final json = message.toJson();
      final messageFromJson = Message.fromJson(json);

      expect(messageFromJson, equals(message));
    });
  });
}