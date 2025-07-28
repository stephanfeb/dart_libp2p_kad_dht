// Ported from go-libp2p-kad-dht/internal/metrics/metrics.go

import 'dart:async';
import 'package:logging/logging.dart';

import 'context.dart';

/// Unit dimensions for metrics
class Units {
  static const String message = '{message}';
  static const String count = '{count}';
  static const String error = '{error}';
  static const String bytes = 'By';
  static const String milliseconds = 'ms';
}

/// Attribute keys for metrics
class Keys {
  static const String messageType = 'message_type';
  static const String peerId = 'peer_id';
  static const String instanceId = 'instance_id';
}

/// A simple metrics implementation for DHT operations.
/// 
/// This is a simplified version of the Go implementation which used OpenTelemetry.
/// A more complete implementation would use a proper metrics library.
class DhtMetrics {
  static final Logger _logger = Logger('dart-libp2p-kad-dht.metrics');
  
  // Counters
  static int _receivedMessages = 0;
  static int _receivedMessageErrors = 0;
  static int _sentMessages = 0;
  static int _sentMessageErrors = 0;
  static int _sentRequests = 0;
  static int _sentRequestErrors = 0;
  
  // Histograms (simplified as lists of values)
  static final List<int> _receivedBytes = [];
  static final List<double> _inboundRequestLatency = [];
  static final List<double> _outboundRequestLatency = [];
  static final List<int> _sentBytes = [];
  
  // Gauge
  static int _networkSize = 0;
  
  /// Records a successful message receive operation.
  static void recordMessageRecvOK(int msgLen) {
    final attrs = attributesFromZone();
    _receivedMessages++;
    _receivedBytes.add(msgLen);
    _logger.fine('Received message: $msgLen bytes, attributes: ${attrs.toMap()}');
  }
  
  /// Records an error during message receive.
  static void recordMessageRecvErr(String messageType, int msgLen) {
    final attrs = attributesFromZone();
    _receivedMessages++;
    _receivedMessageErrors++;
    _receivedBytes.add(msgLen);
    _logger.warning('Error receiving message: $messageType, $msgLen bytes, attributes: ${attrs.toMap()}');
  }
  
  /// Records an error during message handling.
  static void recordMessageHandleErr() {
    final attrs = attributesFromZone();
    _receivedMessageErrors++;
    _logger.warning('Error handling message, attributes: ${attrs.toMap()}');
  }
  
  /// Records the latency of an inbound request.
  static void recordRequestLatency(double latencyMs) {
    final attrs = attributesFromZone();
    _inboundRequestLatency.add(latencyMs);
    _logger.fine('Request latency: $latencyMs ms, attributes: ${attrs.toMap()}');
  }
  
  /// Records an error during request sending.
  static void recordRequestSendErr() {
    final attrs = attributesFromZone();
    _sentRequests++;
    _sentRequestErrors++;
    _logger.warning('Error sending request, attributes: ${attrs.toMap()}');
  }
  
  /// Records a successful request send operation.
  static void recordRequestSendOK(int sentBytesLen, double latencyMs) {
    final attrs = attributesFromZone();
    _sentRequests++;
    _sentBytes.add(sentBytesLen);
    _outboundRequestLatency.add(latencyMs);
    _logger.fine('Sent request: $sentBytesLen bytes, $latencyMs ms, attributes: ${attrs.toMap()}');
  }
  
  /// Records a successful message send operation.
  static void recordMessageSendOK(int sentBytesLen) {
    final attrs = attributesFromZone();
    _sentMessages++;
    _sentBytes.add(sentBytesLen);
    _logger.fine('Sent message: $sentBytesLen bytes, attributes: ${attrs.toMap()}');
  }
  
  /// Records an error during message sending.
  static void recordMessageSendErr() {
    final attrs = attributesFromZone();
    _sentMessages++;
    _sentMessageErrors++;
    _logger.warning('Error sending message, attributes: ${attrs.toMap()}');
  }
  
  /// Records the estimated network size.
  static void recordNetworkSize(int size) {
    _networkSize = size;
    _logger.info('Network size: $size');
  }
  
  /// Creates a message type attribute.
  static Attribute upsertMessageType(String messageType) {
    return Attribute(Keys.messageType, messageType);
  }
  
  /// Returns the current metrics as a map.
  static Map<String, dynamic> getMetrics() {
    return {
      'received_messages': _receivedMessages,
      'received_message_errors': _receivedMessageErrors,
      'sent_messages': _sentMessages,
      'sent_message_errors': _sentMessageErrors,
      'sent_requests': _sentRequests,
      'sent_request_errors': _sentRequestErrors,
      'network_size': _networkSize,
      'received_bytes_avg': _receivedBytes.isEmpty ? 0 : _receivedBytes.reduce((a, b) => a + b) / _receivedBytes.length,
      'inbound_request_latency_avg': _inboundRequestLatency.isEmpty ? 0 : _inboundRequestLatency.reduce((a, b) => a + b) / _inboundRequestLatency.length,
      'outbound_request_latency_avg': _outboundRequestLatency.isEmpty ? 0 : _outboundRequestLatency.reduce((a, b) => a + b) / _outboundRequestLatency.length,
      'sent_bytes_avg': _sentBytes.isEmpty ? 0 : _sentBytes.reduce((a, b) => a + b) / _sentBytes.length,
    };
  }
}