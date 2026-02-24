import 'dart:async';
import 'dart:convert'; // Added for base64Encode, and for logging keys
import 'dart:typed_data';
import 'package:dcid/dcid.dart';
import 'package:logging/logging.dart'; // Added for logging

import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/multiaddr.dart';

import '../pb/dht_message.dart';
import '../pb/record.dart';
import 'dht.dart';
import 'dht_filters.dart';

/// Type definition for a DHT message handler function
typedef DHTHandler = Future<Message> Function(PeerId peer, Message message);

/// Handlers for DHT protocol messages
class DHTHandlers {
  static final _log = Logger('DHTHandlers');

  /// The DHT instance
  final IpfsDHT dht;

  /// Creates a new set of DHT handlers
  DHTHandlers(this.dht);

  String get _logPrefix {
    final id = dht.host().id.toBase58();
    return '[${id.substring(id.length - 6)}.DHTHandlers]';
  }

    /// Gets the appropriate handler for a message type
    DHTHandler handlerForMsgType(MessageType type) {
      _log.finer('$_logPrefix Getting handler for message type: $type');
      switch (type) {
        case MessageType.ping:
          return handlePing;
        case MessageType.findNode:
          return handleFindPeer;
        case MessageType.getValue:
          return handleGetValue;
        case MessageType.putValue:
          return handlePutValue;
        case MessageType.getProviders:
          return handleGetProviders;
        case MessageType.addProvider:
          return handleAddProvider;
        default:
          _log.severe('$_logPrefix Unknown message type received: $type');
          throw ArgumentError('Unknown message type: $type');
      }
    }

    Future<void> _tryAddSenderToRT(PeerId sender, String handlerName, {List<MultiAddr>? senderAddrs}) async {
      final senderShortId = sender.toBase58().substring(0,6);
      try {
        // Store addresses in peerstore if available
        if (senderAddrs != null && senderAddrs.isNotEmpty) {
          _log.fine('$_logPrefix $handlerName: Storing ${senderAddrs.length} addresses for sender $senderShortId in peerstore: ${senderAddrs.map((a) => a.toString()).join(", ")}');
          await dht.host().peerStore.addrBook.addAddrs(sender, senderAddrs, Duration(hours: 1));
        } else {
          _log.fine('$_logPrefix $handlerName: No addresses provided for sender $senderShortId - checking if already in peerstore');
          final existingPeerInfo = await dht.host().peerStore.getPeer(sender);
          if (existingPeerInfo == null || existingPeerInfo.addrs.isEmpty) {
            _log.warning('$_logPrefix $handlerName: Sender $senderShortId has no addresses in peerstore and none provided');
          }
        }

        bool added = await dht.routingTable.tryAddPeer(sender, queryPeer: true, isReplaceable: true);
        _log.fine('$_logPrefix $handlerName: Attempted to add sender $senderShortId to RT. Success: $added. RT Size: ${await dht.routingTable.size()}');
      } catch (e,s) {
        _log.warning('$_logPrefix $handlerName: Error adding sender $senderShortId to RT: $e\n$s');
      }
    }

    /// Handles a PING message
    Future<Message> handlePing(PeerId peer, Message message) async {
      final peerShortId = peer.toBase58().substring(0,6);
      _log.info('$_logPrefix handlePing: Received PING from $peerShortId.');
      // Defer RT insertion (non-blocking) — respond to ping as fast as possible
      _tryAddSenderToRT(peer, 'handlePing').catchError((e) {
        _log.warning('$_logPrefix handlePing: Deferred RT insertion failed: $e');
      });
      return Message(type: MessageType.ping);
    }

    /// Handles a FIND_NODE message
    Future<Message> handleFindPeer(PeerId peer, Message message) async {
      final peerShortId = peer.toBase58().substring(0,6);
      final keyString = message.key != null ? base64Encode(message.key!) : "null";
      _log.info('$_logPrefix handleFindPeer: Received FIND_NODE from $peerShortId for key $keyString.');

      if (message.key == null) {
        _log.warning('$_logPrefix handleFindPeer: FIND_NODE message from $peerShortId missing key.');
        throw ArgumentError('FIND_NODE message must have a key');
      }

      final response = Message(
        type: MessageType.findNode,
        key: message.key,
        closerPeers: [],
      );

      try {
        final closestPeerIds = await dht.routingTable.nearestPeers(message.key!, dht.options.bucketSize);
        _log.fine('$_logPrefix handleFindPeer: Found ${closestPeerIds.length} closest peers in RT for key $keyString.');

        // Filter out the querying peer
        final filteredPeerIds = closestPeerIds.where((pId) => pId != peer).toList();

        // Parallel peerstore lookups instead of sequential
        final peerInfoFutures = filteredPeerIds.map((pId) => dht.host().peerStore.getPeer(pId));
        final peerInfoResults = await Future.wait(peerInfoFutures);

        for (var i = 0; i < filteredPeerIds.length; i++) {
          final pId = filteredPeerIds[i];
          var peerAddrs = peerInfoResults[i]?.addrs.toList() ?? <MultiAddr>[];

          // Filter out localhost addresses if the option is enabled
          if (dht.options.filterLocalhostInResponses) {
            peerAddrs = filterLocalhostAddrs(peerAddrs);
          }

          final addrsBytesList = peerAddrs.map((addr) => addr.toBytes()).toList();

          if (addrsBytesList.isEmpty) {
            _log.warning('$_logPrefix handleFindPeer: Peer ${pId.toBase58().substring(0,6)} has no addresses after filtering');
            continue;
          }

          response.closerPeers.add(Peer(
            id: pId.toBytes(),
            addrs: addrsBytesList,
            connection: ConnectionType.notConnected,
          ));
        }
        _log.info('$_logPrefix handleFindPeer: Responding to $peerShortId for key $keyString with ${response.closerPeers.length} closerPeers.');

        // Defer sender RT insertion to after response is built (non-blocking)
        _tryAddSenderToRT(peer, 'handleFindPeer').catchError((e) {
          _log.warning('$_logPrefix handleFindPeer: Deferred RT insertion failed: $e');
        });

        return response;
      } catch (e, s) {
        _log.severe('$_logPrefix handleFindPeer: Error processing FIND_NODE from $peerShortId for key $keyString: $e\n$s');
        response.closerPeers.clear();
        return response; // Return empty closerPeers on error
      }
    }

    /// Handles a GET_VALUE message
    Future<Message> handleGetValue(PeerId peer, Message message) async {
      final peerShortId = peer.toBase58().substring(0,6);
      final keyString = message.key != null ? base64Encode(message.key!) : "null";
      _log.info('$_logPrefix handleGetValue: Received GET_VALUE from $peerShortId for key $keyString.');

      if (message.key == null) {
        _log.warning('$_logPrefix handleGetValue: GET_VALUE message from $peerShortId missing key.');
        throw ArgumentError('GET_VALUE message must have a key');
      }

      final response = Message(
        type: MessageType.getValue,
        key: message.key,
        closerPeers: [],
      );

      try {
        _log.finer('$_logPrefix handleGetValue: Checking local datastore for key $keyString.');
        final record = await dht.checkLocalDatastore(message.key!);
        if (record != null) {
          _log.info('$_logPrefix handleGetValue: Found record locally for key $keyString. Responding to $peerShortId with record.');
          // Defer RT insertion (non-blocking)
          _tryAddSenderToRT(peer, 'handleGetValue').catchError((e) {
            _log.warning('$_logPrefix handleGetValue: Deferred RT insertion failed: $e');
          });
          return Message(
            type: MessageType.getValue,
            key: message.key,
            record: record,
            closerPeers: response.closerPeers,
          );
        }
        _log.fine('$_logPrefix handleGetValue: Record for key $keyString not found locally. Finding closer peers.');

        final closestPeerIdsFromRT = await dht.routingTable.nearestPeers(message.key!, dht.options.bucketSize);
        _log.fine('$_logPrefix handleGetValue: Found ${closestPeerIdsFromRT.length} closest peer IDs in RT for key $keyString.');

        // Filter out the querying peer
        final filteredPeerIds = closestPeerIdsFromRT.where((pId) => pId != peer).toList();

        // Parallel peerstore lookups instead of sequential
        final peerInfoFutures = filteredPeerIds.map((pId) => dht.host().peerStore.getPeer(pId));
        final peerInfoResults = await Future.wait(peerInfoFutures);

        for (var i = 0; i < filteredPeerIds.length; i++) {
          final pId = filteredPeerIds[i];
          var peerAddrs = peerInfoResults[i]?.addrs.toList() ?? <MultiAddr>[];

          if (dht.options.filterLocalhostInResponses) {
            peerAddrs = filterLocalhostAddrs(peerAddrs);
          }

          final addrsBytesList = peerAddrs.map((addr) => addr.toBytes()).toList();

          if (addrsBytesList.isEmpty) {
            _log.warning('$_logPrefix handleGetValue: Peer ${pId.toBase58().substring(0,6)} has no addresses after filtering');
            continue;
          }

          response.closerPeers.add(Peer(
            id: pId.toBytes(),
            addrs: addrsBytesList,
            connection: ConnectionType.notConnected,
          ));
        }
        _log.info('$_logPrefix handleGetValue: Responding to $peerShortId for key $keyString with ${response.closerPeers.length} closerPeers (no local record).');

        // Defer sender RT insertion to after response is built (non-blocking)
        _tryAddSenderToRT(peer, 'handleGetValue').catchError((e) {
          _log.warning('$_logPrefix handleGetValue: Deferred RT insertion failed: $e');
        });

        return response;
      } catch (e, s) {
        _log.severe('$_logPrefix handleGetValue: Error processing GET_VALUE from $peerShortId for key $keyString: $e\n$s');
        return response;
      }
    }

    /// Handles a PUT_VALUE message
    Future<Message> handlePutValue(PeerId peer, Message message) async {
      final peerShortId = peer.toBase58().substring(0,6);
      final keyString = message.key != null ? base64Encode(message.key!) : "null";
      _log.info('$_logPrefix handlePutValue: Received PUT_VALUE from $peerShortId for key $keyString.');
      // Not typically adding sender to RT on PUT_VALUE unless it's part of a verified exchange.
      // await _tryAddSenderToRT(peer, 'handlePutValue');

      if (message.key == null) {
        _log.warning('$_logPrefix handlePutValue: PUT_VALUE message from $peerShortId missing key.');
        throw ArgumentError('PUT_VALUE message must have a key');
      }
      if (message.record == null) {
        _log.warning('$_logPrefix handlePutValue: PUT_VALUE message from $peerShortId missing record.');
        throw ArgumentError('PUT_VALUE message must have a record');
      }

      final response = Message(
        type: MessageType.putValue,
        key: message.key,
        // Record is not part of response for PUT_VALUE typically
      );

      try {
        final record = message.record!;
        _log.fine('$_logPrefix handlePutValue: Validating record for key $keyString from $peerShortId. Record author: ${PeerId.fromBytes(record.author).toBase58().substring(0,6)}');
        if (!await dht.validateRecord(record)) {
          _log.warning('$_logPrefix handlePutValue: Invalid record for key $keyString from $peerShortId. Validation failed.');
          throw ArgumentError('Invalid record');
        }
        _log.fine('$_logPrefix handlePutValue: Record for key $keyString from $peerShortId validated. Storing...');
        await dht.putRecordToDatastore(record);
        _log.info('$_logPrefix handlePutValue: Successfully stored record for key $keyString from $peerShortId.');
        return response;
      } catch (e, s) {
        _log.severe('$_logPrefix handlePutValue: Error processing PUT_VALUE from $peerShortId for key $keyString: $e\n$s');
        // Consider if an error response should be different or if this is okay (protocol might not specify error responses for PUT)
        return response;
      }
    }

    /// Handles a GET_PROVIDERS message
    Future<Message> handleGetProviders(PeerId peer, Message message) async {
      final peerShortId = peer.toBase58().substring(0,6);
      final keyString = message.key != null ? base64Encode(message.key!) : "null";
      _log.info('$_logPrefix handleGetProviders: Received GET_PROVIDERS from $peerShortId for key $keyString.');

      if (message.key == null) {
        _log.warning('$_logPrefix handleGetProviders: GET_PROVIDERS message from $peerShortId missing key.');
        throw ArgumentError('GET_PROVIDERS message must have a key');
      }

      final response = Message(
        type: MessageType.getProviders,
        key: message.key,
        closerPeers: [],
        providerPeers: [],
      );

      try {
        _log.finer('$_logPrefix handleGetProviders: Checking local provider store for key $keyString.');
        final providers = await dht.getLocalProviders(message.key!);
        if (providers.isNotEmpty) {
          _log.info('$_logPrefix handleGetProviders: Found ${providers.length} local provider(s) for key $keyString. Responding to $peerShortId.');
          for (final p in providers) {
            response.providerPeers.add(Peer(
              id: p.id.toBytes(),
              addrs: p.addrs.map((addr) => addr.toBytes()).toList(),
              connection: ConnectionType.connected, // Assuming if we know them, they are connectable
            ));
          }
          return response;
        }
        _log.fine('$_logPrefix handleGetProviders: No local providers for key $keyString. Finding closer peers.');

        final cid = CID.fromBytes(message.key!);
        final closestPeers = await dht.getClosestPeers(PeerId.fromBytes(cid.multihash)); // This uses routingTable.nearestPeers
        _log.fine('$_logPrefix handleGetProviders: Found ${closestPeers.length} closer peers for key $keyString.');

        for (final p in closestPeers) {
          response.closerPeers.add(Peer(
            id: p.id.toBytes(),
            addrs: p.addrs.map((addr) => addr.toBytes()).toList(),
            connection: ConnectionType.connected,
          ));
        }
        _log.info('$_logPrefix handleGetProviders: Responding to $peerShortId for key $keyString with ${response.closerPeers.length} closerPeers (no local providers).');

        // Defer sender RT insertion (non-blocking)
        _tryAddSenderToRT(peer, 'handleGetProviders').catchError((e) {
          _log.warning('$_logPrefix handleGetProviders: Deferred RT insertion failed: $e');
        });

        return response;
      } catch (e, s) {
        _log.severe('$_logPrefix handleGetProviders: Error processing GET_PROVIDERS from $peerShortId for key $keyString: $e\n$s');
        return response;
      }
    }

    /// Handles an ADD_PROVIDER message
    Future<Message> handleAddProvider(PeerId peer, Message message) async {
      final peerShortId = peer.toBase58().substring(0,6); // Peer who sent the ADD_PROVIDER msg
      final keyString = message.key != null ? base64Encode(message.key!) : "null";
      _log.info('$_logPrefix handleAddProvider: Received ADD_PROVIDER from $peerShortId for key $keyString.');

      if (message.key == null) {
        _log.warning('$_logPrefix handleAddProvider: ADD_PROVIDER message from $peerShortId missing key.');
        throw ArgumentError('ADD_PROVIDER message must have a key');
      }
      if (message.providerPeers.isEmpty) {
        _log.warning('$_logPrefix handleAddProvider: ADD_PROVIDER message from $peerShortId for key $keyString missing providerPeers.');
        throw ArgumentError('ADD_PROVIDER message must have provider peers');
      }

      final response = Message(
        type: MessageType.addProvider,
        key: message.key,
      );

      try {
        _log.fine('$_logPrefix handleAddProvider: Processing ${message.providerPeers.length} provider entries from $peerShortId for key $keyString.');
        for (final p in message.providerPeers) {
          final providerPeerId = PeerId.fromBytes(p.id);
          final providerShortId = providerPeerId.toBase58().substring(0,6);
          final providerAddrs = p.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList();
          _log.finer('$_logPrefix handleAddProvider: Adding provider $providerShortId (addrs: $providerAddrs) for key $keyString, as instructed by $peerShortId.');

          final providerPeerAddrInfo = AddrInfo(providerPeerId, providerAddrs);
          await dht.addProvider(message.key!, providerPeerAddrInfo);

          // Also try to add the actual provider peer to our routing table, not just the sender of ADD_PROVIDER
          // This is important if the provider peer itself didn't send the ADD_PROVIDER message.
          if (providerPeerId != peer) { // Avoid double-adding if sender is the provider
            _log.finer('$_logPrefix handleAddProvider: Also attempting to add actual provider $providerShortId to RT.');
            await _tryAddSenderToRT(providerPeerId, 'handleAddProvider (actual provider)');
          }
        }
        _log.info('$_logPrefix handleAddProvider: Successfully processed ADD_PROVIDER from $peerShortId for key $keyString.');
        // Defer sender RT insertion (non-blocking)
        _tryAddSenderToRT(peer, 'handleAddProvider').catchError((e) {
          _log.warning('$_logPrefix handleAddProvider: Deferred RT insertion failed: $e');
        });
        return response;
      } catch (e, s) {
        _log.severe('$_logPrefix handleAddProvider: Error processing ADD_PROVIDER from $peerShortId for key $keyString: $e\n$s');
        return response;
      }
    }
  }
