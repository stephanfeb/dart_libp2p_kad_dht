import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/peer/peer_id.dart';
// Import Peerstore and Metrics from the same file
import 'package:dart_libp2p/core/peerstore.dart' show Peerstore, Metrics;


// Interfaces like Host, Stream, Message are imported from here
import 'package:dart_libp2p_kad_dht/src/internal/net/message_manager.dart';
import 'package:test/test.dart';

// Mocks

// This mock implements the general Metrics interface from dart_libp2p
class MockMetrics implements Metrics {
  @override
  void recordLatency(PeerId p, Duration d) {
    // no-op
  }

  // Implement other methods from the Metrics interface if necessary,
  // though for this specific test, only recordLatency is directly called
  // by the code path under test in MessageSenderImpl.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    // Allow other methods to be called without crashing if the interface is larger
    print('MockMetrics: Unmocked method ${invocation.memberName} called');
    return null;
  }
}

class MockPeerstore implements Peerstore {
  final MockMetrics _metrics = MockMetrics();

  @override
  Metrics get metrics => _metrics; // Now returns the correct type

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockHost implements Host {
  final String? unreachablePeerId;
  // Peerstore type comes from the corrected import
  final Peerstore _peerstore = MockPeerstore();

  MockHost({this.unreachablePeerId});

  @override
  // Stream type comes from message_manager.dart
  Future<Stream> newStream(String peerId, List<String> protocols) async {
    if (peerId == unreachablePeerId) {
      throw Exception('Simulated connection failure to $peerId');
    }
    // For other peers, return a dummy stream or throw if not expected
    return MockStream();
  }

  @override
  // Peerstore type comes from the corrected import
  Peerstore get peerstore => _peerstore;
  
  @override
  void recordLatency(String peerId, Duration latency) {
    // no-op
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockStream implements Stream {
  @override
  Future<void> close() async {
    // no-op
  }

  @override
  Future<Uint8List> read() async {
    // Simulate a read, perhaps return empty or throw if not expected
    return Uint8List(0);
  }

  @override
  Future<void> reset() async {
    // no-op
  }

  @override
  Future<void> write(Uint8List data) async {
    // no-op
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockMessage implements Message {
  @override
  String get type => 'mock_message';

  @override
  Future<Uint8List> marshal() async {
    return Uint8List.fromList('mock_data'.codeUnits);
  }

  // Static unmarshal is not directly part of the instance, so not mocked here
  // unless a specific test needs to call Message.unmarshal.
}

void main() {
  group('MessageSenderImpl Tests', () {
    test('invalid message sender tracking (port of TestInvalidMessageSenderTracking)', () async {
      final unreachablePeerIdStr = 'unreachable-peer-id-string';
      // Note: dart_libp2p PeerId.fromString might not exist or work this way.
      // For the purpose of this test, MessageSenderImpl takes a String peerId.
      // If it required a PeerId object, we'd create one.

      final mockHost = MockHost(unreachablePeerId: unreachablePeerIdStr);
      final protocols = ['/test/kad/1.0.0'];
      final messageSender = MessageSenderImpl(mockHost, protocols);
      final mockMessage = MockMessage();

      // Expect sendRequest to throw because newStream will fail for unreachablePeerId
      await expectLater(
        messageSender.sendRequest(unreachablePeerIdStr, mockMessage),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'toString()',
          // The actual exception message from MessageSenderImpl
          contains('Failed to open message sender'),
        )),
      );

      // Verify that the _senders map in MessageSenderImpl is empty
      expect(messageSender.sendersMapSize, 0);
    });
  });
}
