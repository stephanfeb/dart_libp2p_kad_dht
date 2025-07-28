import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/managers/network_manager.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/managers/metrics_manager.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/config/dht_config.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/errors/dht_errors.dart';
import 'package:dart_libp2p_kad_dht/src/pb/dht_message.dart';
import 'package:dart_libp2p_kad_dht/src/amino/defaults.dart';

/// Mock implementation of P2PStream for testing
class MockP2PStream implements P2PStream {
  final List<Uint8List> _receivedData = [];
  final List<Uint8List> _dataToReturn = [];
  bool _closed = false;
  final PeerId _remotePeer;
  
  MockP2PStream(this._remotePeer);
  
  void addDataToReturn(Uint8List data) {
    _dataToReturn.add(data);
  }
  
  List<Uint8List> get receivedData => _receivedData;
  
  @override
  Future<void> close() async {
    _closed = true;
  }
  
  @override
  Future<Uint8List> read([int? maxBytes]) async {
    if (_closed) throw StateError('Stream is closed');
    if (_dataToReturn.isEmpty) throw StateError('No data to return');
    return _dataToReturn.removeAt(0);
  }
  
  @override
  Future<void> write(Uint8List data) async {
    if (_closed) throw StateError('Stream is closed');
    _receivedData.add(data);
  }
  
  @override
  String protocol() => AminoConstants.protocolID;
  
  PeerId get remotePeer => _remotePeer;
  
  @override
  bool get isClosed => _closed;
  
  @override
  String id() => _remotePeer.toBase58();
  
  // Use noSuchMethod to handle all other interface methods
  @override
  dynamic noSuchMethod(Invocation invocation) {
    // Handle common return types for methods we don't need to implement
    final symbolName = invocation.memberName;
    
    if (symbolName == Symbol('closeRead') ||
        symbolName == Symbol('closeWrite') ||
        symbolName == Symbol('reset') ||
        symbolName == Symbol('flush') ||
        symbolName == Symbol('setDeadline') ||
        symbolName == Symbol('setProtocol') ||
        symbolName == Symbol('setReadDeadline') ||
        symbolName == Symbol('setWriteDeadline') ||
        symbolName == Symbol('setReadTimeout') ||
        symbolName == Symbol('setWriteTimeout') ||
        symbolName == Symbol('setTimeout') ||
        symbolName == Symbol('writeString')) {
      return Future<void>.value();
    }
    
    if (symbolName == Symbol('readString')) {
      return Future<String>.value('');
    }
    
    if (symbolName == Symbol('writeInt') ||
        symbolName == Symbol('writeVarint')) {
      return Future<void>.value();
    }
    
    if (symbolName == Symbol('readInt') ||
        symbolName == Symbol('readVarint')) {
      return Future<int>.value(0);
    }
    
    if (symbolName == Symbol('sink')) {
      return Future<void>.value();
    }
    
    if (symbolName == Symbol('source')) {
      return Stream<Uint8List>.empty();
    }
    
    if (symbolName == Symbol('scope') ||
        symbolName == Symbol('stat') ||
        symbolName == Symbol('conn')) {
      return null;
    }
    
    if (symbolName == Symbol('incoming')) {
      return this; // Return self for incoming stream
    }
    
    return super.noSuchMethod(invocation);
  }
}

/// Mock implementation of Host for testing
class MockHost implements Host {
  final PeerId _id;
  final Map<PeerId, MockP2PStream> _streams = {};
  final Map<PeerId, Exception?> _streamErrors = {};
  final Map<PeerId, Duration?> _streamDelays = {};
  
  MockHost(this._id);
  
  void setStreamError(PeerId peerId, Exception? error) {
    _streamErrors[peerId] = error;
  }
  
  void setStreamDelay(PeerId peerId, Duration delay) {
    _streamDelays[peerId] = delay;
  }
  
  MockP2PStream createMockStream(PeerId peerId) {
    final stream = MockP2PStream(peerId);
    _streams[peerId] = stream;
    return stream;
  }
  
  @override
  PeerId get id => _id;
  
  @override
  Future<P2PStream> newStream(PeerId peerId, List<String> protocols, Context context) async {
    final delay = _streamDelays[peerId];
    if (delay != null) {
      await Future.delayed(delay);
    }
    
    final error = _streamErrors[peerId];
    if (error != null) {
      throw error;
    }
    
    final stream = _streams[peerId] ?? createMockStream(peerId);
    return stream;
  }
  
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('NetworkManager', () {
    late NetworkManager networkManager;
    late MockHost mockHost;
    late PeerId hostId;
    late PeerId testPeerId;
    late DHTConfigV2 config;
    late MetricsManager metrics;
    
    setUp(() async {
      hostId = await PeerId.random();
      testPeerId = await PeerId.random();
      mockHost = MockHost(hostId);
      networkManager = NetworkManager(mockHost);
      
      config = DHTConfigV2(
        networkTimeout: Duration(seconds: 5),
        maxRetryAttempts: 3,
        retryInitialBackoff: Duration(milliseconds: 100),
      );
      
      metrics = MetricsManager();
      await metrics.start();
      
      networkManager.initialize(config: config, metrics: metrics);
    });
    
    tearDown(() async {
      await networkManager.close();
      await metrics.close();
    });
    
    group('initialization', () {
      test('should initialize with configuration', () {
        expect(networkManager.host, equals(mockHost));
        expect(networkManager.toString(), contains(hostId.toBase58().substring(0, 6)));
      });
      
             test('should start successfully', () async {
         await networkManager.start();
         // Should not throw when started - test with actual operation
         mockHost.createMockStream(testPeerId);
         expect(() => networkManager.isReachable(testPeerId), returnsNormally);
       });
       
       test('should close successfully', () async {
         await networkManager.start();
         await networkManager.close();
         
         expect(
           () async => await networkManager.isReachable(testPeerId),
           throwsA(isA<DHTClosedException>()),
         );
       });
       
       test('should handle multiple start calls', () async {
         await networkManager.start();
         await networkManager.start(); // Should not throw
         
         mockHost.createMockStream(testPeerId);
         expect(() => networkManager.isReachable(testPeerId), returnsNormally);
       });
       
       test('should handle multiple close calls', () async {
         await networkManager.start();
         await networkManager.close();
         await networkManager.close(); // Should not throw
         
         expect(
           () async => await networkManager.isReachable(testPeerId),
           throwsA(isA<DHTClosedException>()),
         );
       });
    });
    
    group('state management', () {
      test('should throw DHTNotStartedException when not started', () {
        expect(
          () async => await networkManager.isReachable(testPeerId),
          throwsA(isA<DHTNotStartedException>()),
        );
      });
      
      test('should throw DHTClosedException when closed', () async {
        await networkManager.start();
        await networkManager.close();
        expect(
          () async => await networkManager.isReachable(testPeerId),
          throwsA(isA<DHTClosedException>()),
        );
      });
      
      test('should work correctly when started', () async {
        await networkManager.start();
        mockHost.createMockStream(testPeerId);
        expect(() => networkManager.isReachable(testPeerId), returnsNormally);
      });
    });
    
    group('sendMessage', () {
      setUp(() async {
        await networkManager.start();
      });
      
      test('should send and receive message successfully', () async {
        final stream = mockHost.createMockStream(testPeerId);
        final requestMessage = Message(type: MessageType.findNode, key: Uint8List.fromList([1, 2, 3]));
        final responseMessage = Message(type: MessageType.findNode, closerPeers: []);
        
        // Setup stream to return the response
        final responseJson = responseMessage.toJson();
        final responseJsonString = jsonEncode(responseJson);
        final responseBytes = utf8.encode(responseJsonString);
        stream.addDataToReturn(responseBytes);
        
        final result = await networkManager.sendMessage(testPeerId, requestMessage);
        
        expect(result.type, equals(MessageType.findNode));
        expect(result.closerPeers, isEmpty);
        
        // Verify the request was sent
        expect(stream.receivedData, hasLength(1));
        final sentData = stream.receivedData.first;
        final sentJsonString = utf8.decode(sentData);
        final sentJson = jsonDecode(sentJsonString) as Map<String, dynamic>;
        final sentMessage = Message.fromJson(sentJson);
        
        expect(sentMessage.type, equals(MessageType.findNode));
        expect(sentMessage.key, equals(Uint8List.fromList([1, 2, 3])));
      });
      
      test('should throw DHTNetworkException when sending to self', () async {
        final message = Message(type: MessageType.ping);
        
        expect(
          () async => await networkManager.sendMessage(hostId, message),
          throwsA(isA<DHTNetworkException>()),
        );
      });
      
      test('should handle stream creation failure', () async {
        mockHost.setStreamError(testPeerId, Exception('Connection failed'));
        final message = Message(type: MessageType.ping);
        
        expect(
          () async => await networkManager.sendMessage(testPeerId, message),
          throwsA(isA<DHTMaxRetriesException>()),
        );
      });
      
      test('should handle stream creation timeout', () async {
        mockHost.setStreamDelay(testPeerId, Duration(seconds: 10));
        final message = Message(type: MessageType.ping);
        
        expect(
          () async => await networkManager.sendMessage(testPeerId, message),
          throwsA(isA<DHTMaxRetriesException>()),
        );
      });
      
      test('should handle message exchange failure', () async {
        mockHost.createMockStream(testPeerId);
        final message = Message(type: MessageType.ping);
        
        // Don't setup response data - will cause read() to fail
        
        expect(
          () async => await networkManager.sendMessage(testPeerId, message),
          throwsA(isA<DHTMaxRetriesException>()),
        );
      });
      
      test('should handle malformed response', () async {
        final stream = mockHost.createMockStream(testPeerId);
        final message = Message(type: MessageType.ping);
        
        // Setup invalid JSON response
        final invalidResponse = utf8.encode('invalid json');
        stream.addDataToReturn(invalidResponse);
        
        expect(
          () async => await networkManager.sendMessage(testPeerId, message),
          throwsA(isA<DHTMaxRetriesException>()),
        );
      });
    });
    
    group('isReachable', () {
      setUp(() async {
        await networkManager.start();
      });
      
      test('should return true for reachable peer', () async {
        mockHost.createMockStream(testPeerId);
        
        final result = await networkManager.isReachable(testPeerId);
        expect(result, isTrue);
      });
      
      test('should return false for unreachable peer', () async {
        mockHost.setStreamError(testPeerId, Exception('Connection failed'));
        
        final result = await networkManager.isReachable(testPeerId);
        expect(result, isFalse);
      });
    });
    
    group('ping', () {
      setUp(() async {
        await networkManager.start();
      });
      
      test('should return ping duration for successful ping', () async {
        final stream = mockHost.createMockStream(testPeerId);
        final responseMessage = Message(type: MessageType.ping);
        
        final responseJson = responseMessage.toJson();
        final responseJsonString = jsonEncode(responseJson);
        final responseBytes = utf8.encode(responseJsonString);
        stream.addDataToReturn(responseBytes);
        
        // Add a small delay to simulate network latency
        mockHost.setStreamDelay(testPeerId, Duration(milliseconds: 10));
        
        final result = await networkManager.ping(testPeerId);
        
        expect(result, isNotNull);
        expect(result!.inMilliseconds, greaterThan(0));
      });
      
      test('should return null for failed ping', () async {
        mockHost.setStreamError(testPeerId, Exception('Connection failed'));
        
        final result = await networkManager.ping(testPeerId);
        expect(result, isNull);
      });
      
      test('should return null for wrong response type', () async {
        final stream = mockHost.createMockStream(testPeerId);
        final responseMessage = Message(type: MessageType.findNode, closerPeers: []);
        
        final responseJson = responseMessage.toJson();
        final responseJsonString = jsonEncode(responseJson);
        final responseBytes = utf8.encode(responseJsonString);
        stream.addDataToReturn(responseBytes);
        
        final result = await networkManager.ping(testPeerId);
        expect(result, isNull);
      });
    });
    
    group('error handling', () {
      setUp(() async {
        await networkManager.start();
      });
      
      test('should ensure started before operations', () async {
        await networkManager.close();
        
        expect(
          () async => await networkManager.sendMessage(testPeerId, Message(type: MessageType.ping)),
          throwsA(isA<DHTClosedException>()),
        );
        
        expect(
          () async => await networkManager.isReachable(testPeerId),
          throwsA(isA<DHTClosedException>()),
        );
        
        expect(
          () async => await networkManager.ping(testPeerId),
          throwsA(isA<DHTClosedException>()),
        );
      });
      
      test('should handle stream cleanup on error', () async {
        final stream = mockHost.createMockStream(testPeerId);
        final message = Message(type: MessageType.ping);
        
        // Setup stream to fail during message exchange
        // (no response data will cause read() to fail)
        
        try {
          await networkManager.sendMessage(testPeerId, message);
          fail('Should have thrown an exception');
        } catch (e) {
          // Expected to fail
          expect(e, isA<DHTMaxRetriesException>());
        }
        
        // Stream should be cleaned up (closed)
        expect(stream._closed, isTrue);
      });
    });
    
    group('metrics integration', () {
      setUp(() async {
        await networkManager.start();
      });
      
             test('should record metrics for successful operations', () async {
         final stream = mockHost.createMockStream(testPeerId);
         final message = Message(type: MessageType.ping);
         final responseMessage = Message(type: MessageType.ping);
         
         final responseJson = responseMessage.toJson();
         final responseJsonString = jsonEncode(responseJson);
         final responseBytes = utf8.encode(responseJsonString);
         stream.addDataToReturn(responseBytes);
         
         final initialMetrics = metrics.getMetrics();
         
         await networkManager.sendMessage(testPeerId, message);
         
         final finalMetrics = metrics.getMetrics();
         expect(finalMetrics.totalNetworkRequests, equals(initialMetrics.totalNetworkRequests + 1));
         expect(finalMetrics.successfulNetworkRequests, equals(initialMetrics.successfulNetworkRequests + 1));
       });
       
       test('should record metrics for failed operations', () async {
         mockHost.setStreamError(testPeerId, Exception('Connection failed'));
         final message = Message(type: MessageType.ping);
         
         final initialMetrics = metrics.getMetrics();
         
         try {
           await networkManager.sendMessage(testPeerId, message);
           fail('Should have thrown an exception');
         } catch (e) {
           // Expected to fail
         }
         
         final finalMetrics = metrics.getMetrics();
         expect(finalMetrics.totalNetworkRequests, equals(initialMetrics.totalNetworkRequests + 1));
         expect(finalMetrics.failedNetworkRequests, equals(initialMetrics.failedNetworkRequests + 1));
       });
       
       test('should record metrics for timeout operations', () async {
         mockHost.setStreamDelay(testPeerId, Duration(seconds: 10));
         final message = Message(type: MessageType.ping);
         
         final initialMetrics = metrics.getMetrics();
         
         try {
           await networkManager.sendMessage(testPeerId, message);
           fail('Should have thrown an exception');
         } catch (e) {
           // Expected to timeout
         }
         
         final finalMetrics = metrics.getMetrics();
         expect(finalMetrics.timeoutNetworkRequests, equals(initialMetrics.timeoutNetworkRequests + 1));
       });
    });
    
    group('configuration', () {
      test('should respect timeout configuration', () async {
        await networkManager.start();
        
        final shortTimeoutConfig = DHTConfigV2(
          networkTimeout: Duration(milliseconds: 1),
          maxRetryAttempts: 1,
        );
        
        final shortTimeoutManager = NetworkManager(mockHost);
        shortTimeoutManager.initialize(config: shortTimeoutConfig, metrics: metrics);
        await shortTimeoutManager.start();
        
        // Set a delay longer than the timeout
        mockHost.setStreamDelay(testPeerId, Duration(milliseconds: 10));
        
        final message = Message(type: MessageType.ping);
        
        expect(
          () async => await shortTimeoutManager.sendMessage(testPeerId, message),
          throwsA(isA<DHTMaxRetriesException>()),
        );
        
        await shortTimeoutManager.close();
      });
      
      test('should respect retry configuration', () async {
        await networkManager.start();
        
        final noRetryConfig = DHTConfigV2(
          maxRetryAttempts: 1,
          retryInitialBackoff: Duration(milliseconds: 1),
        );
        
        final noRetryManager = NetworkManager(mockHost);
        noRetryManager.initialize(config: noRetryConfig, metrics: metrics);
        await noRetryManager.start();
        
        // Set stream to always fail
        mockHost.setStreamError(testPeerId, Exception('Connection failed'));
        
        final message = Message(type: MessageType.ping);
        
        expect(
          () async => await noRetryManager.sendMessage(testPeerId, message),
          throwsA(isA<DHTMaxRetriesException>()),
        );
        
        await noRetryManager.close();
      });
    });
  });
} 