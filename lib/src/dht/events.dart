import 'dart:async';
import 'dart:convert';

import 'package:dart_libp2p/core/peer/peer_id.dart';

import '../kbucket/keyspace/keyspace.dart';
import '../kbucket/keyspace/kad_id.dart';

/// KeyKadID contains the Kademlia key in string and binary form.
class KeyKadID {
  /// The key in string form
  final String key;

  /// The key in binary form
  final KadID kad;

  /// Creates a new KeyKadID
  KeyKadID({
    required this.key,
    required this.kad,
  });

  /// Creates a KeyKadID from a string Kademlia ID.
  static KeyKadID fromString(String k) {
    return KeyKadID(
      key: k,
      kad: KadID.fromKey(k),
    );
  }
}

/// PeerKadID contains a libp2p Peer ID and a binary Kademlia ID.
class PeerKadID {
  /// The peer ID
  final PeerId peer;

  /// The Kademlia ID
  final KadID kad;

  /// Creates a new PeerKadID
  PeerKadID({
    required this.peer,
    required this.kad,
  });

  /// Creates a PeerKadID from a libp2p Peer ID.
  static PeerKadID fromPeerId(PeerId p) {
    return PeerKadID(
      peer: p,
      kad: KadID.fromPeerId(p),
    );
  }
}

/// Creates a slice of PeerKadID from the passed slice of libp2p Peer IDs.
List<PeerKadID> peerKadIDSliceFromPeerIds(List<PeerId> peers) {
  return peers.map((p) => PeerKadID.fromPeerId(p)).toList();
}

/// Returns a PeerKadID or null if the passed Peer ID is empty.
PeerKadID? optPeerKadID(PeerId p) {
  if (p.toString().isEmpty) {
    return null;
  }
  return PeerKadID.fromPeerId(p);
}

/// LookupEvent is emitted for every notable event that happens during a DHT lookup.
class LookupEvent {
  /// Node is the ID of the node performing the lookup.
  final PeerKadID? node;

  /// ID is a unique identifier for the lookup instance.
  final String id;

  /// Key is the Kademlia key used as a lookup target.
  final KeyKadID? key;

  /// Request, if not null, describes a state update event, associated with an outgoing query request.
  final LookupUpdateEvent? request;

  /// Response, if not null, describes a state update event, associated with an outgoing query response.
  final LookupUpdateEvent? response;

  /// Terminate, if not nil, describe a termination event.
  final LookupTerminateEvent? terminate;

  /// Creates a new LookupEvent
  LookupEvent({
    this.node,
    required this.id,
    this.key,
    this.request,
    this.response,
    this.terminate,
  });

  /// Creates a LookupEvent automatically converting the node
  /// libp2p Peer ID to a PeerKadID and the string Kademlia key to a KeyKadID.
  static LookupEvent create({
    required PeerId node,
    required String id,
    required String key,
    LookupUpdateEvent? request,
    LookupUpdateEvent? response,
    LookupTerminateEvent? terminate,
  }) {
    return LookupEvent(
      node: PeerKadID.fromPeerId(node),
      id: id,
      key: KeyKadID.fromString(key),
      request: request,
      response: response,
      terminate: terminate,
    );
  }

  /// Converts the event to JSON
  Map<String, dynamic> toJson() {
    return {
      'node': node != null ? {'peer': node!.peer.toString(), 'kad': node!.kad.toString()} : null,
      'id': id,
      'key': key != null ? {'key': key!.key, 'kad': key!.kad.toString()} : null,
      'request': request?.toJson(),
      'response': response?.toJson(),
      'terminate': terminate?.toJson(),
    };
  }
}

/// LookupUpdateEvent describes a lookup state update event.
class LookupUpdateEvent {
  /// Cause is the peer whose response (or lack of response) caused the update event.
  /// If Cause is nil, this is the first update event in the lookup, caused by the seeding.
  final PeerKadID? cause;

  /// Source is the peer who informed us about the peer IDs in this update (below).
  final PeerKadID? source;

  /// Heard is a set of peers whose state in the lookup's peerset is being set to "heard".
  final List<PeerKadID> heard;

  /// Waiting is a set of peers whose state in the lookup's peerset is being set to "waiting".
  final List<PeerKadID> waiting;

  /// Queried is a set of peers whose state in the lookup's peerset is being set to "queried".
  final List<PeerKadID> queried;

  /// Unreachable is a set of peers whose state in the lookup's peerset is being set to "unreachable".
  final List<PeerKadID> unreachable;

  /// Creates a new LookupUpdateEvent
  LookupUpdateEvent({
    this.cause,
    this.source,
    this.heard = const [],
    this.waiting = const [],
    this.queried = const [],
    this.unreachable = const [],
  });

  /// Creates a new lookup update event, automatically converting the passed peer IDs to peer Kad IDs.
  static LookupUpdateEvent create({
    PeerId? cause,
    PeerId? source,
    List<PeerId> heard = const [],
    List<PeerId> waiting = const [],
    List<PeerId> queried = const [],
    List<PeerId> unreachable = const [],
  }) {
    return LookupUpdateEvent(
      cause: cause != null ? optPeerKadID(cause) : null,
      source: source != null ? optPeerKadID(source) : null,
      heard: peerKadIDSliceFromPeerIds(heard),
      waiting: peerKadIDSliceFromPeerIds(waiting),
      queried: peerKadIDSliceFromPeerIds(queried),
      unreachable: peerKadIDSliceFromPeerIds(unreachable),
    );
  }

  /// Converts the event to JSON
  Map<String, dynamic> toJson() {
    return {
      'cause': cause != null ? {'peer': cause!.peer.toString(), 'kad': cause!.kad.toString()} : null,
      'source': source != null ? {'peer': source!.peer.toString(), 'kad': source!.kad.toString()} : null,
      'heard': heard.map((p) => {'peer': p.peer.toString(), 'kad': p.kad.toString()}).toList(),
      'waiting': waiting.map((p) => {'peer': p.peer.toString(), 'kad': p.kad.toString()}).toList(),
      'queried': queried.map((p) => {'peer': p.peer.toString(), 'kad': p.kad.toString()}).toList(),
      'unreachable': unreachable.map((p) => {'peer': p.peer.toString(), 'kad': p.kad.toString()}).toList(),
    };
  }
}

/// LookupTerminationReason captures reasons for terminating a lookup.
enum LookupTerminationReason {
  /// The lookup was stopped by the user's stopFn.
  stopped,

  /// The lookup was cancelled by the context.
  cancelled,

  /// The lookup terminated due to lack of unqueried peers.
  starvation,

  /// The lookup terminated successfully, reaching the Kademlia end condition.
  completed,
}

/// LookupTerminateEvent describes a lookup termination event.
class LookupTerminateEvent {
  /// The reason for lookup termination.
  final LookupTerminationReason reason;

  /// Creates a new LookupTerminateEvent
  LookupTerminateEvent({
    required this.reason,
  });

  /// Converts the event to JSON
  Map<String, dynamic> toJson() {
    return {
      'reason': reason.toString().split('.').last,
    };
  }
}

/// Key for storing lookup event channels in context
class _LookupEventChannelKey {
  const _LookupEventChannelKey();
}

/// The key used to store lookup event channels in context
const _lookupEventChannelKey = _LookupEventChannelKey();

/// A channel for lookup events
class LookupEventChannel {
  /// The stream controller for events
  final StreamController<LookupEvent> _controller;

  /// Whether the channel is closed
  bool _closed = false;

  /// Creates a new lookup event channel
  LookupEventChannel() : _controller = StreamController<LookupEvent>.broadcast();

  /// Gets the stream of events
  Stream<LookupEvent> get stream => _controller.stream;

  /// Sends an event on the channel
  void send(LookupEvent event) {
    if (!_closed && !_controller.isClosed) {
      _controller.add(event);
    }
  }

  /// Closes the channel
  Future<void> close() async {
    _closed = true;
    await _controller.close();
  }
}

/// The number of events to buffer
const lookupEventBufferSize = 16;

/// Registers a lookup event channel.
/// The returned context can be passed to DHT queries to receive lookup events on
/// the returned stream.
///
/// The caller MUST close the returned channel when no longer interested
/// in query events.
LookupEventChannel registerForLookupEvents() {
  return LookupEventChannel();
}

/// Publishes a lookup event to the lookup event channel
/// associated with the given context, if any.
void publishLookupEvent(LookupEventChannel? channel, LookupEvent event) {
  if (channel != null) {
    channel.send(event);
  }
}
