import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:logging/logging.dart';

import '../../../pb/dht_message.dart';
import '../../../amino/defaults.dart';
import '../config/dht_config.dart';
import '../errors/dht_errors.dart';
import 'metrics_manager.dart';

/// Manages network operations for DHT v2
/// 
/// This component handles:
/// - Message sending and receiving
/// - Connection management
/// - Network error handling
/// - Retry logic
/// - Timeout management
class NetworkManager {
  static final Logger _logger = Logger('NetworkManager');
  
  final Host _host;
  
  // Configuration
  DHTConfigV2? _config;
  MetricsManager? _metrics;
  
  // State
  bool _started = false;
  bool _closed = false;
  
  NetworkManager(this._host);
  
  /// Initializes the network manager
  void initialize({
    required DHTConfigV2 config,
    required MetricsManager metrics,
  }) {
    _config = config;
    _metrics = metrics;
  }
  
  /// Starts the network manager
  Future<void> start() async {
    if (_started || _closed) return;
    
    _logger.info('Starting NetworkManager...');
    _started = true;
    _logger.info('NetworkManager started');
  }
  
  /// Stops the network manager
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    
    _logger.info('Closing NetworkManager...');
    _logger.info('NetworkManager closed');
  }
  
  /// Sends a message to a peer with retry logic and error handling
  /// 
  /// This method provides consistent error handling and retry logic
  /// across all DHT operations, fixing the inconsistencies in the
  /// original implementation.
  Future<Message> sendMessage(PeerId peer, Message message) async {
    _ensureStarted();
    
    final peerShortId = peer.toBase58().substring(0, 6);
    final selfShortId = _host.id.toBase58().substring(0, 6);
    
    // Check for self-messaging before entering retry logic (permanent failure)
    if (peer == _host.id) {
      _logger.fine('[$selfShortId] Skipping self-message for $peerShortId');
      throw DHTNetworkException('Cannot send message to self', peerId: peer);
    }
    
    _logger.info('[$selfShortId] Sending ${message.type} to $peerShortId');
    _metrics?.recordNetworkRequest();
    
    try {
      final result = await DHTErrorHandler.handleQueryError(
        () => _sendMessageWithRetry(peer, message),
        peer,
        maxRetries: _config?.maxRetryAttempts ?? 3,
        initialBackoff: _config?.retryInitialBackoff ?? Duration(milliseconds: 500),
        context: 'sendMessage',
      ) ?? (throw DHTNetworkException('Failed to send message after all retries', peerId: peer));
      
      // Record success for the overall operation
      _metrics?.recordNetworkSuccess();
      return result;
    } catch (e) {
      // Record failure for the overall operation
      if (e is DHTTimeoutException) {
        _metrics?.recordNetworkTimeout(peer: peer);
      } else if (e is DHTMaxRetriesException && e.cause is DHTTimeoutException) {
        // If the max retries exception was caused by a timeout, record it as a timeout
        _metrics?.recordNetworkTimeout(peer: peer);
      } else {
        _metrics?.recordNetworkFailure('operation_failed', peer: peer);
      }
      rethrow;
    }
  }
  
  /// Internal method to send a message with retry logic
  Future<Message> _sendMessageWithRetry(PeerId peer, Message message) async {
    final peerShortId = peer.toBase58().substring(0, 6);
    final selfShortId = _host.id.toBase58().substring(0, 6);
    
    final stopwatch = Stopwatch()..start();
    
    try {
      // Create stream with timeout
      final stream = await _createStream(peer);
      
      try {
        // Send the message
        final responseMessage = await _exchangeMessage(stream, message);
        
        stopwatch.stop();
        _logger.fine('[$selfShortId] Successfully received response from $peerShortId in ${stopwatch.elapsedMilliseconds}ms');
        
        return responseMessage;
      } finally {
        // Always close the stream
        try {
          await stream.close();
        } catch (e) {
          _logger.warning('Failed to close stream: $e');
        }
      }
    } catch (e) {
      stopwatch.stop();
      
      if (e is TimeoutException) {
        throw DHTTimeoutException(
          'Network operation timed out after ${stopwatch.elapsedMilliseconds}ms',
          stopwatch.elapsed,
          peerId: peer,
          cause: e,
        );
      } else if (e is DHTTimeoutException) {
        // Re-throw DHTTimeoutException as-is
        rethrow;
      } else {
        throw DHTNetworkException(
          'Network operation failed: $e',
          peerId: peer,
          cause: e,
        );
      }
    }
  }
  
  /// Creates a stream to the peer with timeout
  Future<P2PStream> _createStream(PeerId peer) async {
    final timeout = _config?.networkTimeout ?? Duration(seconds: 30);
    
    try {
      final stream = await _host.newStream(
        peer,
        [AminoConstants.protocolID],
        Context(),
      ).timeout(timeout);
      
      _logger.fine('Stream created to ${peer.toBase58().substring(0, 6)}');
      _metrics?.recordConnectionOpened();
      
      return stream;
    } on TimeoutException catch (e) {
      throw DHTTimeoutException(
        'Stream creation timed out',
        timeout,
        peerId: peer,
        cause: e,
      );
    } catch (e) {
      throw DHTNetworkException(
        'Failed to create stream: $e',
        peerId: peer,
        cause: e,
      );
    }
  }
  
  /// Exchanges a message over the stream
  Future<Message> _exchangeMessage(P2PStream stream, Message message) async {
    final timeout = _config?.networkTimeout ?? Duration(seconds: 30);
    
    try {
      // Serialize and send the message
      final messageJson = message.toJson();
      final messageJsonString = jsonEncode(messageJson);
      final messageBytes = utf8.encode(messageJsonString);
      
      _logger.fine('Sending message: ${message.type} (${messageBytes.length} bytes)');
      
      await stream.write(messageBytes);
      
      // Read the response with timeout
      final responseBytes = await stream.read().timeout(timeout);
      
      _logger.fine('Received response: ${responseBytes.length} bytes');
      
      // Deserialize the response
      final responseJsonString = utf8.decode(responseBytes);
      final responseJson = jsonDecode(responseJsonString) as Map<String, dynamic>;
      final responseMessage = Message.fromJson(responseJson);
      
      return responseMessage;
    } on TimeoutException catch (e) {
      throw DHTTimeoutException(
        'Message exchange timed out',
        timeout,
        cause: e,
      );
    } catch (e) {
      throw DHTProtocolException(
        'Message exchange failed: $e',
        cause: e,
      );
    }
  }
  
  /// Ensures the network manager is started
  void _ensureStarted() {
    if (_closed) throw DHTClosedException();
    if (!_started) throw DHTNotStartedException();
  }
  
  /// Gets the host instance
  Host get host => _host;
  
  /// Checks if a peer is reachable
  Future<bool> isReachable(PeerId peer) async {
    _ensureStarted();
    
    try {
      // Try to create a stream to the peer
      final stream = await _createStream(peer);
      await stream.close();
      return true;
    } catch (e) {
      _logger.fine('Peer ${peer.toBase58().substring(0, 6)} is not reachable: $e');
      return false;
    }
  }
  
  /// Pings a peer to check connectivity
  Future<Duration?> ping(PeerId peer) async {
    _ensureStarted();
    
    final stopwatch = Stopwatch()..start();
    
    try {
      final pingMessage = Message(type: MessageType.ping);
      final response = await sendMessage(peer, pingMessage);
      
      stopwatch.stop();
      
      if (response.type == MessageType.ping) {
        return stopwatch.elapsed;
      } else {
        throw DHTProtocolException(
          'Unexpected response type: ${response.type}',
          peerId: peer,
        );
      }
    } catch (e) {
      stopwatch.stop();
      _logger.fine('Ping to ${peer.toBase58().substring(0, 6)} failed: $e');
      return null;
    }
  }
  
  @override
  String toString() => 'NetworkManager(${_host.id.toBase58().substring(0, 6)})';
} 