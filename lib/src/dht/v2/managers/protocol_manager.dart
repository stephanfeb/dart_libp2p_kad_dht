import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p_kad_dht/src/pb/dht_codec.dart';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:logging/logging.dart';
import '../../../internal/util.dart' show truncateForLog;

import '../../../record/namespace_validator.dart';
import '../../../record/value_record_store.dart';

import '../../../providers/provider_store.dart';
import '../../../pb/dht_message.dart';
import '../../../pb/dht_message_reader.dart';
import '../../../pb/record.dart';
import '../../../amino/defaults.dart';
import '../config/dht_config.dart';
import '../errors/dht_errors.dart';
import 'metrics_manager.dart';
import 'routing_manager.dart';
import '../../../providers/provider_key.dart';

/// Manages protocol message handling for DHT v2
/// 
/// This component handles:
/// - Protocol message processing
/// - Request/response handling
/// - Message validation
/// - Protocol-specific logic
class ProtocolManager {
  static final Logger _logger = Logger('ProtocolManager');
  
  final Host _host;
  
  // Configuration
  DHTConfigV2? _config;
  MetricsManager? _metrics;
  RoutingManager? _routing;
  ProviderStore? _providerStore;
  
  // State
  bool _started = false;
  bool _closed = false;
  
  // Local datastore for value records (validation, selection, expiry).
  final ValueRecordStore _records = ValueRecordStore();
  Timer? _pruneTimer;
  
  ProtocolManager(this._host);
  
  /// Initializes the protocol manager
  ///
  /// [validator] checks value records by key namespace (`/pk/`, `/ipns/`,
  /// ...). Without it, no namespace has a validator, and records are
  /// accepted only when [DHTConfigV2.allowUnvalidatedRecords] is set.
  void initialize({
    required RoutingManager routing,
    required ProviderStore providerStore,
    required DHTConfigV2 config,
    required MetricsManager metrics,
    NamespacedValidator? validator,
  }) {
    _routing = routing;
    _providerStore = providerStore;
    _config = config;
    _metrics = metrics;
    _records
      ..validator = validator
      ..maxRecordAge = config.maxRecordAge
      ..allowUnvalidatedRecords = config.allowUnvalidatedRecords;
  }
  
  /// Starts the protocol manager.
  /// When [serverMode] is false (client mode), protocol handlers are NOT
  /// registered — matching Go libp2p's ModeClient behaviour where the node
  /// does not serve incoming DHT queries.
  Future<void> start({bool serverMode = true}) async {
    if (_started || _closed) return;

    _logger.info('Starting ProtocolManager (serverMode=$serverMode)...');

    // Only register stream handlers in server mode
    if (serverMode) {
      _setupProtocolHandlers();
    }

    // Remove expired records periodically; reads also skip them.
    final pruneEvery = _records.pruneInterval;
    if (pruneEvery > Duration.zero) {
      _pruneTimer = Timer.periodic(pruneEvery, (_) => pruneExpiredRecords());
    }

    _started = true;
    _logger.info('ProtocolManager started');
  }
  
  /// Stops the protocol manager
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    
    _logger.info('Closing ProtocolManager...');

    _pruneTimer?.cancel();
    _pruneTimer = null;
    
    // The stream handler stays registered on close, as before: removing it
    // makes Identify push a protocol update to peers while the host may be
    // shutting down. Inbound requests after close fail with
    // DHTClosedException.
    
    _logger.info('ProtocolManager closed');
  }
  
  /// Whether the `/ipfs/kad/1.0.0` stream handler is registered, that is,
  /// whether this node answers DHT queries (server mode).
  bool get isServing => _serving;
  bool _serving = false;

  /// Registers the DHT stream handler (server mode). The host then
  /// advertises the protocol, and Identify pushes the change to connected
  /// peers. Does nothing if the handler is registered already.
  void enableServerMode() {
    if (_closed || _serving) return;
    _setupProtocolHandlers();
  }

  /// Removes the DHT stream handler (client mode), as go-libp2p-kad-dht does
  /// when it moves to client mode. Identify pushes the change to connected
  /// peers, which then remove this node from their routing tables. Does
  /// nothing if the handler is not registered.
  void disableServerMode() {
    if (!_serving) return;
    _removeProtocolHandlers();
  }

  /// Sets up protocol handlers for incoming messages
  void _setupProtocolHandlers() {
    _logger.info('Setting up protocol handlers for ${AminoConstants.protocolID}');
    _host.setStreamHandler(AminoConstants.protocolID, _handleIncomingStream);
    _serving = true;
  }
  
  /// Removes protocol handlers
  void _removeProtocolHandlers() {
    if (!_serving) return;
    _logger.info('Removing protocol handlers');
    _host.removeStreamHandler(AminoConstants.protocolID);
    _serving = false;
  }
  
  /// How long an inbound stream can wait for the next request before it is
  /// closed. The default is [AminoConstants.inboundStreamIdleTimeout]
  /// (1 minute, as go-libp2p-kad-dht).
  Duration inboundStreamIdleTimeout = AminoConstants.inboundStreamIdleTimeout;

  /// Handles an incoming protocol stream.
  ///
  /// As in go-libp2p-kad-dht, a peer can send several requests on one
  /// stream: the handler reads a message, writes the response (ADD_PROVIDER
  /// has none) and reads the next message. It closes the stream when the
  /// peer ends it or sends nothing for [inboundStreamIdleTimeout]. It resets
  /// the stream when a message is not valid, a request fails, or a read or
  /// write fails.
  Future<void> _handleIncomingStream(P2PStream stream, PeerId remotePeer) async {
    final remotePeerShortId = truncateForLog(remotePeer.toBase58(), 6);
    final selfShortId = truncateForLog(_host.id.toBase58(), 6);

    _logger.info('[$selfShortId] Handling incoming stream from $remotePeerShortId');

    // Capture address (cheap, no I/O)
    MultiAddr? remoteAddr;
    try {
      remoteAddr = stream.conn.remoteMultiaddr;
    } catch (e) {
      _logger.fine('[$selfShortId] Could not extract remote address for $remotePeerShortId: $e');
    }

    final reader = DhtMessageReader(stream);
    var handled = 0;
    var clean = true;
    try {
      while (true) {
        final Message? message;
        try {
          message = await reader.next(timeout: inboundStreamIdleTimeout);
        } on TimeoutException {
          _logger.fine('[$selfShortId] Stream from $remotePeerShortId idle after $handled request(s); closing');
          break;
        }
        if (message == null) {
          _logger.fine('[$selfShortId] Stream from $remotePeerShortId ended after $handled request(s)');
          break;
        }

        _logger.fine('[$selfShortId] Received ${message.type} message from $remotePeerShortId');

        // Route the message to the appropriate handler
        final response = await _routeMessage(remotePeer, message);
        handled++;

        // ADD_PROVIDER is fire-and-forget per the libp2p spec — no response sent
        if (message.type != MessageType.addProvider) {
          await stream.write(encodeMessage(response));
          _logger.fine('[$selfShortId] Sent response to $remotePeerShortId');
        } else {
          _logger.fine('[$selfShortId] ADD_PROVIDER handled (fire-and-forget, no response)');
        }

        // Store the address once, after the first response (non-blocking)
        if (handled == 1 && remoteAddr != null) {
          _host.peerStore.addOrUpdatePeer(remotePeer, addrs: [remoteAddr]).catchError((e) {
            _logger.fine('[$selfShortId] Failed to store address for peer $remotePeerShortId: $e');
          });
        }
      }
    } catch (e, stackTrace) {
      clean = false;
      _logger.fine('[$selfShortId] Error handling stream from $remotePeerShortId: $e', e, stackTrace);
    }

    // The peer may have closed or reset the stream already; that is fine.
    try {
      if (clean) {
        await stream.close();
      } else {
        await stream.reset();
      }
    } catch (e) {
      _logger.fine('[$selfShortId] Failed to end stream from $remotePeerShortId: $e');
    }
  }
  
  /// Routes a message to the appropriate handler
  Future<Message> _routeMessage(PeerId sender, Message message) async {
    switch (message.type) {
      case MessageType.ping:
        return await handlePing(sender, message);
      case MessageType.findNode:
        return await handleFindNode(sender, message);
      case MessageType.getValue:
        return await handleGetValue(sender, message);
      case MessageType.putValue:
        return await handlePutValue(sender, message);
      case MessageType.getProviders:
        return await handleGetProviders(sender, message);
      case MessageType.addProvider:
        return await handleAddProvider(sender, message);
      default:
        _logger.fine('Unknown message type: ${message.type}');
        throw DHTProtocolException('Unknown message type: ${message.type}', peerId: sender);
    }
  }
  
  /// Creates peer list with addresses populated from peerstore
  /// Uses parallel lookups for all peers to minimize latency
  Future<List<Peer>> _createPeerListWithAddresses(List<PeerId> peerIds) async {
    // Parallel peerstore lookups instead of sequential
    final peerInfoFutures = peerIds.map((peerId) =>
      _host.peerStore.getPeer(peerId).catchError((e) {
        _logger.fine('Failed to get addresses for peer ${peerId.toBase58().substring(0, 6)}: $e');
        return null;
      })
    ).toList();
    final peerInfoResults = await Future.wait(peerInfoFutures);

    final result = <Peer>[];
    for (var i = 0; i < peerIds.length; i++) {
      final peerId = peerIds[i];
      final addresses = peerInfoResults[i]?.addrs.map((addr) => addr.toBytes()).toList() ?? <Uint8List>[];

      result.add(Peer(
        id: peerId.toBytes(),
        addrs: addresses,
        connection: ConnectionType.notConnected,
      ));
    }

    return result;
  }

  /// Handles a FIND_NODE message
  Future<Message> handleFindNode(PeerId sender, Message message) async {
    _ensureStarted();

    final senderShortId = sender.toBase58().substring(0, 6);
    _logger.info('Handling FIND_NODE from $senderShortId');

    try {
      if (message.key == null) {
        throw DHTProtocolException('FIND_NODE message missing key', peerId: sender);
      }

      // Find closest peers
      final closestPeers = await _routing?.getNearestPeers(message.key!, _config?.bucketSize ?? 20) ?? [];

      // Create response (parallel peerstore lookups inside)
      final response = Message(
        type: MessageType.findNode,
        key: message.key,
        closerPeers: await _createPeerListWithAddresses(closestPeers),
      );

      _logger.fine('Responding to FIND_NODE with ${response.closerPeers.length} peers');

      // Defer sender RT insertion (non-blocking)
      _routing?.addPeerIfServer(sender, queryPeer: true, isReplaceable: true).catchError((e) {
        _logger.fine('Deferred RT insertion failed for $senderShortId: $e');
        return false;
      });

      return response;
    } catch (e) {
      _logger.fine('Error handling FIND_NODE: $e');
      throw DHTProtocolException('Failed to handle FIND_NODE: $e', peerId: sender, cause: e);
    }
  }
  
  /// Handles a GET_VALUE message
  Future<Message> handleGetValue(PeerId sender, Message message) async {
    _ensureStarted();

    final senderShortId = sender.toBase58().substring(0, 6);
    _logger.info('Handling GET_VALUE from $senderShortId');

    try {
      if (message.key == null) {
        throw DHTProtocolException('GET_VALUE message missing key', peerId: sender);
      }

      // Check local datastore for the record
      final keyString = String.fromCharCodes(message.key!);
      final localRecord = _liveRecord(keyString);

      // Get closer peers from routing table (parallel peerstore lookups inside)
      final closestPeers = await _routing?.getNearestPeers(message.key!, _config?.bucketSize ?? 20) ?? [];
      final closerPeers = await _createPeerListWithAddresses(closestPeers);

      final response = Message(
        type: MessageType.getValue,
        key: message.key,
        record: localRecord,
        closerPeers: closerPeers,
      );

      if (localRecord != null) {
        _logger.fine('Responding to GET_VALUE with record and ${closerPeers.length} closer peers');
      } else {
        _logger.fine('Responding to GET_VALUE with ${closerPeers.length} closer peers (no local record)');
      }

      // Defer sender RT insertion (non-blocking)
      _routing?.addPeerIfServer(sender, queryPeer: true, isReplaceable: true).catchError((e) {
        _logger.fine('Deferred RT insertion failed for $senderShortId: $e');
        return false;
      });

      return response;
    } catch (e) {
      _logger.fine('Error handling GET_VALUE: $e');
      throw DHTProtocolException('Failed to handle GET_VALUE: $e', peerId: sender, cause: e);
    }
  }
  
  /// Handles a PUT_VALUE message
  Future<Message> handlePutValue(PeerId sender, Message message) async {
    _ensureStarted();

    final senderShortId = sender.toBase58().substring(0, 6);
    _logger.info('Handling PUT_VALUE from $senderShortId');

    try {
      if (message.key == null || message.record == null) {
        throw DHTProtocolException('PUT_VALUE message missing key or record', peerId: sender);
      }
      
      final record = message.record!;
      final keyString = String.fromCharCodes(message.key!);

      // The record must be for the key of the message (go-libp2p-kad-dht
      // checks this too), and it must pass the validator of its namespace.
      if (!_bytesEqual(record.key, message.key!)) {
        throw DHTProtocolException('PUT_VALUE record key does not match message key', peerId: sender);
      }
      // Keep the better of the stored and the received record, as the
      // validator's select() decides (not a writer-chosen timestamp).
      try {
        final stored = await _records.put(keyString, record);
        _logger.fine(stored
            ? 'Stored record from $senderShortId for key ${truncateForLog(keyString)}...'
            : 'Keeping stored record for key ${truncateForLog(keyString)}...: '
                'the record from $senderShortId is not better');
      } catch (e) {
        _logger.fine('Refusing record from $senderShortId for key ${truncateForLog(keyString)}...: $e');
        rethrow;
      }
      
      // The response echoes the request with its record, as
      // go-libp2p-kad-dht does; its client checks that the value came back.
      final response = Message(
        type: MessageType.putValue,
        key: message.key,
        record: record,
      );

      // Defer sender RT insertion (non-blocking)
      _routing?.addPeerIfServer(sender, queryPeer: true, isReplaceable: true).catchError((e) {
        _logger.fine('Deferred RT insertion failed for $senderShortId: $e');
        return false;
      });

      return response;
    } catch (e) {
      _logger.fine('Error handling PUT_VALUE: $e');
      throw DHTProtocolException('Failed to handle PUT_VALUE: $e', peerId: sender, cause: e);
    }
  }
  
  /// Handles a GET_PROVIDERS message
  Future<Message> handleGetProviders(PeerId sender, Message message) async {
    _ensureStarted();

    final senderShortId = sender.toBase58().substring(0, 6);
    _logger.info('Handling GET_PROVIDERS from $senderShortId');

    try {
      if (message.key == null) {
        throw DHTProtocolException('GET_PROVIDERS message missing key', peerId: sender);
      }
      
      // Get providers from local provider store. The key is a multihash;
      // older Dart peers send CID bytes, which reduce to the same key.
      final key = providerKeyFromWire(message.key!);
      final providers = await _providerStore?.getProviders(cidForProviderKey(key)) ?? [];
      
      // Convert providers to protocol format
      final providerPeers = providers.map((provider) => Peer(
        id: provider.id.toBytes(),
        addrs: provider.addrs.map((addr) => addr.toBytes()).toList(),
        connection: ConnectionType.notConnected,
      )).toList();
      
      // Get closer peers from routing table
      final closestPeers = await _routing?.getNearestPeers(key, _config?.bucketSize ?? 20) ?? [];
      final closerPeers = await _createPeerListWithAddresses(closestPeers);
      
      final response = Message(
        type: MessageType.getProviders,
        key: message.key,
        providerPeers: providerPeers,
        closerPeers: closerPeers,
      );
      
      _logger.fine('Responding to GET_PROVIDERS with ${providerPeers.length} providers and ${closerPeers.length} closer peers');

      // Defer sender RT insertion (non-blocking)
      _routing?.addPeerIfServer(sender, queryPeer: true, isReplaceable: true).catchError((e) {
        _logger.fine('Deferred RT insertion failed for $senderShortId: $e');
        return false;
      });

      return response;
    } catch (e) {
      _logger.fine('Error handling GET_PROVIDERS: $e');
      throw DHTProtocolException('Failed to handle GET_PROVIDERS: $e', peerId: sender, cause: e);
    }
  }
  
  /// Handles an ADD_PROVIDER message
  Future<Message> handleAddProvider(PeerId sender, Message message) async {
    _ensureStarted();

    final senderShortId = sender.toBase58().substring(0, 6);
    _logger.info('Handling ADD_PROVIDER from $senderShortId');

    try {
      if (message.key == null || message.providerPeers.isEmpty) {
        throw DHTProtocolException('ADD_PROVIDER message missing key or providers', peerId: sender);
      }
      
      // Store the sender's own provider record only. As in go-libp2p-kad-dht,
      // a peer can announce itself as a provider, but not other peers:
      // entries whose ID is not the sender's are ignored.
      final cid = cidForProviderKey(providerKeyFromWire(message.key!));
      var storedCount = 0;

      for (final providerPeer in message.providerPeers) {
        try {
          final providerId = PeerId.fromBytes(providerPeer.id);
          if (providerId != sender) {
            _logger.fine('Ignoring provider entry for ${providerId.toBase58().substring(0, 6)} '
                'from $senderShortId: a peer can only add itself as a provider');
            continue;
          }
          final providerAddrs = providerPeer.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList();
          await _providerStore?.addProvider(cid, AddrInfo(providerId, providerAddrs));
          storedCount++;
          _logger.fine('Stored provider record of $senderShortId for key');
        } catch (e) {
          _logger.fine('Failed to store provider record of $senderShortId: $e');
        }
      }

      _logger.fine('Stored $storedCount/${message.providerPeers.length} provider entries');

      // Create response
      final response = Message(
        type: MessageType.addProvider,
        key: message.key,
      );

      // Defer sender RT insertion (non-blocking)
      _routing?.addPeerIfServer(sender, queryPeer: true, isReplaceable: true).catchError((e) {
        _logger.fine('Deferred RT insertion failed for $senderShortId: $e');
        return false;
      });

      return response;
    } catch (e) {
      _logger.fine('Error handling ADD_PROVIDER: $e');
      throw DHTProtocolException('Failed to handle ADD_PROVIDER: $e', peerId: sender, cause: e);
    }
  }
  
  /// Handles a PING message
  Future<Message> handlePing(PeerId sender, Message message) async {
    _ensureStarted();

    final senderShortId = sender.toBase58().substring(0, 6);
    _logger.fine('Handling PING from $senderShortId');

    // Defer RT insertion (non-blocking) — respond to ping as fast as possible
    _routing?.addPeerIfServer(sender, queryPeer: true, isReplaceable: true).catchError((e) {
      _logger.fine('Deferred RT insertion failed for $senderShortId: $e');
      return false;
    });

    return Message(type: MessageType.ping);
  }
  
  // Record validation and selection: the rules live in ValueRecordStore,
  // which the legacy IpfsDHT uses too.

  /// Checks a value record for [key].
  ///
  /// - The record's key must be [key].
  /// - If the record carries an author or a signature, the signature must be
  ///   valid.
  /// - If the key's namespace has a validator, the validator must accept the
  ///   value.
  /// - If it has none, the record is refused, unless
  ///   [DHTConfigV2.allowUnvalidatedRecords] is set (or [requireValidator]
  ///   is false); then the record must be signed by its author.
  ///
  /// Throws a [DHTProtocolException] when the record is not valid.
  Future<void> validateRecord(String key, Record record, {bool requireValidator = true}) =>
      _records.validateRecord(key, record, requireValidator: requireValidator);

  /// Returns the index of the best record in [records] for [key].
  ///
  /// With a namespace validator, its `select()` decides. Without one (see
  /// [DHTConfigV2.allowUnvalidatedRecords]), the author with the most
  /// records wins, ties going to the author of the earliest record in the
  /// list (callers put the local record first), and then the newest record
  /// of that author wins.
  Future<int> selectRecord(String key, List<Record> records) =>
      _records.selectRecord(key, records);

  /// Returns the stored record for [key], or null when there is none or it
  /// is older than the maximum record age (it is then removed).
  Record? _liveRecord(String key) => _records.get(key);

  /// Removes the records that are older than the maximum record age
  /// ([DHTConfigV2.maxRecordAge], default 36 hours). Returns how many were
  /// removed. This runs periodically; reads also skip expired records.
  int pruneExpiredRecords() => _records.pruneExpired();

  static bool _bytesEqual(List<int> a, List<int> b) => ValueRecordStore.bytesEqual(a, b);

  // Public datastore interface methods
  
  /// Gets a record from the local datastore
  Future<Record?> getRecordFromDatastore(String key) async {
    _ensureStarted();
    final record = _liveRecord(key);
    if (record != null) {
      _logger.fine('Retrieved record from datastore for key: ${truncateForLog(key)}...');
      // Use existing metrics method
      _metrics?.recordQuerySuccess(Duration.zero);
    }
    return record;
  }
  
  /// Gets a record from the local datastore using byte key
  Future<Record?> getRecordFromDatastoreBytes(Uint8List keyBytes) async {
    // Keys are stored with one character per byte (as PUT_VALUE and
    // putValue build them), not UTF-8 decoded.
    return await getRecordFromDatastore(String.fromCharCodes(keyBytes));
  }
  
  /// Puts a record into the local datastore
  ///
  /// This is a local write: the record's signature (if any) and the
  /// validator of the key's namespace (if any) are checked, but a key
  /// without a validator is not refused. A stored record is replaced only if
  /// the new record is better (see [selectRecord]); without a validator,
  /// only a newer record of the same author replaces it.
  Future<void> putRecordToDatastore(String key, Record record) async {
    _ensureStarted();
    if (!await _records.putLocal(key, record)) {
      _logger.fine('Keeping stored record for key: ${truncateForLog(key)}...');
      return;
    }
    // Use existing metrics method
    _metrics?.recordQuerySuccess(Duration.zero);
    _logger.fine('Stored record in datastore for key: ${truncateForLog(key)}...');
  }
  
  /// Puts a record into the local datastore using dynamic record
  Future<void> putRecordToDatastoreDynamic(dynamic record) async {
    if (record is! Record) {
      throw DHTProtocolException('Invalid record type: expected Record, got ${record.runtimeType}');
    }
    
    final keyString = String.fromCharCodes(record.key);
    if (keyString.isEmpty) {
      throw DHTProtocolException('Record missing key field');
    }
    
    await putRecordToDatastore(keyString, record);
  }
  
  /// Checks if a record exists in the local datastore
  Future<bool> hasRecordInDatastore(String key) async {
    _ensureStarted();
    final hasRecord = _liveRecord(key) != null;
    _logger.fine('Datastore contains key ${truncateForLog(key)}...: $hasRecord');
    return hasRecord;
  }
  
  /// Removes a record from the local datastore
  Future<void> removeRecordFromDatastore(String key) async {
    _ensureStarted();
    if (_records.remove(key)) {
      // Use existing metrics method
      _metrics?.recordQuerySuccess(Duration.zero);
      _logger.fine('Removed record from datastore for key: ${truncateForLog(key)}...');
    }
  }
  
  /// Gets all keys from the local datastore
  Stream<String> getKeysFromDatastore() async* {
    _ensureStarted();
    final keys = _records.keys;
    _logger.fine('Getting all keys from datastore (${keys.length} keys)');
    
    for (final key in keys) {
      yield key;
    }
  }
  
  /// Gets the current size of the local datastore
  Future<int> getDatastoreSize() async {
    _ensureStarted();
    return _records.length;
  }
  
  /// Clears all records from the local datastore
  Future<void> clearDatastore() async {
    _ensureStarted();
    final count = _records.clear();
    _logger.info('Cleared datastore (removed $count records)');
  }
  
  /// Gets datastore statistics
  Future<Map<String, dynamic>> getDatastoreStatistics() async {
    _ensureStarted();
    final records = _records.records;
    
    final stats = <String, dynamic>{
      'total_records': records.length,
      'total_size_bytes': records.fold<int>(0, (sum, record) => sum + record.value.length),
      'oldest_record_timestamp': records.isEmpty ? null : records.map((r) => r.timeReceived).reduce((a, b) => a < b ? a : b),
      'newest_record_timestamp': records.isEmpty ? null : records.map((r) => r.timeReceived).reduce((a, b) => a > b ? a : b),
    };
    
    return stats;
  }
  
  /// Ensures the protocol manager is started
  void _ensureStarted() {
    if (_closed) throw DHTClosedException();
    if (!_started) throw DHTNotStartedException();
  }
  
  @override
  String toString() => 'ProtocolManager(${_host.id.toBase58().substring(0, 6)})';
}
