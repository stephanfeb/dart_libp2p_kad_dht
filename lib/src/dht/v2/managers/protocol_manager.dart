import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_libp2p_kad_dht/src/pb/dht_codec.dart';

import 'package:dcid/dcid.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:logging/logging.dart';

import '../../../record/record_signer.dart';

import '../../../providers/provider_store.dart';
import '../../../pb/dht_message.dart';
import '../../../pb/record.dart';
import '../../../amino/defaults.dart';
import '../config/dht_config.dart';
import '../errors/dht_errors.dart';
import 'metrics_manager.dart';
import 'routing_manager.dart';

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
  
  // Local datastore for records
  final Map<String, Record> _datastore = {};
  
  ProtocolManager(this._host);
  
  /// Initializes the protocol manager
  void initialize({
    required RoutingManager routing,
    required ProviderStore providerStore,
    required DHTConfigV2 config,
    required MetricsManager metrics,
  }) {
    _routing = routing;
    _providerStore = providerStore;
    _config = config;
    _metrics = metrics;
  }
  
  /// Starts the protocol manager
  Future<void> start() async {
    if (_started || _closed) return;
    
    _logger.info('Starting ProtocolManager...');
    
    // Set up protocol handlers
    _setupProtocolHandlers();
    
    _started = true;
    _logger.info('ProtocolManager started');
  }
  
  /// Stops the protocol manager
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    
    _logger.info('Closing ProtocolManager...');
    
    // Remove protocol handlers
    _removeProtocolHandlers();
    
    _logger.info('ProtocolManager closed');
  }
  
  /// Sets up protocol handlers for incoming messages
  void _setupProtocolHandlers() {
    _logger.info('Setting up protocol handlers for ${AminoConstants.protocolID}');
    _host.setStreamHandler(AminoConstants.protocolID, _handleIncomingStream);
  }
  
  /// Removes protocol handlers
  void _removeProtocolHandlers() {
    _logger.info('Removing protocol handlers');
    // Note: Host interface might not have removeStreamHandler method
    // This is typically handled by the host's cleanup during shutdown
  }
  
  /// Handles incoming protocol streams
  Future<void> _handleIncomingStream(P2PStream stream, PeerId remotePeer) async {
    final remotePeerShortId = remotePeer.toBase58().substring(0, 6);
    final selfShortId = _host.id.toBase58().substring(0, 6);
    
    _logger.info('[$selfShortId] Handling incoming stream from $remotePeerShortId');
    
    try {
      // CRITICAL FIX: Capture address information from connecting peer
      // This is how bootstrap servers collect address info!
      try {
        final connection = stream.conn;
        final remoteAddr = connection.remoteMultiaddr;
        // Store the peer's address in peerstore
        await _host.peerStore.addOrUpdatePeer(
          remotePeer, 
          addrs: [remoteAddr]
        );
        _logger.fine('[$selfShortId] Stored address $remoteAddr for peer $remotePeerShortId');
      } catch (e) {
        _logger.warning('[$selfShortId] Failed to store address for peer $remotePeerShortId: $e');
        // Continue processing - address capture failure shouldn't block protocol handling
      }
      
      // Read the message from the stream
      final messageBytes = await stream.read();
      
      // Parse the protobuf message
      final message = decodeMessage(Uint8List.fromList(messageBytes));

      _logger.fine('[$selfShortId] Received ${message.type} message from $remotePeerShortId');

      // Route the message to the appropriate handler
      final response = await _routeMessage(remotePeer, message);

      // ADD_PROVIDER is fire-and-forget per the libp2p spec — no response sent
      if (message.type != MessageType.addProvider) {
        final responseBytes = encodeMessage(response);
        await stream.write(responseBytes);
        _logger.fine('[$selfShortId] Sent response to $remotePeerShortId');
      } else {
        _logger.fine('[$selfShortId] ADD_PROVIDER handled (fire-and-forget, no response)');
      }
      
    } catch (e, stackTrace) {
      _logger.severe('[$selfShortId] Error handling stream from $remotePeerShortId: $e', e, stackTrace);
      
      // Send error response if possible
      try {
        final errorResponse = Message(type: MessageType.ping); // Default error response
        final errorResponseBytes = encodeMessage(errorResponse);
        await stream.write(errorResponseBytes);
      } catch (responseError) {
        _logger.warning('[$selfShortId] Failed to send error response: $responseError');
      }
    } finally {
      // NOTE: Don't close the stream here! 
      // The client (NetworkManager) will close it to avoid race conditions.
      // Server-side should not close streams initiated by clients.
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
        _logger.warning('Unknown message type: ${message.type}');
        throw DHTProtocolException('Unknown message type: ${message.type}', peerId: sender);
    }
  }
  
  /// Creates peer list with addresses populated from peerstore
  Future<List<Peer>> _createPeerListWithAddresses(List<PeerId> peerIds) async {
    final result = <Peer>[];
    
    for (final peerId in peerIds) {
      try {
        // Look up addresses from peerstore
        final peerInfo = await _host.peerStore.getPeer(peerId);
        final addresses = peerInfo?.addrs.map((addr) => addr.toBytes()).toList() ?? <Uint8List>[];
        
        result.add(Peer(
          id: peerId.toBytes(),
          addrs: addresses, // CRITICAL FIX: Actually populate addresses from peerstore!
          connection: ConnectionType.notConnected,
        ));
        
        if (addresses.isNotEmpty) {
          _logger.finest('Including peer ${peerId.toBase58().substring(0, 6)} with ${addresses.length} addresses');
        } else {
          _logger.finest('Including peer ${peerId.toBase58().substring(0, 6)} with no known addresses');
        }
      } catch (e) {
        _logger.warning('Failed to get addresses for peer ${peerId.toBase58().substring(0, 6)}: $e');
        // Still include the peer but without addresses
        result.add(Peer(
          id: peerId.toBytes(),
          addrs: [],
          connection: ConnectionType.notConnected,
        ));
      }
    }
    
    return result;
  }

  /// Handles a FIND_NODE message
  Future<Message> handleFindNode(PeerId sender, Message message) async {
    _ensureStarted();
    
    final senderShortId = sender.toBase58().substring(0, 6);
    _logger.info('Handling FIND_NODE from $senderShortId');
    
    try {
      // Add sender to routing table
      await _routing?.addPeer(sender, queryPeer: true, isReplaceable: true);
      
      if (message.key == null) {
        throw DHTProtocolException('FIND_NODE message missing key', peerId: sender);
      }
      
      // Find closest peers
      final closestPeers = await _routing?.getNearestPeers(message.key!, _config?.bucketSize ?? 20) ?? [];
      
      // Create response
      final response = Message(
        type: MessageType.findNode,
        key: message.key,
        closerPeers: await _createPeerListWithAddresses(closestPeers),
      );
      
      _logger.fine('Responding to FIND_NODE with ${response.closerPeers.length} peers');
      return response;
    } catch (e) {
      _logger.warning('Error handling FIND_NODE: $e');
      throw DHTProtocolException('Failed to handle FIND_NODE: $e', peerId: sender, cause: e);
    }
  }
  
  /// Handles a GET_VALUE message
  Future<Message> handleGetValue(PeerId sender, Message message) async {
    _ensureStarted();
    
    final senderShortId = sender.toBase58().substring(0, 6);
    _logger.info('Handling GET_VALUE from $senderShortId');
    
    try {
      // Add sender to routing table (important for bootstrap servers to collect peer info)
      await _routing?.addPeer(sender, queryPeer: true, isReplaceable: true);
      
      if (message.key == null) {
        throw DHTProtocolException('GET_VALUE message missing key', peerId: sender);
      }
      
      // Check local datastore for the record
      final keyString = String.fromCharCodes(message.key!);
      final localRecord = _datastore[keyString];
      
      // Get closer peers from routing table
      final closestPeers = await _routing?.getNearestPeers(message.key!, _config?.bucketSize ?? 20) ?? [];
      final closerPeers = await _createPeerListWithAddresses(closestPeers);
      
      final response = Message(
        type: MessageType.getValue,
        key: message.key,
        record: localRecord, // Include the record if found
        closerPeers: closerPeers,
      );
      
      if (localRecord != null) {
        _logger.fine('Responding to GET_VALUE with record and ${closerPeers.length} closer peers');
      } else {
        _logger.fine('Responding to GET_VALUE with ${closerPeers.length} closer peers (no local record)');
      }
      
      return response;
    } catch (e) {
      _logger.warning('Error handling GET_VALUE: $e');
      throw DHTProtocolException('Failed to handle GET_VALUE: $e', peerId: sender, cause: e);
    }
  }
  
  /// Handles a PUT_VALUE message
  Future<Message> handlePutValue(PeerId sender, Message message) async {
    _ensureStarted();
    
    final senderShortId = sender.toBase58().substring(0, 6);
    _logger.info('Handling PUT_VALUE from $senderShortId');
    
    try {
      // Add sender to routing table
      await _routing?.addPeer(sender, queryPeer: true, isReplaceable: true);
      
      if (message.key == null || message.record == null) {
        throw DHTProtocolException('PUT_VALUE message missing key or record', peerId: sender);
      }
      
      // Validate the record signature
      final record = message.record!;
      final keyString = String.fromCharCodes(message.key!);
      
      _logger.fine('Validating record signature for key: ${keyString.substring(0, 10)}...');
      
      final isValid = await RecordSigner.validateRecordSignature(record);
      if (!isValid) {
        _logger.warning('Invalid record signature from $senderShortId for key: ${keyString.substring(0, 10)}...');
        throw DHTProtocolException('Invalid record signature', peerId: sender);
      }
      
      // Check if this is a newer record than what we have
      final existingRecord = _datastore[keyString];
      if (existingRecord != null) {
        if (record.timeReceived <= existingRecord.timeReceived) {
          _logger.fine('Rejecting older record from $senderShortId for key: ${keyString.substring(0, 10)}...');
          // Still return success - we just don't store the older record
        } else {
          _logger.fine('Accepting newer record from $senderShortId for key: ${keyString.substring(0, 10)}...');
          _datastore[keyString] = record;
        }
      } else {
        _logger.fine('Storing new record from $senderShortId for key: ${keyString.substring(0, 10)}...');
        _datastore[keyString] = record;
      }
      
      // Create response
      final response = Message(
        type: MessageType.putValue,
        key: message.key,
      );
      
      return response;
    } catch (e) {
      _logger.warning('Error handling PUT_VALUE: $e');
      throw DHTProtocolException('Failed to handle PUT_VALUE: $e', peerId: sender, cause: e);
    }
  }
  
  /// Handles a GET_PROVIDERS message
  Future<Message> handleGetProviders(PeerId sender, Message message) async {
    _ensureStarted();
    
    final senderShortId = sender.toBase58().substring(0, 6);
    _logger.info('Handling GET_PROVIDERS from $senderShortId');
    
    try {
      // Add sender to routing table
      await _routing?.addPeer(sender, queryPeer: true, isReplaceable: true);
      
      if (message.key == null) {
        throw DHTProtocolException('GET_PROVIDERS message missing key', peerId: sender);
      }
      
      // Get providers from local provider store
      final cid = CID.fromBytes(message.key!);
      final providers = await _providerStore?.getProviders(cid) ?? [];
      
      // Convert providers to protocol format
      final providerPeers = providers.map((provider) => Peer(
        id: provider.id.toBytes(),
        addrs: provider.addrs.map((addr) => addr.toBytes()).toList(),
        connection: ConnectionType.notConnected,
      )).toList();
      
      // Get closer peers from routing table
      final closestPeers = await _routing?.getNearestPeers(message.key!, _config?.bucketSize ?? 20) ?? [];
      final closerPeers = await _createPeerListWithAddresses(closestPeers);
      
      final response = Message(
        type: MessageType.getProviders,
        key: message.key,
        providerPeers: providerPeers,
        closerPeers: closerPeers,
      );
      
      _logger.fine('Responding to GET_PROVIDERS with ${providerPeers.length} providers and ${closerPeers.length} closer peers');
      return response;
    } catch (e) {
      _logger.warning('Error handling GET_PROVIDERS: $e');
      throw DHTProtocolException('Failed to handle GET_PROVIDERS: $e', peerId: sender, cause: e);
    }
  }
  
  /// Handles an ADD_PROVIDER message
  Future<Message> handleAddProvider(PeerId sender, Message message) async {
    _ensureStarted();
    
    final senderShortId = sender.toBase58().substring(0, 6);
    _logger.info('Handling ADD_PROVIDER from $senderShortId');
    
    try {
      // Add sender to routing table
      await _routing?.addPeer(sender, queryPeer: true, isReplaceable: true);
      
      if (message.key == null || message.providerPeers.isEmpty) {
        throw DHTProtocolException('ADD_PROVIDER message missing key or providers', peerId: sender);
      }
      
      // Store providers in local provider store
      final cid = CID.fromBytes(message.key!);
      var storedCount = 0;
      
      for (final providerPeer in message.providerPeers) {
        try {
          final providerId = PeerId.fromBytes(providerPeer.id);
          final providerAddrs = providerPeer.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList();
          final providerInfo = AddrInfo(providerId, providerAddrs);
          
          await _providerStore?.addProvider(cid, providerInfo);
          storedCount++;
          
          _logger.fine('Stored provider ${providerId.toBase58().substring(0, 6)} for key');
        } catch (e) {
          _logger.warning('Failed to store provider: $e');
        }
      }
      
      _logger.fine('Stored $storedCount/${message.providerPeers.length} providers');
      
      // Create response
      final response = Message(
        type: MessageType.addProvider,
        key: message.key,
      );
      
      return response;
    } catch (e) {
      _logger.warning('Error handling ADD_PROVIDER: $e');
      throw DHTProtocolException('Failed to handle ADD_PROVIDER: $e', peerId: sender, cause: e);
    }
  }
  
  /// Handles a PING message
  Future<Message> handlePing(PeerId sender, Message message) async {
    _ensureStarted();
    
    final senderShortId = sender.toBase58().substring(0, 6);
    _logger.fine('Handling PING from $senderShortId');
    
    try {
      // Add sender to routing table
      await _routing?.addPeer(sender, queryPeer: true, isReplaceable: true);
      
      // Create response
      final response = Message(type: MessageType.ping);
      
      return response;
    } catch (e) {
      _logger.warning('Error handling PING: $e');
      throw DHTProtocolException('Failed to handle PING: $e', peerId: sender, cause: e);
    }
  }
  
  // Public datastore interface methods
  
  /// Gets a record from the local datastore
  Future<Record?> getRecordFromDatastore(String key) async {
    _ensureStarted();
    final record = _datastore[key];
    if (record != null) {
      _logger.fine('Retrieved record from datastore for key: ${key}...');
      // Use existing metrics method
      _metrics?.recordQuerySuccess(Duration.zero);
    }
    return record;
  }
  
  /// Gets a record from the local datastore using byte key
  Future<Record?> getRecordFromDatastoreBytes(Uint8List keyBytes) async {
    final keyString = utf8.decode(keyBytes);
    return await getRecordFromDatastore(keyString);
  }
  
  /// Puts a record into the local datastore
  Future<void> putRecordToDatastore(String key, Record record) async {
    _ensureStarted();
    
    // Validate the record signature before storing
    final isValid = await RecordSigner.validateRecordSignature(record);
    if (!isValid) {
      throw DHTProtocolException('Cannot store record with invalid signature');
    }
    
    // Check if this is a newer record than what we have
    final existingRecord = _datastore[key];
    if (existingRecord != null) {
      if (record.timeReceived <= existingRecord.timeReceived) {
        _logger.fine('Rejecting older record for key: ${key}...');
        return; // Don't store older records
      }
    }
    
    _datastore[key] = record;
    // Use existing metrics method
    _metrics?.recordQuerySuccess(Duration.zero);
    _logger.fine('Stored record in datastore for key: ${key}...');
  }
  
  /// Puts a record into the local datastore using dynamic record
  Future<void> putRecordToDatastoreDynamic(dynamic record) async {
    if (record is! Record) {
      throw DHTProtocolException('Invalid record type: expected Record, got ${record.runtimeType}');
    }
    
    // Extract key from record - this assumes the record has a key field
    // In a real implementation, you'd need to determine the key from the record
    final keyString = String.fromCharCodes(record.key ?? Uint8List(0));
    if (keyString.isEmpty) {
      throw DHTProtocolException('Record missing key field');
    }
    
    await putRecordToDatastore(keyString, record as Record);
  }
  
  /// Checks if a record exists in the local datastore
  Future<bool> hasRecordInDatastore(String key) async {
    _ensureStarted();
    final hasRecord = _datastore.containsKey(key);
    _logger.fine('Datastore contains key ${key}...: $hasRecord');
    return hasRecord;
  }
  
  /// Removes a record from the local datastore
  Future<void> removeRecordFromDatastore(String key) async {
    _ensureStarted();
    final removed = _datastore.remove(key);
    if (removed != null) {
      // Use existing metrics method
      _metrics?.recordQuerySuccess(Duration.zero);
      _logger.fine('Removed record from datastore for key: ${key}...');
    }
  }
  
  /// Gets all keys from the local datastore
  Stream<String> getKeysFromDatastore() async* {
    _ensureStarted();
    _logger.fine('Getting all keys from datastore (${_datastore.length} keys)');
    
    for (final key in _datastore.keys) {
      yield key;
    }
  }
  
  /// Gets the current size of the local datastore
  Future<int> getDatastoreSize() async {
    _ensureStarted();
    return _datastore.length;
  }
  
  /// Clears all records from the local datastore
  Future<void> clearDatastore() async {
    _ensureStarted();
    final count = _datastore.length;
    _datastore.clear();
    _logger.info('Cleared datastore (removed $count records)');
  }
  
  /// Gets datastore statistics
  Future<Map<String, dynamic>> getDatastoreStatistics() async {
    _ensureStarted();
    
    final stats = <String, dynamic>{
      'total_records': _datastore.length,
      'total_size_bytes': _datastore.values.fold<int>(0, (sum, record) => sum + record.value.length),
      'oldest_record_timestamp': _datastore.values.isEmpty ? null : _datastore.values.map((r) => r.timeReceived).reduce((a, b) => a < b ? a : b),
      'newest_record_timestamp': _datastore.values.isEmpty ? null : _datastore.values.map((r) => r.timeReceived).reduce((a, b) => a > b ? a : b),
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