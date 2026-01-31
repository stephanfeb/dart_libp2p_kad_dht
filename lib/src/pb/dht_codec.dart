/// Codec for encoding/decoding DHT messages using protobuf wire format
/// with varint-length framing (compatible with go-libp2p-kad-dht).
library;

import 'dart:typed_data';

import 'package:dart_libp2p/p2p/multiaddr/codec.dart' show MultiAddrCodec;

import 'dht.pb.dart' as pb;
import 'dht.pbenum.dart' as pb_enum;
import 'record.pb.dart' as pb_rec;
import 'dht_message.dart';
import 'record.dart' as custom;

/// Encode a custom Message to varint-length-prefixed protobuf bytes.
Uint8List encodeMessage(Message msg) {
  final payload = _toProto(msg).writeToBuffer();
  final lenBytes = MultiAddrCodec.encodeVarint(payload.length);
  final result = Uint8List(lenBytes.length + payload.length);
  result.setRange(0, lenBytes.length, lenBytes);
  result.setRange(lenBytes.length, result.length, payload);
  return result;
}

/// Decode varint-length-prefixed protobuf bytes to a custom Message.
Message decodeMessage(Uint8List bytes) {
  final (length, consumed) = MultiAddrCodec.decodeVarint(bytes);
  final pbMsg = pb.Message.fromBuffer(bytes.sublist(consumed, consumed + length));
  return _fromProto(pbMsg);
}

/// Encode without length prefix.
Uint8List encodeMessageRaw(Message msg) {
  return Uint8List.fromList(_toProto(msg).writeToBuffer());
}

/// Decode without length prefix.
Message decodeMessageRaw(Uint8List bytes) {
  return _fromProto(pb.Message.fromBuffer(bytes));
}

// --- Private conversion helpers ---

pb.Message _toProto(Message msg) {
  final pbMsg = pb.Message()
    ..type = pb_enum.Message_MessageType.valueOf(msg.type.value)!
    ..clusterLevelRaw = msg.clusterLevelRaw;
  if (msg.key != null) pbMsg.key = msg.key!;
  if (msg.record != null) pbMsg.record = _recordToProto(msg.record!);
  pbMsg.closerPeers.addAll(msg.closerPeers.map(_peerToProto));
  pbMsg.providerPeers.addAll(msg.providerPeers.map(_peerToProto));
  return pbMsg;
}

Message _fromProto(pb.Message pbMsg) {
  return Message(
    type: MessageType.fromValue(pbMsg.type.value),
    clusterLevelRaw: pbMsg.clusterLevelRaw,
    key: pbMsg.hasKey() ? Uint8List.fromList(pbMsg.key) : null,
    record: pbMsg.hasRecord() ? _recordFromProto(pbMsg.record) : null,
    closerPeers: pbMsg.closerPeers.map(_peerFromProto).toList(),
    providerPeers: pbMsg.providerPeers.map(_peerFromProto).toList(),
  );
}

pb_rec.Record _recordToProto(custom.Record rec) {
  return pb_rec.Record()
    ..key = rec.key
    ..value = rec.value
    ..timeReceived = rec.timeReceived.toString();
  // author and signature are local-only fields, not part of the wire format.
}

custom.Record _recordFromProto(pb_rec.Record pbRec) {
  return custom.Record(
    key: Uint8List.fromList(pbRec.key),
    value: Uint8List.fromList(pbRec.value),
    timeReceived: int.tryParse(pbRec.timeReceived) ?? 0,
    author: Uint8List(0),
    signature: Uint8List(0),
  );
}

pb.Message_Peer _peerToProto(Peer peer) {
  final pbPeer = pb.Message_Peer()
    ..id = peer.id
    ..connection =
        pb_enum.Message_ConnectionType.valueOf(peer.connection.value)!;
  pbPeer.addrs.addAll(peer.addrs);
  return pbPeer;
}

Peer _peerFromProto(pb.Message_Peer pbPeer) {
  return Peer(
    id: Uint8List.fromList(pbPeer.id),
    addrs: pbPeer.addrs.map((a) => Uint8List.fromList(a)).toList(),
    connection: ConnectionType.fromValue(pbPeer.connection.value),
  );
}