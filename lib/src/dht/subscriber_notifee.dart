// Ported from go-libp2p-kad-dht/subscriber_notifee.go

import 'dart:async';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:logging/logging.dart';
import 'dht_options.dart';
import 'package:dart_libp2p/core/network/network.dart';

import 'dht.dart';

/// Logger for subscriber notifee operations
final Logger _logger = Logger('subscriber-notifee');

/// Network event types that the DHT is interested in
enum NetworkEventType {
  /// Event when peer identification is completed
  peerIdentificationCompleted,

  /// Event when peer protocols are updated
  peerProtocolsUpdated,

  /// Event when local addresses are updated
  localAddressesUpdated,

  /// Event when peer connectedness changes
  peerConnectednessChanged,

  /// Event when local reachability changes
  localReachabilityChanged,
}

/// Network event with payload
class NetworkEvent {
  /// The type of the event
  final NetworkEventType type;

  /// The peer ID associated with the event, if any
  final PeerId? peer;

  /// The connectedness state, if this is a connectedness event
  final Connectedness? connectedness;

  /// The reachability state, if this is a reachability event
  final Reachability? reachability;

  /// Creates a new network event
  NetworkEvent({
    required this.type,
    this.peer,
    this.connectedness,
    this.reachability,
  });
}

/// A class that manages network event subscriptions for the DHT
class SubscriberNotifee {
  /// The DHT instance
  final IpfsDHT dht;

  /// Stream controller for network events
  final StreamController<NetworkEvent> _eventController = StreamController<NetworkEvent>.broadcast();

  /// Subscription to the event stream
  StreamSubscription<NetworkEvent>? _subscription;

  /// Whether the subscriber is running
  bool _running = false;

  /// Creates a new subscriber notifee for the given DHT
  SubscriberNotifee(this.dht);

  /// Starts the network subscriber
  Future<void> startNetworkSubscriber() async {
    if (_running) return;

    _running = true;

    // Set up the event stream
    _subscription = _eventController.stream.listen(_handleEvent);

    // Register for network events
    // Note: In a real implementation, we would register for actual network events
    // from the host. Since we don't have direct access to the event bus in Dart,
    // we'll simulate this by having other parts of the code call our publish methods.

    _logger.info('Network subscriber started');
  }

  /// Stops the network subscriber
  Future<void> stopNetworkSubscriber() async {
    if (!_running) return;

    _running = false;

    // Cancel the subscription
    await _subscription?.cancel();
    _subscription = null;

    _logger.info('Network subscriber stopped');
  }

  /// Handles a network event
  void _handleEvent(NetworkEvent event) {
    if (!_running) return;

    switch (event.type) {
      case NetworkEventType.peerIdentificationCompleted:
        if (event.peer != null) {
          _handlePeerChangeEvent(event.peer!);
        }
        break;

      case NetworkEventType.peerProtocolsUpdated:
        if (event.peer != null) {
          _handlePeerChangeEvent(event.peer!);
        }
        break;

      case NetworkEventType.localAddressesUpdated:
        // When our address changes, we should proactively tell our closest peers about it
        // so we become discoverable quickly
        _logger.info('Local addresses updated, refreshing routing table');
        // In a real implementation, we would trigger a routing table refresh here
        break;

      case NetworkEventType.peerConnectednessChanged:
        if (event.peer != null && event.connectedness != null && 
            event.connectedness != Connectedness.connected) {
          // Handle peer disconnection
          _logger.info('Peer ${event.peer} disconnected');
          // In a real implementation, we would handle peer disconnection here
        }
        break;

      case NetworkEventType.localReachabilityChanged:
        if (event.reachability != null) {
          _handleLocalReachabilityChangedEvent(event.reachability!);
        }
        break;
    }
  }

  /// Handles a peer change event
  Future<void> _handlePeerChangeEvent(PeerId peer) async {
    try {
      // In a real implementation, we would check if the peer supports the DHT protocol
      // For now, just try to add the peer to the routing table
      await dht.routingTable.tryAddPeer(peer, queryPeer: true);
    } catch (e) {
      _logger.warning('Could not add peer to routing table: $e');
    }
  }

  /// Handles a local reachability changed event
  void _handleLocalReachabilityChangedEvent(Reachability reachability) {
    DHTMode target;

    switch (reachability) {
      case Reachability.private:
        target = DHTMode.client;
        break;

      case Reachability.unknown:
        // Default to client mode for unknown reachability
        target = DHTMode.client;
        break;

      case Reachability.public:
        target = DHTMode.server;
        break;
    }

    _logger.info('Processed local reachability change event; should switch DHT mode to $target');

    // In a real implementation, we would switch the DHT mode here
    // For now, just log the event
    if (target == DHTMode.server) {
      _logger.info('DHT should operate in server mode');
    } else {
      _logger.info('DHT should operate in client mode');
    }
  }

  /// Publishes a peer identification completed event
  void publishPeerIdentificationCompleted(PeerId peer) {
    if (!_running) return;

    _eventController.add(NetworkEvent(
      type: NetworkEventType.peerIdentificationCompleted,
      peer: peer,
    ));
  }

  /// Publishes a peer protocols updated event
  void publishPeerProtocolsUpdated(PeerId peer) {
    if (!_running) return;

    _eventController.add(NetworkEvent(
      type: NetworkEventType.peerProtocolsUpdated,
      peer: peer,
    ));
  }

  /// Publishes a local addresses updated event
  void publishLocalAddressesUpdated() {
    if (!_running) return;

    _eventController.add(NetworkEvent(
      type: NetworkEventType.localAddressesUpdated,
    ));
  }

  /// Publishes a peer connectedness changed event
  void publishPeerConnectednessChanged(PeerId peer, Connectedness connectedness) {
    if (!_running) return;

    _eventController.add(NetworkEvent(
      type: NetworkEventType.peerConnectednessChanged,
      peer: peer,
      connectedness: connectedness,
    ));
  }

  /// Publishes a local reachability changed event
  void publishLocalReachabilityChanged(Reachability reachability) {
    if (!_running) return;

    _eventController.add(NetworkEvent(
      type: NetworkEventType.localReachabilityChanged,
      reachability: reachability,
    ));
  }
}
