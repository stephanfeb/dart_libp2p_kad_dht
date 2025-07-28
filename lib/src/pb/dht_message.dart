import 'dart:typed_data';

import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:equatable/equatable.dart';
import 'package:meta/meta.dart';

import 'record.dart';

/// Enum for different types of DHT messages
enum MessageType {
  /// Store a value in the DHT
  putValue(0),

  /// Retrieve a value from the DHT
  getValue(1),

  /// Announce that this peer can provide a value for a key
  addProvider(2),

  /// Find peers that can provide a value for a key
  getProviders(3),

  /// Find the closest peers to a key
  findNode(4),

  /// Check if a peer is alive
  ping(5);

  /// The numeric value of this message type
  final int value;

  /// Constructor
  const MessageType(this.value);

  /// Get a MessageType from its numeric value
  static MessageType fromValue(int value) {
    return MessageType.values.firstWhere(
      (type) => type.value == value,
      orElse: () => throw ArgumentError('Invalid MessageType value: $value'),
    );
  }
}

/// Enum for different types of peer connections
enum ConnectionType {
  /// Sender does not have a connection to peer, and no extra information
  notConnected(0),

  /// Sender has a live connection to peer
  connected(1),

  /// Sender recently connected to peer
  canConnect(2),

  /// Sender recently tried to connect to peer repeatedly but failed to connect
  cannotConnect(3);

  /// The numeric value of this connection type
  final int value;

  /// Constructor
  const ConnectionType(this.value);

  /// Get a ConnectionType from its numeric value
  static ConnectionType fromValue(int value) {
    return ConnectionType.values.firstWhere(
      (type) => type.value == value,
      orElse: () => throw ArgumentError('Invalid ConnectionType value: $value'),
    );
  }
}

/// Represents a peer in the DHT
@immutable
class Peer extends Equatable {
  /// The ID of the peer
  final Uint8List id;

  /// The multiaddresses of the peer
  final List<Uint8List> addrs;

  /// The connection status to this peer
  final ConnectionType connection;

  /// Creates a new Peer
  const Peer({
    required this.id,
    required this.addrs,
    this.connection = ConnectionType.notConnected,
  });

  /// Creates a Peer from a map
  factory Peer.fromJson(Map<String, dynamic> json) {
    // When decoding from JSON, byte arrays are often List<int> or List<dynamic>.
    // We need to explicitly convert them to Uint8List.
    final idList = json['id'] as List<dynamic>?;
    final idBytes = idList != null ? Uint8List.fromList(idList.cast<int>()) : Uint8List(0);

    final addrsList = json['addrs'] as List<dynamic>?;
    final addrsBytes = addrsList
            ?.map((addr) => Uint8List.fromList((addr as List<dynamic>).cast<int>()))
            .toList() ??
        <Uint8List>[];

    return Peer(
      id: idBytes,
      addrs: addrsBytes,
      connection: ConnectionType.fromValue(json['connection'] as int),
    );
  }

  /// Converts this Peer to a map
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'addrs': addrs,
      'connection': connection.value,
    };
  }

  @override
  List<Object?> get props => [id, addrs, connection];

  @override
  String toString() {
    List<String> multiAddrs = addrs.map((m) => MultiAddr.fromBytes(m).toString()).toList();
    return 'Peer{id: ${PeerId.fromBytes(id)}, addrs: ${multiAddrs}, connection: $connection}';
  }
}

/// Represents a DHT message
@immutable
class Message extends Equatable {
  /// The type of this message
  final MessageType type;

  /// The cluster level of this message
  final int clusterLevelRaw;

  /// The key associated with this message
  final Uint8List? key;

  /// The record associated with this message
  final Record? record;

  /// Peers closer to the target key
  final List<Peer> closerPeers;

  /// Peers that can provide the value for the key
  final List<Peer> providerPeers;

  /// Creates a new Message
  const Message({
    required this.type,
    this.clusterLevelRaw = 0,
    this.key,
    this.record,
    this.closerPeers = const [],
    this.providerPeers = const [],
  });

  /// Creates a Message from a map
  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      type: MessageType.fromValue(json['type'] as int),
      clusterLevelRaw: json['clusterLevelRaw'] as int? ?? 0,
      key: json['key'] != null ? Uint8List.fromList((json['key'] as List<dynamic>).cast<int>()) : null,
      record: json['record'] != null
          ? Record.fromJson(json['record'] as Map<String, dynamic>)
          : null,
      closerPeers: (json['closerPeers'] as List<dynamic>?)
              ?.map((e) => Peer.fromJson(e as Map<String, dynamic>))
              .toList() ?? const [],
      providerPeers: (json['providerPeers'] as List<dynamic>?)
              ?.map((e) => Peer.fromJson(e as Map<String, dynamic>))
              .toList() ?? const [],
    );
  }

  /// Converts this Message to a map
  Map<String, dynamic> toJson() {
    return {
      'type': type.value,
      'clusterLevelRaw': clusterLevelRaw,
      if (key != null) 'key': key,
      if (record != null) 'record': record!.toJson(),
      if (closerPeers.isNotEmpty)
        'closerPeers': closerPeers.map((e) => e.toJson()).toList(),
      if (providerPeers.isNotEmpty)
        'providerPeers': providerPeers.map((e) => e.toJson()).toList(),
    };
  }

  @override
  List<Object?> get props => [
        type,
        clusterLevelRaw,
        key,
        record,
        closerPeers,
        providerPeers,
      ];

  @override
  String toString() {
    return 'Message{type: $type, clusterLevelRaw: $clusterLevelRaw, key: $key, record: $record, closerPeers: $closerPeers, providerPeers: $providerPeers}';
  }
}
