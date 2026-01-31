import 'dart:typed_data';

import 'package:dart_libp2p_kad_dht/src/pb/dht_codec.dart';
import 'package:dart_libp2p_kad_dht/src/pb/dht_message.dart';
import 'package:dart_libp2p_kad_dht/src/pb/record.dart';
import 'package:test/test.dart';

void main() {
  group('DHT Protobuf Codec', () {
    test('round-trip: FIND_NODE message with key', () {
      final msg = Message(
        type: MessageType.findNode,
        key: Uint8List.fromList([1, 2, 3, 4, 5]),
      );

      final encoded = encodeMessage(msg);
      final decoded = decodeMessage(encoded);

      expect(decoded.type, MessageType.findNode);
      expect(decoded.key, orderedEquals(msg.key!));
      expect(decoded.record, isNull);
      expect(decoded.closerPeers, isEmpty);
      expect(decoded.providerPeers, isEmpty);
    });

    test('round-trip: GET_VALUE response with record', () {
      final record = Record(
        key: Uint8List.fromList('/test/key'.codeUnits),
        value: Uint8List.fromList('hello-world'.codeUnits),
        timeReceived: 1234567890,
        author: Uint8List.fromList([10, 20, 30]),
        signature: Uint8List.fromList([40, 50, 60]),
      );

      final msg = Message(
        type: MessageType.getValue,
        key: Uint8List.fromList('/test/key'.codeUnits),
        record: record,
      );

      final encoded = encodeMessage(msg);
      final decoded = decodeMessage(encoded);

      expect(decoded.type, MessageType.getValue);
      expect(decoded.record, isNotNull);
      expect(decoded.record!.key, orderedEquals(record.key));
      expect(decoded.record!.value, orderedEquals(record.value));
      expect(decoded.record!.timeReceived, record.timeReceived);
      // author and signature are NOT on the wire
      expect(decoded.record!.author, isEmpty);
      expect(decoded.record!.signature, isEmpty);
    });

    test('round-trip: message with closerPeers', () {
      final msg = Message(
        type: MessageType.findNode,
        key: Uint8List.fromList([1, 2, 3]),
        closerPeers: [
          Peer(
            id: Uint8List.fromList([10, 20, 30]),
            addrs: [
              Uint8List.fromList([4, 127, 0, 0, 1, 6, 0, 80]),
            ],
            connection: ConnectionType.connected,
          ),
          Peer(
            id: Uint8List.fromList([40, 50, 60]),
            addrs: [],
            connection: ConnectionType.notConnected,
          ),
        ],
      );

      final encoded = encodeMessage(msg);
      final decoded = decodeMessage(encoded);

      expect(decoded.closerPeers.length, 2);
      expect(decoded.closerPeers[0].id, orderedEquals([10, 20, 30]));
      expect(decoded.closerPeers[0].addrs.length, 1);
      expect(decoded.closerPeers[0].connection, ConnectionType.connected);
      expect(decoded.closerPeers[1].id, orderedEquals([40, 50, 60]));
      expect(decoded.closerPeers[1].addrs, isEmpty);
    });

    test('round-trip: all MessageType values', () {
      for (final type in MessageType.values) {
        final msg = Message(type: type);
        final encoded = encodeMessage(msg);
        final decoded = decodeMessage(encoded);
        expect(decoded.type, type, reason: 'Failed for $type');
      }
    });

    test('round-trip: empty message', () {
      final msg = Message(type: MessageType.ping);
      final encoded = encodeMessage(msg);
      final decoded = decodeMessage(encoded);

      expect(decoded.type, MessageType.ping);
      expect(decoded.key, isNull);
      expect(decoded.record, isNull);
      expect(decoded.closerPeers, isEmpty);
      expect(decoded.providerPeers, isEmpty);
    });

    test('varint framing: length prefix matches payload', () {
      final msg = Message(
        type: MessageType.findNode,
        key: Uint8List.fromList(List.generate(100, (i) => i)),
      );

      final encoded = encodeMessage(msg);
      final raw = encodeMessageRaw(msg);

      // encoded should be varint(raw.length) + raw
      expect(encoded.length, greaterThan(raw.length));
      // First byte(s) should be the varint length
      // For small messages (<128 bytes), varint is 1 byte
      if (raw.length < 128) {
        expect(encoded[0], raw.length);
        expect(encoded.sublist(1), orderedEquals(raw));
      }
    });

    test('raw encode/decode without framing', () {
      final msg = Message(
        type: MessageType.putValue,
        key: Uint8List.fromList('/test/key'.codeUnits),
        record: Record(
          key: Uint8List.fromList('/test/key'.codeUnits),
          value: Uint8List.fromList('value'.codeUnits),
          timeReceived: 0,
          author: Uint8List(0),
          signature: Uint8List(0),
        ),
      );

      final raw = encodeMessageRaw(msg);
      final decoded = decodeMessageRaw(raw);

      expect(decoded.type, MessageType.putValue);
      expect(decoded.record, isNotNull);
      expect(decoded.record!.value, orderedEquals('value'.codeUnits));
    });
  });
}
