import 'package:test/test.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart'; // For PeerId
import '../../lib/src/kbucket/table/table.dart'; // For RoutingTable
import '../../lib/src/kbucket/keyspace/kad_id.dart'; // For KadId - though not directly used in constructor test anymore
import '../../lib/src/netsize/netsize.dart'; // For Estimator, NotEnoughDataException, PeerLatencyMetrics (from table.dart)
// XORKeySpace is also in netsize.dart and will be used by Estimator.normedDistance

// Mock for PeerLatencyMetrics required by RoutingTable
class MockPeerLatencyMetrics implements PeerLatencyMetrics {
  @override
  Duration latencyEWMA(PeerId peerId) {
    return const Duration(milliseconds: 10); // Default low latency
  }
}

void main() {
  group('Estimator', () {
    group('constructor', () {
      test('initializes correctly', () async {
        const bucketSize = 20;
        final localPeerId = await PeerId.random();
        // final localKadId = KadId(localPeerId.toBytes()); // Not needed for RT constructor

        final rt = RoutingTable(
          local: localPeerId, // Changed from localId, expects PeerId
          bucketSize: bucketSize,
          maxLatency: const Duration(seconds: 1), // Changed from latencyTolerance
          metrics: MockPeerLatencyMetrics(), // Added required metrics
          usefulnessGracePeriod: const Duration(seconds: 1), // Changed from replacementCacheTTL
        );

        final estimator = Estimator(
          localId: localPeerId,
          rt: rt,
          bucketSize: bucketSize,
        );

        expect(estimator.localId, localPeerId);
        expect(estimator.rt, rt);
        expect(estimator.bucketSize, bucketSize);

        // Indirectly test that _netSizeCache is initially _invalidEstimate
        // and measurements are insufficient.
        expect(
          () => estimator.networkSize(),
          throwsA(isA<NotEnoughDataException>()),
        );
      });
    });

    group('Estimator.normedDistance', () {
      test('calculates zero distance for equivalent peerId and key string', () async {
        final pid1 = await PeerId.random();
        // Construct a key string whose .codeUnits will match pid1.toBytes()
        final keyStringForPid1 = String.fromCharCodes(pid1.toBytes());

        final dist = Estimator.normedDistance(pid1, keyStringForPid1);
        expect(dist, 0.0);
      });

      test('calculates non-zero distance for different peerId and key string', () async {
        final pid1 = await PeerId.random();
        final pid2 = await PeerId.random();

        // Ensure pids are different, although PeerId.random() should guarantee this
        expect(pid1 == pid2, isFalse);

        final keyStringForPid2 = String.fromCharCodes(pid2.toBytes());

        final dist = Estimator.normedDistance(pid1, keyStringForPid2);
        expect(dist, greaterThan(0.0));
        // Matching Go's assert.Less(t, dist, 1.0)
        // Note: Dart's XORKeySpace.normalizedDistance can return 1.0.
        // If this test fails because dist is 1.0, it might indicate a
        // subtle difference or an edge case not strictly covered by Go's assertion.
        expect(dist, lessThan(1.0));
      });
    });
  });
}
