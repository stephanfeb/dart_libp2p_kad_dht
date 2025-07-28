import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p_kad_dht/src/query/qpeerset.dart';
import 'package:dart_libp2p_kad_dht/src/query/query_runner.dart';
import 'package:test/test.dart';

Future<PeerId> _createPeerId() async {
  final keyPair = await generateEd25519KeyPair();
  return await PeerId.fromPublicKey(keyPair.publicKey);
}

void main() {
  group('QueryRunner', () {
    test('can be instantiated', () async {
      final target = Uint8List.fromList([1, 2, 3]);
      final queryFn = (PeerId peer) async => <AddrInfo>[];
      final stopFn = (peerset) => false;
      final initialPeers = <PeerId>[];

      expect(
        () => QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: initialPeers,
        ),
        returnsNormally,
      );
    });

    test('terminates with no peers', () async {
      final target = Uint8List.fromList([1, 2, 3]);
      final queryFn = (PeerId peer) async => <AddrInfo>[];
      final stopFn = (peerset) => false;
      final initialPeers = <PeerId>[];

      final runner = QueryRunner(
        target: target,
        queryFn: queryFn,
        stopFn: stopFn,
        initialPeers: initialPeers,
      );

      // Set up event listener BEFORE calling run()
      final eventsFuture = expectLater(
        runner.events,
        emits(
          isA<QueryTerminated>().having(
            (e) => e.result.reason,
            'reason',
            equals(QueryTerminationReason.NoMorePeers),
          ),
        ),
      );

      final result = await runner.run();
      expect(result.reason, equals(QueryTerminationReason.NoMorePeers));

      // Wait for the events to be processed
      await eventsFuture;
      
      // Clean up
      await runner.dispose();
    });

    test('queries initial peers and terminates', () async {
      final target = Uint8List.fromList([1, 2, 3]);
      final initialPeer = await _createPeerId();
      final newPeer = await _createPeerId();

      final queryFn = (PeerId peer) async {
        if (peer == initialPeer) {
          return [AddrInfo(newPeer, [])];
        }
        return <AddrInfo>[];
      };
      final stopFn = (QueryPeerset peerset) => peerset.getClosestInStates([PeerState.queried]).isNotEmpty;

      final runner = QueryRunner(
        target: target,
        queryFn: queryFn,
        stopFn: stopFn,
        initialPeers: [initialPeer],
      );

      bool peersetContains(QueryPeerset peerset, PeerId peer) {
        try {
          peerset.getState(peer);
          return true;
        } catch (e) {
          return false;
        }
      }

      // Set up event listener BEFORE calling run()
      final eventsFuture = expectLater(
        runner.events,
        emitsInOrder([
          isA<PeerQueried>().having((e) => e.peer, 'peer', equals(initialPeer)),
          isA<QueryTerminated>(),
        ]),
      );

      final result = await runner.run();
      expect(result.reason, equals(QueryTerminationReason.Success));
      expect(peersetContains(result.peerset, initialPeer), isTrue);
      expect(peersetContains(result.peerset, newPeer), isTrue);

      // Wait for the events to be processed
      await eventsFuture;
      
      // Clean up
      await runner.dispose();
    });

    test('handles query failures', () async {
      final target = Uint8List.fromList([1, 2, 3]);
      final initialPeer = await _createPeerId();
      final error = Exception('query failed');

      final queryFn = (PeerId peer) async {
        if (peer == initialPeer) {
          throw error;
        }
        return <AddrInfo>[];
      };
      final stopFn = (QueryPeerset peerset) => false;

      final runner = QueryRunner(
        target: target,
        queryFn: queryFn,
        stopFn: stopFn,
        initialPeers: [initialPeer],
      );

      // Set up event listener BEFORE calling run()
      final eventsFuture = expectLater(
        runner.events,
        emitsInOrder([
          isA<PeerQueryFailed>()
              .having((e) => e.peer, 'peer', equals(initialPeer))
              .having((e) => e.error, 'error', equals(error)),
          isA<QueryTerminated>(),
        ]),
      );

      final result = await runner.run();
      expect(result.reason, equals(QueryTerminationReason.NoMorePeers));
      expect(result.errors, contains(error));
      expect(result.peerset.getState(initialPeer), equals(PeerState.unreachable));

      // Wait for the events to be processed
      await eventsFuture;
      
      // Clean up
      await runner.dispose();
    });

    test('terminates on timeout', () async {
      final target = Uint8List.fromList([1, 2, 3]);
      final initialPeer = await _createPeerId();

      final completer = Completer<List<AddrInfo>>();
      final queryFn = (PeerId peer) => completer.future;
      final stopFn = (QueryPeerset peerset) => false;

      final runner = QueryRunner(
        target: target,
        queryFn: queryFn,
        stopFn: stopFn,
        initialPeers: [initialPeer],
        timeout: Duration(milliseconds: 10),
      );

      // Set up event listener BEFORE calling run()
      final eventsFuture = expectLater(
        runner.events,
        emits(
          isA<QueryTerminated>().having(
            (e) => e.result.reason,
            'reason',
            equals(QueryTerminationReason.Timeout),
          ),
        ),
      );

      final result = await runner.run();
      expect(result.reason, equals(QueryTerminationReason.Timeout));

      // Wait for the events to be processed
      await eventsFuture;
      
      // Clean up
      await runner.dispose();
    });

    group('Cancellation', () {
      test('cancel() while query is running', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final initialPeer = await _createPeerId();
        final completer = Completer<List<AddrInfo>>();
        
        final queryFn = (PeerId peer) => completer.future;
        final stopFn = (QueryPeerset peerset) => false;

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: [initialPeer],
        );

        // Set up event listener BEFORE calling run()
        final eventsFuture = expectLater(
          runner.events,
          emits(
            isA<QueryTerminated>().having(
              (e) => e.result.reason,
              'reason',
              equals(QueryTerminationReason.Cancelled),
            ),
          ),
        );

        // Start the query (don't await yet)
        final runFuture = runner.run();
        
        // Wait a bit to ensure query starts
        await Future.delayed(Duration(milliseconds: 5));
        expect(runner.isRunning, isTrue);
        expect(runner.isCancelled, isFalse);

        // Cancel the query
        final cancelResult = runner.cancel();
        expect(cancelResult.reason, equals(QueryTerminationReason.Cancelled));
        expect(runner.isCancelled, isTrue);

        // The run() should complete with cancelled result
        final runResult = await runFuture;
        expect(runResult.reason, equals(QueryTerminationReason.Cancelled));

        // Wait for events
        await eventsFuture;
        
        // Clean up
        await runner.dispose();
      });

      test('cancel() when not running', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final queryFn = (PeerId peer) async => <AddrInfo>[];
        final stopFn = (QueryPeerset peerset) => false;

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: [],
        );

        expect(runner.isRunning, isFalse);
        expect(runner.isCancelled, isFalse);

        // Cancel when not running
        final result = runner.cancel();
        expect(result.reason, equals(QueryTerminationReason.Cancelled));
        expect(runner.isCancelled, isTrue);
        expect(runner.isRunning, isFalse);

        // Clean up
        await runner.dispose();
      });

      test('cancellation interrupts ongoing queries', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final peer1 = await _createPeerId();
        final peer2 = await _createPeerId();
        final completer1 = Completer<List<AddrInfo>>();
        final completer2 = Completer<List<AddrInfo>>();
        
        var queryCount = 0;
        final queryFn = (PeerId peer) {
          queryCount++;
          if (peer == peer1) return completer1.future;
          if (peer == peer2) return completer2.future;
          return Future.value(<AddrInfo>[]);
        };
        final stopFn = (QueryPeerset peerset) => false;

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: [peer1, peer2],
          alpha: 2,
        );

        // Start the query
        final runFuture = runner.run();
        
        // Wait for queries to start
        await Future.delayed(Duration(milliseconds: 10));
        expect(queryCount, equals(2)); // Both peers should be queried

        // Cancel while queries are in progress
        runner.cancel();

        // Complete one of the queries after cancellation
        completer1.complete([]);
        
        final result = await runFuture;
        expect(result.reason, equals(QueryTerminationReason.Cancelled));

        // Clean up
        await runner.dispose();
      });
    });

    group('Input Validation', () {
      test('throws on alpha <= 0', () {
        final target = Uint8List.fromList([1, 2, 3]);
        final queryFn = (PeerId peer) async => <AddrInfo>[];
        final stopFn = (QueryPeerset peerset) => false;

        expect(
          () => QueryRunner(
            target: target,
            queryFn: queryFn,
            stopFn: stopFn,
            initialPeers: [],
            alpha: 0,
          ),
          throwsA(isA<AssertionError>()),
        );

        expect(
          () => QueryRunner(
            target: target,
            queryFn: queryFn,
            stopFn: stopFn,
            initialPeers: [],
            alpha: -1,
          ),
          throwsA(isA<AssertionError>()),
        );
      });

      test('throws on timeout <= 0', () {
        final target = Uint8List.fromList([1, 2, 3]);
        final queryFn = (PeerId peer) async => <AddrInfo>[];
        final stopFn = (QueryPeerset peerset) => false;

        expect(
          () => QueryRunner(
            target: target,
            queryFn: queryFn,
            stopFn: stopFn,
            initialPeers: [],
            timeout: Duration.zero,
          ),
          throwsA(isA<AssertionError>()),
        );

        expect(
          () => QueryRunner(
            target: target,
            queryFn: queryFn,
            stopFn: stopFn,
            initialPeers: [],
            timeout: Duration(milliseconds: -1),
          ),
          throwsA(isA<AssertionError>()),
        );
      });

      test('accepts valid edge case values', () {
        final target = Uint8List.fromList([1, 2, 3]);
        final queryFn = (PeerId peer) async => <AddrInfo>[];
        final stopFn = (QueryPeerset peerset) => false;

        expect(
          () => QueryRunner(
            target: target,
            queryFn: queryFn,
            stopFn: stopFn,
            initialPeers: [],
            alpha: 1,
            timeout: Duration(milliseconds: 1),
          ),
          returnsNormally,
        );
      });
    });

    group('Resource Management', () {
      test('dispose() closes streams and cancels timers', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final queryFn = (PeerId peer) async => <AddrInfo>[];
        final stopFn = (QueryPeerset peerset) => false;

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: [],
        );

        // Dispose should work even if never run
        await runner.dispose();
        
        // Event stream should be closed
        expect(runner.events, emitsDone);
      });

      test('multiple dispose() calls are safe', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final queryFn = (PeerId peer) async => <AddrInfo>[];
        final stopFn = (QueryPeerset peerset) => false;

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: [],
        );

        // Multiple dispose calls should not throw
        await runner.dispose();
        await runner.dispose();
        await runner.dispose();
      });

      test('dispose after query completion', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final queryFn = (PeerId peer) async => <AddrInfo>[];
        final stopFn = (QueryPeerset peerset) => false;

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: [],
        );

        // Run and complete the query
        final result = await runner.run();
        expect(result.reason, equals(QueryTerminationReason.NoMorePeers));

        // Dispose should work after completion
        await runner.dispose();
      });
    });

    group('State Management', () {
      test('isRunning getter reflects correct state', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final completer = Completer<List<AddrInfo>>();
        final queryFn = (PeerId peer) => completer.future;
        final stopFn = (QueryPeerset peerset) => false;
        final initialPeer = await _createPeerId();

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: [initialPeer],
        );

        // Initially not running
        expect(runner.isRunning, isFalse);

        // Start query
        final runFuture = runner.run();
        await Future.delayed(Duration(milliseconds: 5));
        
        // Should be running
        expect(runner.isRunning, isTrue);

        // Complete the query
        completer.complete([]);
        await runFuture;

        // Should not be running anymore
        expect(runner.isRunning, isFalse);

        await runner.dispose();
      });

      test('isCancelled getter reflects correct state', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final completer = Completer<List<AddrInfo>>();
        final queryFn = (PeerId peer) => completer.future;
        final stopFn = (QueryPeerset peerset) => false;
        final initialPeer = await _createPeerId();

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: [initialPeer],
        );

        // Initially not cancelled
        expect(runner.isCancelled, isFalse);

        // Start and cancel query
        final runFuture = runner.run();
        await Future.delayed(Duration(milliseconds: 5));
        
        runner.cancel();
        expect(runner.isCancelled, isTrue);

        await runFuture;
        await runner.dispose();
      });

      test('multiple run() calls throw StateError', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final completer = Completer<List<AddrInfo>>();
        final queryFn = (PeerId peer) => completer.future;
        final stopFn = (QueryPeerset peerset) => false;
        final initialPeer = await _createPeerId();

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: [initialPeer],
        );

        // Start first query
        final runFuture1 = runner.run();
        await Future.delayed(Duration(milliseconds: 5));

        // Second run() should throw
        expect(() => runner.run(), throwsStateError);

        // Complete first query
        completer.complete([]);
        await runFuture1;

        await runner.dispose();
      });

      test('can run again after completion', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final queryFn = (PeerId peer) async => <AddrInfo>[];
        final stopFn = (QueryPeerset peerset) => false;

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: [],
        );

        // First run
        final result1 = await runner.run();
        expect(result1.reason, equals(QueryTerminationReason.NoMorePeers));
        expect(runner.isRunning, isFalse);

        // Should be able to run again
        final result2 = await runner.run();
        expect(result2.reason, equals(QueryTerminationReason.NoMorePeers));

        await runner.dispose();
      });
    });

    group('Concurrency and Alpha', () {
      test('queries exactly alpha peers simultaneously', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final peers = <PeerId>[];
        
        // Create 5 peers
        for (int i = 0; i < 5; i++) {
          peers.add(await _createPeerId());
        }

        var queryCount = 0;
        final queryFn = (PeerId peer) async {
          queryCount++;
          // Return empty results to force multiple rounds
          return <AddrInfo>[];
        };
        final stopFn = (QueryPeerset peerset) => false;

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: peers,
          alpha: 3,
        );

        final result = await runner.run();
        
        // Should query all 5 peers across multiple rounds
        expect(queryCount, equals(5));
        expect(result.reason, equals(QueryTerminationReason.NoMorePeers));

        await runner.dispose();
      });

      test('alpha > available peers queries all available', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final peers = <PeerId>[];
        
        // Create only 2 peers
        for (int i = 0; i < 2; i++) {
          peers.add(await _createPeerId());
        }

        var queryCount = 0;
        final queryFn = (PeerId peer) async {
          queryCount++;
          return <AddrInfo>[];
        };
        final stopFn = (QueryPeerset peerset) => false;

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: peers,
          alpha: 5, // More than available peers
        );

        await runner.run();

        // Should query all available peers (2), not alpha (5)
        expect(queryCount, equals(2));

        await runner.dispose();
      });

      test('large alpha values work correctly', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final peers = <PeerId>[];
        
        // Create 10 peers
        for (int i = 0; i < 10; i++) {
          peers.add(await _createPeerId());
        }

        var queryCount = 0;
        final queryFn = (PeerId peer) async {
          queryCount++;
          return <AddrInfo>[];
        };
        final stopFn = (QueryPeerset peerset) => false;

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: peers,
          alpha: 100, // Very large alpha
        );

        await runner.run();

        // Should query all available peers
        expect(queryCount, equals(10));

        await runner.dispose();
      });
    });

    group('Complex Scenarios', () {
      test('multi-round peer discovery', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final initialPeer = await _createPeerId();
        final round1Peer = await _createPeerId();
        final round2Peer = await _createPeerId();

        final queryFn = (PeerId peer) async {
          if (peer == initialPeer) {
            return [AddrInfo(round1Peer, [])];
          } else if (peer == round1Peer) {
            return [AddrInfo(round2Peer, [])];
          }
          return <AddrInfo>[];
        };
        
        var roundCount = 0;
        final stopFn = (QueryPeerset peerset) {
          final queriedPeers = peerset.getClosestInStates([PeerState.queried]);
          roundCount = queriedPeers.length;
          return queriedPeers.length >= 2; // Stop after 2 peers queried
        };

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: [initialPeer],
          alpha: 1,
        );

        final result = await runner.run();
        expect(result.reason, equals(QueryTerminationReason.Success));
        expect(roundCount, equals(2));

        // Verify all peers are in the peerset
        expect(result.peerset.getState(initialPeer), equals(PeerState.queried));
        expect(result.peerset.getState(round1Peer), equals(PeerState.queried));
        expect(result.peerset.getState(round2Peer), equals(PeerState.heard));

        await runner.dispose();
      });

      test('mixed success/failure in single round', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final successPeer = await _createPeerId();
        final failurePeer = await _createPeerId();
        final newPeer = await _createPeerId();

        final queryFn = (PeerId peer) async {
          if (peer == successPeer) {
            return [AddrInfo(newPeer, [])];
          } else if (peer == failurePeer) {
            throw Exception('Query failed');
          }
          return <AddrInfo>[];
        };
        
        // Stop after the initial peers have been queried to keep newPeer in heard state
        final stopFn = (QueryPeerset peerset) {
          final queriedPeers = peerset.getClosestInStates([PeerState.queried]);
          final unreachablePeers = peerset.getClosestInStates([PeerState.unreachable]);
          // Stop when both initial peers have been processed (one queried, one unreachable)
          return queriedPeers.length + unreachablePeers.length >= 2;
        };

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: [successPeer, failurePeer],
          alpha: 2,
        );

        final result = await runner.run();
        expect(result.reason, equals(QueryTerminationReason.Success));
        expect(result.errors.length, equals(1));

        // Verify peer states
        expect(result.peerset.getState(successPeer), equals(PeerState.queried));
        expect(result.peerset.getState(failurePeer), equals(PeerState.unreachable));
        expect(result.peerset.getState(newPeer), equals(PeerState.heard));

        await runner.dispose();
      });

      test('stopFn with different conditions', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final peers = <PeerId>[];
        
        for (int i = 0; i < 3; i++) {
          peers.add(await _createPeerId());
        }

        final queryFn = (PeerId peer) async => <AddrInfo>[];
        
        // Stop after exactly 2 peers are queried
        final stopFn = (QueryPeerset peerset) {
          return peerset.getClosestInStates([PeerState.queried]).length >= 2;
        };

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: peers,
          alpha: 1, // Query one at a time
        );

        final result = await runner.run();
        expect(result.reason, equals(QueryTerminationReason.Success));
        expect(result.peerset.getClosestInStates([PeerState.queried]).length, equals(2));

        await runner.dispose();
      });

      test('peer state transitions', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final peer = await _createPeerId();
        final completer = Completer<List<AddrInfo>>();

        final queryFn = (PeerId p) => completer.future;
        final stopFn = (QueryPeerset peerset) => false;

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: [peer],
        );

        // Start query and complete it
        final runFuture = runner.run();
        await Future.delayed(Duration(milliseconds: 5));

        // Complete query
        completer.complete([]);
        final result = await runFuture;

        // Verify final state through the result
        expect(result.peerset.getState(peer), equals(PeerState.queried));

        await runner.dispose();
      });
    });

    group('Event Stream', () {
      test('events are emitted in correct order', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final peer1 = await _createPeerId();
        final peer2 = await _createPeerId();
        final newPeer = await _createPeerId();

        final queryFn = (PeerId peer) async {
          if (peer == peer1) {
            return [AddrInfo(newPeer, [])];
          }
          return <AddrInfo>[];
        };
        final stopFn = (QueryPeerset peerset) => 
            peerset.getClosestInStates([PeerState.queried]).length >= 2;

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: [peer1, peer2],
          alpha: 2,
        );

        // Set up event listener BEFORE calling run()
        final eventsFuture = expectLater(
          runner.events,
          emitsInOrder([
            isA<PeerQueried>(),
            isA<PeerQueried>(),
            isA<QueryTerminated>(),
          ]),
        );

        await runner.run();
        await eventsFuture;
        await runner.dispose();
      });

      test('multiple event listeners receive events', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final peer = await _createPeerId();

        final queryFn = (PeerId p) async => <AddrInfo>[];
        final stopFn = (QueryPeerset peerset) => false;

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: [peer],
        );

        // Set up multiple listeners
        final events1 = <QueryEvent>[];
        final events2 = <QueryEvent>[];
        
        final sub1 = runner.events.listen(events1.add);
        final sub2 = runner.events.listen(events2.add);

        await runner.run();
        
        // Wait for events to be processed
        await Future.delayed(Duration(milliseconds: 10));

        // Both listeners should receive the same events
        expect(events1.length, equals(events2.length));
        expect(events1.length, greaterThan(0));

        await sub1.cancel();
        await sub2.cancel();
        await runner.dispose();
      });

      test('event stream completes after termination', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final queryFn = (PeerId peer) async => <AddrInfo>[];
        final stopFn = (QueryPeerset peerset) => false;

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: [],
        );

        // Start listening to events
        final eventsFuture = runner.events.toList();

        // Run and complete query
        await runner.run();
        
        // Dispose to close the stream
        await runner.dispose();

        // Events should complete
        final events = await eventsFuture;
        expect(events.length, equals(1)); // Just the termination event
        expect(events.first, isA<QueryTerminated>());
      });
    });

    group('Edge Cases', () {
      test('empty initial peers with immediate stop', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final queryFn = (PeerId peer) async => <AddrInfo>[];
        final stopFn = (QueryPeerset peerset) => true; // Always stop

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: [],
        );

        final result = await runner.run();
        expect(result.reason, equals(QueryTerminationReason.NoMorePeers));

        await runner.dispose();
      });

      test('query function returning empty list', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final peer = await _createPeerId();
        final queryFn = (PeerId p) async => <AddrInfo>[]; // Always empty
        final stopFn = (QueryPeerset peerset) => false;

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: [peer],
        );

        final result = await runner.run();
        expect(result.reason, equals(QueryTerminationReason.NoMorePeers));
        expect(result.peerset.getState(peer), equals(PeerState.queried));

        await runner.dispose();
      });

      test('very short timeout', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final peer = await _createPeerId();
        final completer = Completer<List<AddrInfo>>();
        final queryFn = (PeerId p) => completer.future;
        final stopFn = (QueryPeerset peerset) => false;

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: [peer],
          timeout: Duration(milliseconds: 1), // Very short
        );

        final result = await runner.run();
        expect(result.reason, equals(QueryTerminationReason.Timeout));

        await runner.dispose();
      });

      test('exception in stopFn is handled gracefully', () async {
        final target = Uint8List.fromList([1, 2, 3]);
        final peer = await _createPeerId();
        final queryFn = (PeerId p) async => <AddrInfo>[];
        final stopFn = (QueryPeerset peerset) => throw Exception('Stop function error');

        final runner = QueryRunner(
          target: target,
          queryFn: queryFn,
          stopFn: stopFn,
          initialPeers: [peer],
        );

        // Should handle the exception and terminate gracefully
        final result = await runner.run();
        expect(result.reason, anyOf([
          QueryTerminationReason.NoMorePeers,
          QueryTerminationReason.Cancelled,
        ]));

        await runner.dispose();
      });
    });
  });
}
