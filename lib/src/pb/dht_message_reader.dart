/// Reads varint-length-prefixed DHT messages from a stream, one at a time.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/network/stream.dart';

import 'dht_codec.dart';
import 'dht_message.dart';

/// The largest DHT message accepted, as `network.MessageSizeMax` in
/// go-libp2p (4 MiB).
const int dhtMaxMessageSize = 4 * 1024 * 1024;

/// Thrown when the bytes on a stream are not a valid DHT message frame.
class DhtFrameException implements Exception {
  final String message;
  DhtFrameException(this.message);

  @override
  String toString() => 'DhtFrameException: $message';
}

/// Reads complete DHT messages from a [P2PStream].
///
/// A stream read can return part of a message, or the end of one message
/// and the start of the next. The reader keeps the extra bytes for the
/// next call, so a peer can send several requests on one stream, as
/// go-libp2p-kad-dht does.
class DhtMessageReader {
  final P2PStream _stream;
  final int maxMessageSize;
  final List<int> _buffer = [];

  DhtMessageReader(this._stream, {this.maxMessageSize = dhtMaxMessageSize});

  /// Reads the next message.
  ///
  /// Returns null when the stream ends before the first byte of a message
  /// (the peer has no more requests). Throws a [TimeoutException] when no
  /// complete message arrives within [timeout], a [DhtFrameException] when
  /// the frame is not valid or the stream ends inside a message, and the
  /// stream's own error when a read fails.
  Future<Message?> next({Duration? timeout}) async {
    final deadline = timeout == null ? null : DateTime.now().add(timeout);
    while (true) {
      final frame = _takeFrame();
      if (frame != null) {
        try {
          return decodeMessageRaw(frame);
        } catch (e) {
          throw DhtFrameException('Message is not a valid DHT protobuf: $e');
        }
      }

      Future<Uint8List> read = _stream.read();
      if (deadline != null) {
        final left = deadline.difference(DateTime.now());
        if (left <= Duration.zero) {
          throw TimeoutException('No complete DHT message', timeout);
        }
        read = read.timeout(left);
      }
      final chunk = await read;
      if (chunk.isEmpty) {
        if (_buffer.isEmpty) return null;
        throw DhtFrameException('Stream ended inside a message');
      }
      _buffer.addAll(chunk);
    }
  }

  /// Removes and returns one complete frame payload from the buffer, or
  /// returns null when the buffer does not hold a complete frame yet.
  Uint8List? _takeFrame() {
    var length = 0;
    var shift = 0;
    var i = 0;
    while (true) {
      if (i >= _buffer.length) return null;
      if (i >= 9) throw DhtFrameException('Length prefix is too long');
      final b = _buffer[i++];
      length |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) break;
      shift += 7;
    }
    if (length > maxMessageSize) {
      throw DhtFrameException('Message of $length bytes is larger than $maxMessageSize');
    }
    if (_buffer.length - i < length) return null;
    final payload = Uint8List.fromList(_buffer.sublist(i, i + length));
    _buffer.removeRange(0, i + length);
    return payload;
  }
}
