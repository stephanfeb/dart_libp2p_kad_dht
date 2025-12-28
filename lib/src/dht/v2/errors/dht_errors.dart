import 'dart:async';

import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/protocol/identify/identify_exceptions.dart';
import 'package:logging/logging.dart';

/// Base exception for all DHT v2 errors
abstract class DHTException implements Exception {
  final String message;
  final Object? cause;
  final StackTrace? stackTrace;
  
  const DHTException(this.message, {this.cause, this.stackTrace});
  
  @override
  String toString() => 'DHTException: $message${cause != null ? ' (caused by: $cause)' : ''}';
}

/// Exception thrown when DHT is not started
class DHTNotStartedException extends DHTException {
  const DHTNotStartedException() : super('DHT is not started. Call start() first.');
}

/// Exception thrown when DHT is already closed
class DHTClosedException extends DHTException {
  const DHTClosedException() : super('DHT is closed and cannot be used.');
}

/// Exception thrown when bootstrap process fails
class DHTBootstrapException extends DHTException {
  const DHTBootstrapException(String message, {Object? cause, StackTrace? stackTrace})
      : super(message, cause: cause, stackTrace: stackTrace);
}

/// Exception thrown when network operations fail
class DHTNetworkException extends DHTException {
  final PeerId? peerId;
  
  const DHTNetworkException(String message, {this.peerId, Object? cause, StackTrace? stackTrace})
      : super(message, cause: cause, stackTrace: stackTrace);
}

/// Exception thrown when routing operations fail
class DHTRoutingException extends DHTException {
  final PeerId? peerId;
  
  const DHTRoutingException(String message, {this.peerId, Object? cause, StackTrace? stackTrace})
      : super(message, cause: cause, stackTrace: stackTrace);
}

/// Exception thrown when query operations fail
class DHTQueryException extends DHTException {
  final PeerId? peerId;
  
  const DHTQueryException(String message, {this.peerId, Object? cause, StackTrace? stackTrace})
      : super(message, cause: cause, stackTrace: stackTrace);
}

/// Exception thrown when protocol operations fail
class DHTProtocolException extends DHTException {
  final PeerId? peerId;
  
  const DHTProtocolException(String message, {this.peerId, Object? cause, StackTrace? stackTrace})
      : super(message, cause: cause, stackTrace: stackTrace);
}

/// Exception thrown when configuration is invalid
class DHTConfigurationException extends DHTException {
  const DHTConfigurationException(String message, {Object? cause, StackTrace? stackTrace})
      : super(message, cause: cause, stackTrace: stackTrace);
}

/// Exception thrown when maximum retry attempts are exceeded
class DHTMaxRetriesException extends DHTException {
  final int attempts;
  final PeerId? peerId;
  
  const DHTMaxRetriesException(String message, this.attempts, {this.peerId, Object? cause, StackTrace? stackTrace})
      : super(message, cause: cause, stackTrace: stackTrace);
}

/// Exception thrown when timeout occurs
class DHTTimeoutException extends DHTException {
  final Duration timeout;
  final PeerId? peerId;
  
  const DHTTimeoutException(String message, this.timeout, {this.peerId, Object? cause, StackTrace? stackTrace})
      : super(message, cause: cause, stackTrace: stackTrace);
}

/// Centralized error handling for DHT operations
class DHTErrorHandler {
  static final Logger _logger = Logger('DHTErrorHandler');
  
  /// Handles query errors with consistent patterns
  static Future<T?> handleQueryError<T>(
    Future<T> Function() operation,
    PeerId peer, {
    bool retryable = true,
    int maxRetries = 3,
    Duration initialBackoff = const Duration(milliseconds: 500),
    String? context,
  }) async {
    int attempts = 0;
    Duration backoff = initialBackoff;
    
    while (true) {
      attempts++;
      
      try {
        return await operation();
      } on DHTNetworkException catch (e) {
        _logger.warning('Network error querying ${peer.toBase58().substring(0, 6)}${context != null ? ' ($context)' : ''}: ${e.message}');
        
        if (!retryable || attempts >= maxRetries) {
          throw DHTMaxRetriesException(
            'Failed to query peer after $attempts attempts',
            attempts,
            peerId: peer,
            cause: e,
          );
        }
        
        await Future.delayed(backoff);
        backoff = Duration(milliseconds: (backoff.inMilliseconds * 1.5).round());
      } on DHTTimeoutException catch (e) {
        _logger.warning('Timeout querying ${peer.toBase58().substring(0, 6)}${context != null ? ' ($context)' : ''}: ${e.message}');
        
        if (!retryable || attempts >= maxRetries) {
          throw DHTMaxRetriesException(
            'Failed to query peer after $attempts attempts (timeout)',
            attempts,
            peerId: peer,
            cause: e,
          );
        }
        
        await Future.delayed(backoff);
        backoff = Duration(milliseconds: (backoff.inMilliseconds * 1.5).round());
      } on DHTProtocolException catch (e) {
        _logger.warning('Protocol error querying ${peer.toBase58().substring(0, 6)}${context != null ? ' ($context)' : ''}: ${e.message}');
        
        // Protocol errors are usually not retryable
        return null;
      } catch (e, stackTrace) {
        _logger.severe('Unexpected error querying ${peer.toBase58().substring(0, 6)}${context != null ? ' ($context)' : ''}: $e', e, stackTrace);
        
        if (!retryable || attempts >= maxRetries) {
          throw DHTQueryException(
            'Unexpected error querying peer after $attempts attempts',
            peerId: peer,
            cause: e,
            stackTrace: stackTrace,
          );
        }
        
        await Future.delayed(backoff);
        backoff = Duration(milliseconds: (backoff.inMilliseconds * 1.5).round());
      }
    }
    // Note: This point is unreachable due to the while(true) loop's exit conditions
    // All paths either return, throw, or continue
  }
  
  /// Handles network errors with consistent patterns
  static Future<T?> handleNetworkError<T>(
    Future<T> Function() operation,
    PeerId peer, {
    String? context,
  }) async {
    try {
      return await operation();
    } on TimeoutException catch (e) {
      throw DHTTimeoutException(
        'Network operation timed out',
        e.duration ?? Duration.zero,
        peerId: peer,
        cause: e,
      );
    } on Exception catch (e) {
      if (_isRetryableConnectionError(e)) {
        throw DHTNetworkException(
          'Connection error',
          peerId: peer,
          cause: e,
        );
      } else {
        throw DHTProtocolException(
          'Protocol error',
          peerId: peer,
          cause: e,
        );
      }
    } on Error catch (e) {
      // ArgumentError, StateError, etc. are protocol errors, not network errors
      throw DHTProtocolException(
        'Protocol error',
        peerId: peer,
        cause: e,
      );
    } catch (e, stackTrace) {
      throw DHTNetworkException(
        'Unexpected network error',
        peerId: peer,
        cause: e,
        stackTrace: stackTrace,
      );
    }
  }
  
  /// Checks if an error is retryable based on its type and message
  static bool _isRetryableConnectionError(dynamic error) {
    // IdentifyTimeoutException is retryable - peer may become available later
    if (error is IdentifyTimeoutException) {
      return true;
    }
    
    // Other IdentifyException types are generally retryable (connection issues)
    if (error is IdentifyException) {
      return true;
    }
    
    if (error is Exception) {
      final errorString = error.toString().toLowerCase();
      return errorString.contains('connection refused') ||
             errorString.contains('connection reset by peer') ||
             errorString.contains('network is unreachable') ||
             errorString.contains('host is down') ||
             errorString.contains('broken pipe') ||
             errorString.contains('socketexception') ||
             errorString.contains('connection timed out') ||
             errorString.contains('connection is closed') ||
             errorString.contains('identify timeout') ||
             errorString.contains('identifytimeoutexception');
    }
    return false;
  }
  
  /// Logs error with consistent formatting
  static void logError(
    String operation,
    dynamic error, {
    PeerId? peer,
    String? context,
    StackTrace? stackTrace,
  }) {
    final peerStr = peer != null ? ' for peer ${peer.toBase58().substring(0, 6)}' : '';
    final contextStr = context != null ? ' ($context)' : '';
    
    if (error is DHTException) {
      _logger.warning('$operation failed$peerStr$contextStr: ${error.message}');
    } else {
      _logger.severe('$operation failed$peerStr$contextStr: $error', error, stackTrace);
    }
  }
} 