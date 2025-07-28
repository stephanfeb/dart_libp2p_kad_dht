// Ported from go-libp2p-kad-dht/internal/net/message_manager.go

import 'dart:async';
import 'dart:typed_data';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peerstore.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:synchronized/synchronized.dart';

import '../metrics/metrics.dart';
import '../metrics/context.dart';

/// The timeout for reading a response message.
const Duration dhtReadMessageTimeout = Duration(seconds: 10);

/// Error thrown when no message is read within the timeout period.
class ReadTimeoutException implements Exception {
  final String message = 'timed out reading response';
  
  @override
  String toString() => message;
}

/// Logger for DHT operations.
final Logger logger = Logger('dart-libp2p-kad-dht');

/// Interface for a message that can be sent over the network.
abstract class Message {
  /// The type of the message.
  String get type;
  
  /// Converts the message to bytes.
  Future<Uint8List> marshal();
  
  /// Creates a message from bytes.
  static Future<Message> unmarshal(Uint8List data) {
    // This would be implemented by concrete message classes
    throw UnimplementedError('Message.unmarshal must be implemented by subclasses');
  }
}

/// Interface for a peer in the DHT.
abstract class Peer {
  /// The ID of the peer.
  String get id;
  
  /// The addresses of the peer.
  List<String> get addresses;
}

/// Interface for a network stream.
abstract class Stream {
  /// Writes data to the stream.
  Future<void> write(Uint8List data);
  
  /// Reads data from the stream.
  Future<Uint8List> read();
  
  /// Closes the stream gracefully.
  Future<void> close();
  
  /// Resets the stream, closing it immediately.
  Future<void> reset();
}

/// Interface for a host that can create streams to peers.
abstract class Host {
  /// Creates a new stream to a peer using the given protocols.
  Future<Stream> newStream(String peerId, List<String> protocols);
  
  /// Records the latency of a peer.
  void recordLatency(String peerId, Duration latency);
  
  /// Gets the peerstore for this host.
  Peerstore get peerstore;
}


/// Interface for a message sender that can send messages to peers.
abstract class MessageSender {
  /// Sends a request to a peer and waits for a response.
  Future<Message> sendRequest(String peerId, Message message);
  
  /// Sends a message to a peer without waiting for a response.
  Future<void> sendMessage(String peerId, Message message);
  
  /// Called when a peer disconnects.
  Future<void> onDisconnect(String peerId);
}

/// Implementation of a message sender that efficiently sends messages to peers.
class MessageSenderImpl implements MessageSender {
  final Host _host;
  final List<String> _protocols;
  final Map<String, PeerMessageSender> _senders = {};
  final Lock _mutex = Lock();
  
  /// Creates a new message sender with the given host and protocols.
  MessageSenderImpl(this._host, this._protocols);

  @visibleForTesting
  int get sendersMapSize => _senders.length;
  
  @override
  Future<void> onDisconnect(String peerId) async {
    await _mutex.synchronized(() async {
      final sender = _senders[peerId];
      if (sender == null) {
        return;
      }
      _senders.remove(peerId);
      
      // Do this asynchronously as sender.lock can block for a while
      unawaited(_invalidateSender(sender));
    });
  }
  
  Future<void> _invalidateSender(PeerMessageSender sender) async {
    await sender.lock.synchronized(() {
      sender.invalidate();
    });
  }
  
  @override
  Future<Message> sendRequest(String peerId, Message message) async {
    // Run with metrics attributes
    return runWithAttributes(() async {
      final sender = await _messageSenderForPeer(peerId);
      if (sender == null) {
        DhtMetrics.recordRequestSendErr();
        logger.warning('Request failed to open message sender to $peerId');
        throw Exception('Failed to open message sender');
      }
      
      final marshalled = await message.marshal();
      
      final start = DateTime.now();
      
      try {
        final response = await sender.sendRequest(message);
        
        final outboundLatency = DateTime.now().difference(start).inMilliseconds.toDouble();
        DhtMetrics.recordRequestSendOK(marshalled.length, outboundLatency);
        _host.peerstore.metrics.recordLatency(PeerId.fromString(peerId), DateTime.now().difference(start));
        
        return response;
      } catch (e) {
        DhtMetrics.recordRequestSendErr();
        logger.warning('Request failed to $peerId: $e');
        rethrow;
      }
    }, [DhtMetrics.upsertMessageType(message.type)]);
  }
  
  @override
  Future<void> sendMessage(String peerId, Message message) async {
    // Run with metrics attributes
    return runWithAttributes(() async {
      final sender = await _messageSenderForPeer(peerId);
      if (sender == null) {
        DhtMetrics.recordMessageSendErr();
        logger.warning('Message failed to open message sender to $peerId');
        throw Exception('Failed to open message sender');
      }
      
      final marshalled = await message.marshal();
      
      try {
        await sender.sendMessage(message);
        DhtMetrics.recordMessageSendOK(marshalled.length);
      } catch (e) {
        DhtMetrics.recordMessageSendErr();
        logger.warning('Message failed to $peerId: $e');
        rethrow;
      }
    }, [DhtMetrics.upsertMessageType(message.type)]);
  }
  
  Future<PeerMessageSender?> _messageSenderForPeer(String peerId) async {
    PeerMessageSender? pms; // PeerMessageSender instance

    // Step 1: Get or create the sender object, potentially adding it to the map.
    // This part needs to be under _mutex.
    await _mutex.synchronized(() {
      pms = _senders[peerId];
      if (pms == null) {
        pms = PeerMessageSender(
          peerId: peerId,
          messageSender: this,
          lock: Lock(), // Each PeerMessageSender has its own lock for its stream state
        );
        _senders[peerId] = pms!; // Use null assertion as pms is guaranteed non-null here
      }
      // Now pms is the sender instance, either old or newly created and added to the map.
    });

    // pms should be non-null here due to the logic above.
    // If, for some reason it were null (e.g., an error not caught above, though unlikely with current structure),
    // it would lead to a null check operator error on pms!.prepOrInvalidate().
    // However, the current logic ensures pms is assigned.

    // Step 2: Prepare the sender. This is done outside the _mutex lock.
    if (!await pms!.prepOrInvalidate()) {
      // Preparation failed. We need to remove it from the map,
      // but only if it's still the same one (i.e., not replaced by another concurrent operation).
      await _mutex.synchronized(() {
        // Check if the sender in the map is still the one that failed preparation.
        if (_senders[peerId] == pms) {
          _senders.remove(peerId);
        }
        // If it's not the same, then another operation might have already replaced it or removed it.
        // The 'pms' instance we have is now effectively orphaned and will be garbage collected.
        // The new sender in the map (if any) would have undergone its own preparation.
      });
      return null; // Preparation failed, so no sender is available.
    }

    // If we reach here, pms is prepped and valid.
    return pms;
  }
}

/// Responsible for sending messages to a specific peer.
class PeerMessageSender {
  final String peerId;
  final MessageSenderImpl messageSender;
  final Lock lock;
  
  Stream? stream;
  bool invalid = false;
  int singleMes = 0;
  
  /// Creates a new peer message sender.
  PeerMessageSender({
    required this.peerId,
    required this.messageSender,
    required this.lock,
  });
  
  /// Invalidates this sender, preventing it from being reused.
  void invalidate() {
    invalid = true;
    if (stream != null) {
      unawaited(stream!.reset());
      stream = null;
    }
  }
  
  /// Prepares the sender for use or invalidates it if preparation fails.
  Future<bool> prepOrInvalidate() async {
    return await lock.synchronized(() async {
      if (!await prep()) {
        invalidate();
        return false;
      }
      return true;
    });
  }
  
  /// Prepares the sender for use.
  Future<bool> prep() async {
    if (invalid) {
      return false;
    }
    
    if (stream != null) {
      return true;
    }
    
    try {
      // Create a new stream to the peer
      final newStream = await messageSender._host.newStream(peerId, messageSender._protocols);
      stream = newStream;
      return true;
    } catch (e) {
      logger.warning('Failed to create stream to $peerId: $e');
      return false;
    }
  }
  
  /// The maximum number of times to try reusing a stream before giving up.
  static const int streamReuseTries = 3;
  
  /// Sends a message to the peer without waiting for a response.
  Future<void> sendMessage(Message message) async {
    return await lock.synchronized(() async {
      bool retry = false;
      
      while (true) {
        if (!await prep()) { // prep is called within the lock
          throw Exception('Failed to prepare stream');
        }
        
        try {
          await _writeMsg(message);
          
          if (singleMes > streamReuseTries) {
            await stream?.close();
            stream = null;
          } else if (retry) {
            singleMes++;
          }
          
          return;
        } catch (e) {
          await stream?.reset();
          stream = null;
          
          if (retry) {
            logger.warning('Error writing message: $e');
            rethrow;
          }
          
          logger.info('Error writing message, retrying: $e');
          retry = true;
        }
      }
    });
  }
  
  /// Sends a request to the peer and waits for a response.
  Future<Message> sendRequest(Message message) async {
    return await lock.synchronized(() async {
      bool retry = false;
      
      while (true) {
        if (!await prep()) { // prep is called within the lock
          throw Exception('Failed to prepare stream');
        }
        
        try {
          await _writeMsg(message);
          
          final response = await _readMsg();
          
          if (singleMes > streamReuseTries) {
            await stream?.close();
            stream = null;
          } else if (retry) {
            singleMes++;
          }
          
          return response;
        } catch (e) {
          await stream?.reset();
          stream = null;
          
          if (e is TimeoutException) {
            throw ReadTimeoutException();
          }
          
          if (retry) {
            logger.warning('Error reading/writing message: $e');
            rethrow;
          }
          
          logger.info('Error reading/writing message, retrying: $e');
          retry = true;
        }
      }
    });
  }
  
  /// Writes a message to the stream.
  Future<void> _writeMsg(Message message) async {
    final data = await message.marshal();
    await stream?.write(data);
  }
  
  /// Reads a message from the stream with timeout.
  Future<Message> _readMsg() async {
    final completer = Completer<Message>();
    
    // Start reading in a separate isolate/thread
    unawaited(() async {
      try {
        final data = await stream?.read();
        if (data != null) {
          final message = await Message.unmarshal(data);
          if (!completer.isCompleted) {
            completer.complete(message);
          }
        } else {
          if (!completer.isCompleted) {
            completer.completeError(Exception('Failed to read message'));
          }
        }
      } catch (e) {
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      }
    }());
    
    // Wait with timeout
    return completer.future.timeout(dhtReadMessageTimeout);
  }
}

/// Marks a future as unawaited to avoid lint warnings.
void unawaited(Future<void> future) {
  // Intentionally not awaiting the future
}
