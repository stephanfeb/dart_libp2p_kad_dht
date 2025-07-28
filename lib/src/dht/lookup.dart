import 'dart:typed_data';

import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/routing/routing.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:dart_libp2p_kad_dht/src/kbucket/keyspace/kad_id.dart';
import 'package:dart_libp2p_kad_dht/src/kbucket/table/table_refresh.dart';


/// Extension methods for DHT to handle lookups
extension LookupExtension on IpfsDHT {
  /// GetClosestPeers is a Kademlia 'node lookup' operation. Returns a list of
  /// the K closest peers to the given key.
  ///
  /// If the operation is canceled, this function will return the closest K peers
  /// it has found so far along with an error.
  Future<List<PeerId>> getClosestPeers(String key) async {
    if (key.isEmpty) {
      throw ArgumentError('Cannot lookup empty key');
    }

    // Run the lookup with the pmGetClosestPeers query function
    final lookupRes = await this.runLookupWithFollowup(
      target: Uint8List.fromList(key.codeUnits),
      queryFn: (peer) => pmGetClosestPeers(peer, key),
      stopFn: (peerset) => false, // Never stop early
    );

    // Track lookup results for network size estimator
    try {
      // In a real implementation, we would track the lookup results for network size estimation
      // For now, just log a message
      print('Network size estimator: tracking lookup results for key $key');

      // If we had a network size estimator, we would record the network size metric
      // metrics.RecordNetworkSize(int64(ns))
    } catch (e) {
      // Log warning if there was an error tracking the lookup results
      print('Warning: network size estimator track peers: $e');
    }

    // Reset the refresh timer for this key's bucket since we've just
    // successfully interacted with the closest peers to key
    routingTable.resetCplRefreshedAtForID(KadID.fromKey(key).bytes, DateTime.now());

    return lookupRes.peers;
  }
  
  /// pmGetClosestPeers is the protocol messenger version of the GetClosestPeer queryFn.
  Future<List<AddrInfo>> pmGetClosestPeers(PeerId p, String key) async {
    // For DHT query event
    RoutingNotifier.publishQueryEvent(RoutingQueryEvent(
      type: QueryEventType.sendingQuery,
      id: p,
    ));

    try {
      // In the Go implementation, this would call the protocol messenger's GetClosestPeers method
      // For now, we'll simulate this by creating a message and sending it
      final message = Message(
        type: MessageType.findNode,
        key: Uint8List.fromList(key.codeUnits),
      );

      // Send the message to the peer
      final response = await sendMessage(p, message);

      // Convert the response to AddrInfo objects
      final peers = response.closerPeers.map((p) => AddrInfo(
        PeerId.fromBytes(p.id),
        p.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList(),
      )).toList();

      // For DHT query event
      RoutingNotifier.publishQueryEvent(RoutingQueryEvent(
        type: QueryEventType.peerResponse,
        id: p,
        responses: peers,
      ));

      return peers;
    } catch (e) {
      // Log the error
      print('Error getting closer peers: $e');

      // For DHT query event
      RoutingNotifier.publishQueryEvent(RoutingQueryEvent(
        type: QueryEventType.queryError,
        id: p,
        extra: e.toString(),
      ));

      // Rethrow the error
      rethrow;
    }
  }
}

/// A utility class for publishing routing query events
class RoutingNotifier {
  /// Publishes a query event
  static void publishQueryEvent(RoutingQueryEvent event) {
    // In a real implementation, this would publish the event to a stream
    // For now, just log the event
    print('Publishing query event: ${event.type} for peer ${event.id}');
  }
}

/// Types of query events
enum QueryEventType {
  /// Sending a query to a peer
  sendingQuery,

  /// Received a response from a peer
  peerResponse,

  /// An error occurred during a query
  queryError,
}

/// A routing query event
class RoutingQueryEvent {
  /// The type of event
  final QueryEventType type;

  /// The peer ID involved
  final PeerId id;

  /// Additional information about the event
  final String? extra;

  /// Responses from the peer
  final List<AddrInfo>? responses;

  /// Creates a new routing query event
  RoutingQueryEvent({
    required this.type,
    required this.id,
    this.extra,
    this.responses,
  });
}
