import 'dart:async';
import 'dart:math' as math;

import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/discovery/peer_info.dart';
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';

import '../kbucket/bucket/bucket.dart' as bucket;
import '../kbucket/table/table.dart';

/// Logger for the network size estimation component
final _logger = Logger('dht/netsize');

/// Indicates that we currently have no valid estimate cached.
const _invalidEstimate = -1;

/// Maximum age of measurements to consider for network size estimation
const maxMeasurementAge = Duration(hours: 2);

/// Minimum number of measurements required for network size estimation
const minMeasurementsThreshold = 5;

/// Maximum number of measurements to keep for network size estimation
const maxMeasurementsThreshold = 150;

/// Exception thrown when there is not enough data to estimate network size
class NotEnoughDataException implements Exception {
  @override
  String toString() => 'Not enough data to estimate network size';
}

/// Exception thrown when the number of peers provided doesn't match the bucket size
class WrongNumOfPeersException implements Exception {
  @override
  String toString() => 'Expected bucket size number of peers';
}

/// A measurement of peer distance for network size estimation
class Measurement {
  /// The normalized distance of the peer from the key
  final double distance;

  /// The weight of this measurement
  final double weight;

  /// When this measurement was taken
  final DateTime timestamp;

  /// Creates a new measurement
  Measurement({
    required this.distance,
    required this.weight,
    required this.timestamp,
  });
}

/// Estimates the size of the DHT network based on peer distances
class Estimator {
  /// The local node's ID
  final PeerId localId;

  /// The routing table
  final RoutingTable rt;

  /// The bucket size used in the routing table
  final int bucketSize;

  /// Lock for measurements access
  final _measurementsLock = Lock();

  /// Measurements organized by peer index
  final Map<int, List<Measurement>> _measurements = {};

  /// Cached network size estimate
  int _netSizeCache = _invalidEstimate;

  /// Creates a new network size estimator
  Estimator({
    required this.localId,
    required this.rt,
    required this.bucketSize,
  }) {
    // Initialize measurements map
    for (int i = 0; i < bucketSize; i++) {
      _measurements[i] = [];
    }
  }

  /// Calculates the normalized XOR distance between a peer ID and a key (from 0 to 1)
  static double normedDistance(PeerId peerId, String key) {
    final peerKey = XORKeySpace.key(peerId.toBytes());
    final keyBytes = XORKeySpace.key(key.codeUnits);
    return XORKeySpace.normalizedDistance(peerKey, keyBytes);
  }

  /// Calculates the normalized XOR distance between a peer info and a key (from 0 to 1)
  static double normedDistanceFromPeerInfo(PeerInfo peerInfo, String key) {
    return normedDistance(peerInfo.peerId, key);
  }

  /// Tracks the list of peers for the given key to incorporate in the next network size estimate.
  /// 
  /// [key] is expected **NOT** to be in the kademlia keyspace and [peers] is expected to be a sorted list of
  /// the closest peers to the given key (the closest first).
  /// 
  /// This function expects peers to have the same length as the routing table bucket size. It also
  /// strips old and limits the number of data points (favouring new).
  Future<void> track(String key, List<PeerInfo> peers) async {
    // Sanity check
    if (peers.length != bucketSize) {
      throw WrongNumOfPeersException();
    }

    _logger.fine('Tracking peers for key: $key');

    final now = DateTime.now();

    // Invalidate cache
    _netSizeCache = _invalidEstimate;

    // Calculate weight for the peer distances
    final weight = await _calcWeight(key, peers);

    // Map given key to the Kademlia key space (hash it)
    final ksKey = XORKeySpace.key(key.codeUnits);

    // The maximum age timestamp of the measurement data points
    final maxAgeTs = now.subtract(maxMeasurementAge);

    await _measurementsLock.synchronized(() async {
      for (int i = 0; i < peers.length; i++) {
        final p = peers[i];

        // Construct measurement struct
        final m = Measurement(
          distance: normedDistanceFromPeerInfo(p, key),
          weight: weight,
          timestamp: now,
        );

        var measurements = List<Measurement>.from(_measurements[i] ?? []);
        measurements.add(m);

        // Find the smallest index of a measurement that is still in the allowed time window
        // all measurements with a lower index should be discarded as they are too old
        final n = measurements.length;
        int idx = 0;
        while (idx < n && measurements[idx].timestamp.isBefore(maxAgeTs)) {
          idx++;
        }

        // If measurements are outside the allowed time window remove them
        if (idx != 0) {
          measurements = measurements.sublist(idx);
        }

        // If the number of data points exceed the max threshold, strip oldest measurement data points
        if (measurements.length > maxMeasurementsThreshold) {
          measurements = measurements.sublist(measurements.length - maxMeasurementsThreshold);
        }

        _measurements[i] = measurements;
      }
    });
  }

  /// Calculates the current network size estimate
  Future<int> networkSize() async {
    // Return cached calculation lock-free (fast path)
    if (_netSizeCache != _invalidEstimate) {
      _logger.fine('Cached network size estimation: $_netSizeCache');
      return _netSizeCache;
    }

    return await _measurementsLock.synchronized(() async {
      // Check a second time. This is needed because we maybe had to wait on another async call doing the computation.
      // Then the computation was just finished by the other call, and we don't need to redo it.
      if (_netSizeCache != _invalidEstimate) {
        _logger.fine('Cached network size estimation: $_netSizeCache');
        return _netSizeCache;
      }

      // Remove obsolete data points
      _garbageCollect();

      // Initialize lists for linear fit
      final xs = List<double>.filled(bucketSize, 0);
      final ys = List<double>.filled(bucketSize, 0);
      final yerrs = List<double>.filled(bucketSize, 0);

      for (int i = 0; i < bucketSize; i++) {
        final observationCount = _measurements[i]?.length ?? 0;

        // If we don't have enough data to reasonably calculate the network size, return early
        if (observationCount < minMeasurementsThreshold) {
          throw NotEnoughDataException();
        }

        // Calculate Average Distance
        double sumDistances = 0.0;
        double sumWeights = 0.0;
        for (final m in _measurements[i]!) {
          sumDistances += m.weight * m.distance;
          sumWeights += m.weight;
        }
        final distanceAvg = sumDistances / sumWeights;

        // Calculate standard deviation
        double sumWeightedDiffs = 0.0;
        for (final m in _measurements[i]!) {
          final diff = m.distance - distanceAvg;
          sumWeightedDiffs += m.weight * diff * diff;
        }
        final variance = sumWeightedDiffs / ((observationCount - 1) / observationCount * sumWeights);
        final distanceStd = math.sqrt(variance);

        // Track calculations
        xs[i] = (i + 1).toDouble();
        ys[i] = distanceAvg;
        yerrs[i] = distanceStd;
      }

      // Calculate linear regression (assumes the line goes through the origin)
      double x2Sum = 0.0, xySum = 0.0;
      for (int i = 0; i < xs.length; i++) {
        final xi = xs[i];
        final yi = ys[i];
        xySum += yerrs[i] * xi * yi;
        x2Sum += yerrs[i] * xi * xi;
      }
      final slope = xySum / x2Sum;

      // Calculate final network size
      final netSize = (1 / slope - 1).toInt();

      // Cache network size estimation
      _netSizeCache = netSize;

      _logger.fine('New network size estimation: $netSize');
      return netSize;
    });
  }

  /// Weighs data points exponentially less if they fall into a non-full bucket.
  /// It weighs distance estimates based on their CPLs and bucket levels.
  /// Bucket Level: 20 -> 1/2^0 -> weight: 1
  /// Bucket Level: 17 -> 1/2^3 -> weight: 1/8
  /// Bucket Level: 10 -> 1/2^10 -> weight: 1/1024
  Future<double> _calcWeight(String key, List<PeerInfo> peers)  async {

    //TODO: Confirm that xor distance of codeUnits actually works as expected here
    final cpl = bucket.commonPrefixLen(key.codeUnits, localId.toString().codeUnits);
    final bucketLevel = await rt.nPeersForCpl(cpl);

    if (bucketLevel < bucketSize) {
      // Routing table doesn't have a full bucket. Check how many peers would fit into that bucket
      int peerLevel = 0;
      for (final p in peers) {
        if (cpl == bucket.commonPrefixLen(p.peerId.toBytes(), localId.toBytes())) {
          peerLevel += 1;
        }
      }

      if (peerLevel > bucketLevel) {
        return math.pow(2, peerLevel - bucketSize).toDouble();
      }
    }

    return math.pow(2, bucketLevel - bucketSize).toDouble();
  }

  /// Removes all measurements from the list that fell out of the measurement time window.
  void _garbageCollect() {
    _logger.fine('Running garbage collection');

    // The maximum age timestamp of the measurement data points
    final maxAgeTs = DateTime.now().subtract(maxMeasurementAge);

    for (int i = 0; i < bucketSize; i++) {
      final measurements = _measurements[i];
      if (measurements == null || measurements.isEmpty) continue;

      // Find the smallest index of a measurement that is still in the allowed time window
      // all measurements with a lower index should be discarded as they are too old
      final n = measurements.length;
      int idx = 0;
      while (idx < n && measurements[idx].timestamp.isBefore(maxAgeTs)) {
        idx++;
      }

      // If measurements are outside the allowed time window remove them
      if (idx == n) {
        _measurements[i] = [];
      } else if (idx != 0) {
        _measurements[i] = measurements.sublist(idx);
      }
    }
  }
}


/// XOR Key Space implementation for Kademlia
class XORKeySpace {
  /// Creates a key in the XOR key space from the given bytes
  static BigInt key(List<int> bytes) {
    // Implementation depends on how keys are represented in your system
    // This is a simplified version
    return BigInt.parse(bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(), radix: 16);
  }

  /// Calculates the XOR distance between two keys
  static BigInt distance(BigInt a, BigInt b) {
    // XOR distance is the bitwise XOR of the two keys
    return a ^ b;
  }

  /// Calculates the normalized XOR distance between two keys (from 0 to 1)
  static double normalizedDistance(BigInt a, BigInt b) {
    final dist = distance(a, b);
    final keyspaceMax = BigInt.parse('1' * 256, radix: 2);
    return dist / keyspaceMax;
  }
}
