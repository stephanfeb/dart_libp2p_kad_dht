import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/errors/dht_errors.dart';

void main() {
  group('DHTException', () {
    test('should have correct message and cause', () {
      final exception = DHTNetworkException('Test message', cause: 'Test cause');
      
      expect(exception.message, equals('Test message'));
      expect(exception.cause, equals('Test cause'));
    });
    
    test('should have correct toString format', () {
      final exception = DHTNetworkException('Test message', cause: 'Test cause');
      
      expect(exception.toString(), equals('DHTException: Test message (caused by: Test cause)'));
    });
    
    test('should have correct toString format without cause', () {
      final exception = DHTNetworkException('Test message');
      
      expect(exception.toString(), equals('DHTException: Test message'));
    });
  });
  
  group('Specific DHT Exceptions', () {
    test('DHTNotStartedException should have correct message', () {
      final exception = DHTNotStartedException();
      
      expect(exception.message, equals('DHT is not started. Call start() first.'));
    });
    
    test('DHTClosedException should have correct message', () {
      final exception = DHTClosedException();
      
      expect(exception.message, equals('DHT is closed and cannot be used.'));
    });
    
    test('DHTBootstrapException should store all fields', () {
      final cause = Exception('Bootstrap failed');
      final stackTrace = StackTrace.current;
      final exception = DHTBootstrapException(
        'Bootstrap process failed',
        cause: cause,
        stackTrace: stackTrace,
      );
      
      expect(exception.message, equals('Bootstrap process failed'));
      expect(exception.cause, equals(cause));
      expect(exception.stackTrace, equals(stackTrace));
    });
    
    test('DHTNetworkException should store peer ID', () async {
      final peerId = await PeerId.random();
      final exception = DHTNetworkException('Network error', peerId: peerId);
      
      expect(exception.message, equals('Network error'));
      expect(exception.peerId, equals(peerId));
    });
    
    test('DHTRoutingException should store peer ID', () async {
      final peerId = await PeerId.random();
      final exception = DHTRoutingException('Routing error', peerId: peerId);
      
      expect(exception.message, equals('Routing error'));
      expect(exception.peerId, equals(peerId));
    });
    
    test('DHTQueryException should store peer ID', () async {
      final peerId = await PeerId.random();
      final exception = DHTQueryException('Query error', peerId: peerId);
      
      expect(exception.message, equals('Query error'));
      expect(exception.peerId, equals(peerId));
    });
    
    test('DHTProtocolException should store peer ID', () async {
      final peerId = await PeerId.random();
      final exception = DHTProtocolException('Protocol error', peerId: peerId);
      
      expect(exception.message, equals('Protocol error'));
      expect(exception.peerId, equals(peerId));
    });
    
    test('DHTConfigurationException should store all fields', () {
      final cause = Exception('Invalid config');
      final stackTrace = StackTrace.current;
      final exception = DHTConfigurationException(
        'Configuration is invalid',
        cause: cause,
        stackTrace: stackTrace,
      );
      
      expect(exception.message, equals('Configuration is invalid'));
      expect(exception.cause, equals(cause));
      expect(exception.stackTrace, equals(stackTrace));
    });
    
    test('DHTMaxRetriesException should store attempts and peer ID', () async {
      final peerId = await PeerId.random();
      final exception = DHTMaxRetriesException('Max retries reached', 3, peerId: peerId);
      
      expect(exception.message, equals('Max retries reached'));
      expect(exception.attempts, equals(3));
      expect(exception.peerId, equals(peerId));
    });
    
    test('DHTTimeoutException should store timeout and peer ID', () async {
      final peerId = await PeerId.random();
      final timeout = Duration(seconds: 30);
      final exception = DHTTimeoutException('Operation timed out', timeout, peerId: peerId);
      
      expect(exception.message, equals('Operation timed out'));
      expect(exception.timeout, equals(timeout));
      expect(exception.peerId, equals(peerId));
    });
  });
  
  group('DHTErrorHandler', () {
    late PeerId testPeerId;
    
    setUp(() async {
      testPeerId = await PeerId.random();
    });
    
    group('handleQueryError', () {
      test('should return successful result on first try', () async {
        final result = await DHTErrorHandler.handleQueryError(
          () async => 'success',
          testPeerId,
        );
        
        expect(result, equals('success'));
      });
      
      test('should retry on DHTNetworkException', () async {
        var attempts = 0;
        
        final result = await DHTErrorHandler.handleQueryError(
          () async {
            attempts++;
            if (attempts < 3) {
              throw DHTNetworkException('Network error', peerId: testPeerId);
            }
            return 'success';
          },
          testPeerId,
          maxRetries: 3,
          initialBackoff: Duration(milliseconds: 1), // Fast test
        );
        
        expect(result, equals('success'));
        expect(attempts, equals(3));
      });
      
      test('should retry on DHTTimeoutException', () async {
        var attempts = 0;
        
        final result = await DHTErrorHandler.handleQueryError(
          () async {
            attempts++;
            if (attempts < 2) {
              throw DHTTimeoutException('Timeout', Duration(seconds: 30), peerId: testPeerId);
            }
            return 'success';
          },
          testPeerId,
          maxRetries: 3,
          initialBackoff: Duration(milliseconds: 1), // Fast test
        );
        
        expect(result, equals('success'));
        expect(attempts, equals(2));
      });
      
      test('should not retry on DHTProtocolException', () async {
        var attempts = 0;
        
        final result = await DHTErrorHandler.handleQueryError(
          () async {
            attempts++;
            throw DHTProtocolException('Protocol error', peerId: testPeerId);
          },
          testPeerId,
          maxRetries: 3,
        );
        
        expect(result, isNull);
        expect(attempts, equals(1));
      });
      
      test('should throw DHTMaxRetriesException when max retries exceeded', () async {
        var attempts = 0;
        
        try {
          await DHTErrorHandler.handleQueryError(
            () async {
              attempts++;
              throw DHTNetworkException('Network error', peerId: testPeerId);
            },
            testPeerId,
            maxRetries: 2,
            initialBackoff: Duration(milliseconds: 1), // Fast test
          );
          fail('Expected DHTMaxRetriesException to be thrown');
        } catch (e) {
          expect(e, isA<DHTMaxRetriesException>());
        }
        
        expect(attempts, equals(2));
      });
      
      test('should throw DHTQueryException on unexpected error', () async {
        var attempts = 0;
        
        try {
          await DHTErrorHandler.handleQueryError(
            () async {
              attempts++;
              throw Exception('Unexpected error');
            },
            testPeerId,
            maxRetries: 2,
            initialBackoff: Duration(milliseconds: 1), // Fast test
          );
          fail('Expected DHTQueryException to be thrown');
        } catch (e) {
          expect(e, isA<DHTQueryException>());
        }
        
        expect(attempts, equals(2));
      });
      
      test('should not retry when retryable is false', () async {
        var attempts = 0;
        
        expect(
          () async => await DHTErrorHandler.handleQueryError(
            () async {
              attempts++;
              throw DHTNetworkException('Network error', peerId: testPeerId);
            },
            testPeerId,
            retryable: false,
            maxRetries: 3,
          ),
          throwsA(isA<DHTMaxRetriesException>()),
        );
        
        expect(attempts, equals(1));
      });
      
      test('should increase backoff on retry', () async {
        var attempts = 0;
        final backoffTimes = <DateTime>[];
        
        try {
          await DHTErrorHandler.handleQueryError(
            () async {
              attempts++;
              backoffTimes.add(DateTime.now());
              throw DHTNetworkException('Network error', peerId: testPeerId);
            },
            testPeerId,
            maxRetries: 2,
            initialBackoff: Duration(milliseconds: 10),
          );
        } catch (e) {
          // Expected to fail
        }
        
        expect(attempts, equals(2));
        expect(backoffTimes.length, equals(2));
        
        // Check that there was a delay between attempts
        if (backoffTimes.length >= 2) {
          final delay = backoffTimes[1].difference(backoffTimes[0]);
          expect(delay.inMilliseconds, greaterThanOrEqualTo(10));
        }
      });
    });
    
    group('handleNetworkError', () {
      test('should return successful result', () async {
        final result = await DHTErrorHandler.handleNetworkError(
          () async => 'success',
          testPeerId,
        );
        
        expect(result, equals('success'));
      });
      
      test('should throw DHTTimeoutException on TimeoutException', () async {
        expect(
          () async => await DHTErrorHandler.handleNetworkError(
            () async => throw TimeoutException('Timeout', Duration(seconds: 30)),
            testPeerId,
          ),
          throwsA(isA<DHTTimeoutException>()),
        );
      });
      
      test('should throw DHTNetworkException on retryable connection error', () async {
        expect(
          () async => await DHTErrorHandler.handleNetworkError(
            () async => throw SocketException('Connection refused'),
            testPeerId,
          ),
          throwsA(isA<DHTNetworkException>()),
        );
      });
      
      test('should throw DHTProtocolException on non-retryable error', () async {
        expect(
          () async => await DHTErrorHandler.handleNetworkError(
            () async => throw FormatException('Invalid format'),
            testPeerId,
          ),
          throwsA(isA<DHTProtocolException>()),
        );
      });
      
      test('should throw DHTNetworkException on unexpected error', () async {
        expect(
          () async => await DHTErrorHandler.handleNetworkError(
            () async => throw 'Unexpected error',
            testPeerId,
          ),
          throwsA(isA<DHTNetworkException>()),
        );
      });
    });
    
    group('retryable connection error handling', () {
      test('should throw DHTNetworkException on retryable connection errors', () async {
        final retryableErrors = [
          SocketException('Connection refused'),
          SocketException('Connection reset by peer'),
          SocketException('Network is unreachable'),
          SocketException('Host is down'),
          SocketException('Broken pipe'),
          SocketException('Connection timed out'),
          SocketException('Connection is closed'),
        ];
        
        for (final error in retryableErrors) {
          expect(
            () async => await DHTErrorHandler.handleNetworkError(
              () async => throw error,
              testPeerId,
            ),
            throwsA(isA<DHTNetworkException>()),
            reason: 'Should throw DHTNetworkException for ${error.message}',
          );
        }
      });
      
      test('should throw DHTProtocolException on non-retryable errors', () async {
        final nonRetryableErrors = [
          FormatException('Invalid format'),
          ArgumentError('Invalid argument'),
          StateError('Invalid state'),
        ];
        
        for (final error in nonRetryableErrors) {
          expect(
            () async => await DHTErrorHandler.handleNetworkError(
              () async => throw error,
              testPeerId,
            ),
            throwsA(isA<DHTProtocolException>()),
            reason: 'Should throw DHTProtocolException for ${error.toString()}',
          );
        }
      });
      
      test('should throw DHTNetworkException on unexpected non-Exception types', () async {
        expect(
          () async => await DHTErrorHandler.handleNetworkError(
            () async => throw 'String error',
            testPeerId,
          ),
          throwsA(isA<DHTNetworkException>()),
        );
      });
    });
    
    group('logError', () {
      test('should log error with all context', () {
        // This test verifies the method runs without throwing
        // In a real scenario, you might want to capture log output
        expect(
          () => DHTErrorHandler.logError(
            'Test operation',
            DHTNetworkException('Network error', peerId: testPeerId),
            peer: testPeerId,
            context: 'Test context',
            stackTrace: StackTrace.current,
          ),
          returnsNormally,
        );
      });
      
      test('should log error with minimal context', () {
        expect(
          () => DHTErrorHandler.logError(
            'Test operation',
            Exception('Generic error'),
          ),
          returnsNormally,
        );
      });
      
      test('should log DHT exception without stackTrace', () {
        expect(
          () => DHTErrorHandler.logError(
            'Test operation',
            DHTConfigurationException('Config error'),
          ),
          returnsNormally,
        );
      });
      
      test('should log non-DHT exception with stackTrace', () {
        expect(
          () => DHTErrorHandler.logError(
            'Test operation',
            Exception('Generic error'),
            stackTrace: StackTrace.current,
          ),
          returnsNormally,
        );
      });
    });
  });
  
  group('Exception Inheritance', () {
    test('all exceptions should extend DHTException', () {
      expect(DHTNotStartedException(), isA<DHTException>());
      expect(DHTClosedException(), isA<DHTException>());
      expect(DHTBootstrapException('test'), isA<DHTException>());
      expect(DHTNetworkException('test'), isA<DHTException>());
      expect(DHTRoutingException('test'), isA<DHTException>());
      expect(DHTQueryException('test'), isA<DHTException>());
      expect(DHTProtocolException('test'), isA<DHTException>());
      expect(DHTConfigurationException('test'), isA<DHTException>());
      expect(DHTMaxRetriesException('test', 3), isA<DHTException>());
      expect(DHTTimeoutException('test', Duration(seconds: 1)), isA<DHTException>());
    });
    
    test('all exceptions should implement Exception', () {
      expect(DHTNotStartedException(), isA<Exception>());
      expect(DHTClosedException(), isA<Exception>());
      expect(DHTBootstrapException('test'), isA<Exception>());
      expect(DHTNetworkException('test'), isA<Exception>());
      expect(DHTRoutingException('test'), isA<Exception>());
      expect(DHTQueryException('test'), isA<Exception>());
      expect(DHTProtocolException('test'), isA<Exception>());
      expect(DHTConfigurationException('test'), isA<Exception>());
      expect(DHTMaxRetriesException('test', 3), isA<Exception>());
      expect(DHTTimeoutException('test', Duration(seconds: 1)), isA<Exception>());
    });
  });
} 