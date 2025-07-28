import 'dart:typed_data';
import 'package:dart_libp2p/core/peer/peer_id.dart';

// /// Enum for lookup termination reasons (legacy compatibility)
// enum LookupTerminationReason {
//   /// The lookup found the target
//   success,
//
//   /// The lookup timed out
//   timeout,
//
//   /// The lookup was cancelled
//   cancelled,
//
//   /// The lookup ran out of peers to query
//   noMorePeers,
// }

// /// Result of a lookup with followup (legacy compatibility)
// class LookupWithFollowupResult {
//   /// The peers found during the lookup
//   final List<PeerId> peers;
//
//   /// The reason the lookup terminated
//   final LookupTerminationReason terminationReason;
//
//   /// Errors encountered during individual peer queries
//   final List<Object> errors;
//
//   /// Whether the lookup was successful
//   bool get success => terminationReason == LookupTerminationReason.success && errors.isEmpty;
//
//   /// Creates a new lookup result
//   LookupWithFollowupResult({
//     required this.peers,
//     required this.terminationReason,
//     this.errors = const [],
//   });
// }
