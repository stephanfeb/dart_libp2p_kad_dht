import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/routing/options.dart';
// Changed validator import to use the one directly from record/validator.dart
import '../record/validator.dart' show Validator; 

import '../internal/config/quorum.dart';

/// This file implements the routing functionality for the DHT.

/// ReceivedValue stores a value and the peer from which we got the value.
class ReceivedValue {
  /// The value received
  final Uint8List val;
  
  /// The peer from which we got the value
  final PeerId from;

  /// Creates a new ReceivedValue
  ReceivedValue({required this.val, required this.from});
}

/// Helper class for DHT routing operations
class DHTRouting {
  /// Processes values from a stream, validates them, selects the best, and returns it.
  static Future<(Uint8List? bestValue, Map<PeerId, bool> peersWithBest, bool aborted)> processValues(
    String key,
    Stream<ReceivedValue> vals,
    Validator validator, // Added validator parameter
    bool Function(ReceivedValue value, bool isCurrentlyBestAmongValid) newValCallback,
  ) async {
    List<Uint8List> validValues = [];
    // Maps a valid value (as Uint8List) to the list of peers that provided this exact valid value.
    Map<String, List<PeerId>> valueSourcePeers = {}; // Key: base64 of Uint8List value

    bool abortedByCallback = false;

    await for (final receivedVal in vals) {
      if (abortedByCallback) {
        break;
      }

      try {
        await validator.validate(key, receivedVal.val); // Step 1: Validate the record (added await)
        
        // If valid, add to list and track its source
        final valKey = String.fromCharCodes(receivedVal.val); // Using string representation as key for map
        if (!valueSourcePeers.containsKey(valKey)) {
          validValues.add(receivedVal.val);
          valueSourcePeers[valKey] = [];
        }
        valueSourcePeers[valKey]!.add(receivedVal.from);
        
        bool isCurrentlyBest = false;
        if (validValues.isNotEmpty) {
            final bestIdx = await validator.select(key, validValues); // Added await
            // Check if the current receivedVal.val is the one selected as best
            if (bytesEqual(validValues[bestIdx], receivedVal.val)) {
                isCurrentlyBest = true;
            }
        }
        
        abortedByCallback = newValCallback(receivedVal, isCurrentlyBest);

      } catch (e) {
        // Validation failed (e.g., InvalidRecordError from validator.validate)
        // Log or handle as appropriate, but this record is skipped.
        // Consider using a logger instance if available, or rethrow if critical.
        print('DHTRouting.processValues: Record validation failed for key "$key" from peer ${receivedVal.from}: $e');
      }
    }

    if (validValues.isEmpty) {
      return (null, <PeerId, bool>{}, abortedByCallback); // Explicitly type the empty map
    }

    // Step 2: Select the best from all collected valid values
    final bestIndex = await validator.select(key, validValues); // Added await
    final Uint8List bestValueOverall = validValues[bestIndex];
    
    final Map<PeerId, bool> peersWithOverallBest = {};
    final bestValKey = String.fromCharCodes(bestValueOverall);
    if (valueSourcePeers.containsKey(bestValKey)) {
        for (var peerId in valueSourcePeers[bestValKey]!) {
            peersWithOverallBest[peerId] = true;
        }
    }

    return (bestValueOverall, peersWithOverallBest, abortedByCallback);
  }

  /// Helper method to compare byte arrays
  static bool bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Gets the quorum value from routing options
  static int getQuorum(RoutingOptions options) {
    if (options.other == null) {
      return 0;
    }
    
    final quorumValue = options.other![QuorumOptionKey()];
    if (quorumValue is int) {
      return quorumValue;
    }
    
    return 0;
  }
}
