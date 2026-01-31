import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:collection/collection.dart';
import 'package:dcid/dcid.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:dart_libp2p_kad_dht/src/pb/dht_codec.dart';
import 'package:dart_libp2p_kad_dht/src/dht/routing.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/managers/query_manager.dart';
import 'package:dart_libp2p_kad_dht/src/internal/protocol_messenger.dart';
import 'package:dart_libp2p_kad_dht/src/kbucket/table/table.dart';
import 'package:dart_libp2p_kad_dht/src/netsize/netsize.dart';
import 'package:dart_libp2p_kad_dht/src/query/query_runner.dart';
import 'package:dart_libp2p_kad_dht/src/query/qpeerset.dart';
import 'package:dart_libp2p_kad_dht/src/query/legacy_types.dart';
import 'package:dart_libp2p_kad_dht/src/rtrefresh/rt_refresh_manager.dart';
// Ensure logging is imported for the whole class
import 'package:logging/logging.dart';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peerstore.dart';
import 'package:dart_libp2p/core/routing/options.dart';
import 'package:dart_libp2p/core/routing/routing.dart';
// Added import for Discovery interface and related classes
import 'package:dart_libp2p/core/discovery.dart';
import 'package:dart_libp2p/core/event/addrs.dart';
import 'package:dart_libp2p/core/network/stream.dart'; // Import for P2PStream
import 'package:dart_libp2p/p2p/multiaddr/protocol.dart'; // Added for Protocols.p2p.name

// Direct imports for Validators
// Validator might be needed if _recordValidator type is just Validator
import 'package:dart_libp2p_kad_dht/src/record/generic_validator.dart';
import 'package:dart_libp2p_kad_dht/src/record/ipns_validator.dart';
import 'package:dart_libp2p_kad_dht/src/record/namespace_validator.dart';
import 'package:dart_libp2p_kad_dht/src/record/pubkey.dart';



/// Exception thrown when DHT message retries are exhausted.
class MaxRetriesExceededException implements Exception {
  final String message;
  final dynamic lastError;

  MaxRetriesExceededException(this.message, [this.lastError]);

  @override
  String toString() {
    if (lastError != null) {
      return 'MaxRetriesExceededException: $message - Last error: $lastError';
    }
    return 'MaxRetriesExceededException: $message';
  }
}

/// Simple implementation of PeerLatencyMetrics that returns a default latency
/// for all peers. In a real implementation, this would use the host's peerstore
/// to get actual latency measurements.
class SimplePeerLatencyMetrics implements PeerLatencyMetrics {
  /// Default latency to return for all peers
  final Duration defaultLatency;



  /// Creates a new SimplePeerLatencyMetrics with the given default latency
  SimplePeerLatencyMetrics({this.defaultLatency = const Duration(milliseconds: 100)});

  @override
  Duration latencyEWMA(PeerId peerId) {
    // In a real implementation, this would use the host's peerstore to get
    // the actual latency for the peer. For now, just return the default.
    return defaultLatency;
  }
}

// /// Type definition for a stream handler function
// typedef StreamHandler = Future<void> Function(dynamic stream, PeerId remotePeer);


/// DHT is the main implementation of the Kademlia DHT for libp2p.
class IpfsDHT implements Routing, Discovery { // Added Discovery interface
  static final _log = Logger('IpfsDHT');
  /// The host that this DHT is running on
  final Host _host;

  /// The routing table for this DHT
  final RoutingTable _routingTable;

  /// The provider manager for this DHT
  final ProviderManager _providerManager;

  /// The network size estimator
  late final Estimator _nsEstimator;

  RtRefreshManager? _refreshManager;

  /// The message handlers
  late final DHTHandlers _handlers;

  /// The peer store for this DHT
  late final Peerstore peerstore;

  /// The protocol messenger for this DHT
  late final ProtocolMessenger protoMessenger;

  /// Whether value storage and retrieval is enabled
  bool enableValues = true;

  final _context = Context();

  /// The current mode of operation
  DHTMode _mode;

  /// The options for this DHT
  final DHTOptions _options;

  /// The record validator
  late final NamespacedValidator _recordValidator;

  /// Whether the DHT has been started
  bool _started = false;

  /// Whether the DHT has been closed
  bool _closed = false;

  /// Subscription to address update events
  StreamSubscription? _addressUpdateSubscription;

  /// Set to track active QueryRunner instances for proper cleanup
  final Set<QueryRunner> _activeQueryRunners = <QueryRunner>{};

  DHTHandlers get handlers => _handlers; // Flag to ensure background bootstrap tasks are only initiated once

  // or managed correctly if bootstrap is called multiple times.
  bool _backgroundTasksInitiated = false;
  
  /// Completer to control auto mode checking
  Completer<void>? _autoModeCompleter;
  
  /// Completer to control background refresh
  Completer<void>? _backgroundRefreshCompleter;


  /// Local datastore for key-value pairs
  final Map<String, Record> _datastore = {};

  /// Creates a new DHT with the given options
  IpfsDHT({
    required Host host,
    required ProviderStore providerStore,
    DHTOptions? options,
    NamespacedValidator? validator, // Optional: allow passing a pre-configured one
  })  : _host = host,
        _routingTable = RoutingTable(
          local: host.id,
          bucketSize: options?.bucketSize ?? AminoConstants.defaultBucketSize,
          maxLatency: AminoConstants.defaultMaxLatency,
          metrics: SimplePeerLatencyMetrics(),
          usefulnessGracePeriod: AminoConstants.defaultUsefulnessGracePeriod,
        ),
        _providerManager = ProviderManager(
          localPeerId: host.id,
          peerStore: host.peerStore, // Assuming the network implements PeerStore
          store: providerStore,
          options: ProviderManagerOptions(
            provideValidity: options?.provideValidity ?? AminoConstants.defaultProvideValidity,
            providerAddrTTL: options?.providerAddrTTL ?? AminoConstants.defaultProviderAddrTTL,
          ),
        ),
        _mode = options?.mode ?? DHTMode.auto,
        _options = options ?? const DHTOptions() {
    _handlers = DHTHandlers(this);
    _recordValidator = validator ?? NamespacedValidator();
    // Configure _recordValidator with specific validators
    _recordValidator['pk'] = PublicKeyValidator(); // Namespace without slashes
    _recordValidator['ipns'] = IpnsValidator(host.peerStore); // Namespace without slashes
    _recordValidator['v'] = GenericValidator(); // Namespace without slashes
    _nsEstimator = Estimator(
      localId: host.id,
      rt: _routingTable,
      bucketSize: options?.bucketSize ?? AminoConstants.defaultBucketSize,
    );


    if (options?.autoRefresh ?? false) {
      _refreshManager = RtRefreshManager(
        host: host,
        dhtPeerId: host.id,
        rt: _routingTable,
        enableAutoRefresh: true,
        refreshKeyGenFnc: _generateRefreshKey,
        refreshQueryFnc: _performRefreshQuery,
        refreshPingFnc: _performRefreshPing,
        refreshQueryTimeout: Duration(seconds: 10),
        refreshInterval: Duration(minutes: 5),
        successfulOutboundQueryGracePeriod: Duration(minutes: 1),
      );
    }
  }

  /// Gets the host that this DHT is running on
  Host host() => _host;

  /// Starts the DHT
  Future<void> start() async {
    final logPrefix = '[${_host.id.toBase58()}.start]';
    if (_started) {
      _log.fine('$logPrefix DHT already started.');
      return;
    }
    if (_closed) {
      _log.warning('$logPrefix Attempted to start a closed DHT.');
      throw StateError('DHT has been closed');
    }

    _started = true;
    _log.info('$logPrefix DHT starting in mode: $_mode');

    // Set up protocol handlers if in server mode
    if (_mode == DHTMode.server) {
      _log.info('$logPrefix Initial mode is server, setting up protocol handlers.');
      _setupProtocolHandlers();
    }

    // If in auto mode, set up periodic checking to switch to server mode
    if (_mode == DHTMode.auto) {
      _log.info('$logPrefix Mode is auto, starting periodic check for switch to server mode.');
      _autoModeCompleter = Completer<void>();
      _startAutoModeChecker();
    }

    // Subscribe to local address changes to trigger a bootstrap (self-walk)
    // This is crucial for the DHT to update its view of the network when its own addresses change.
    print('[IpfsDHT.start] Subscribing to EvtLocalAddressesUpdated...');
    _addressUpdateSubscription = _host.eventBus.subscribe(EvtLocalAddressesUpdated).stream.listen((event) {
      print('[IpfsDHT.start] Received event from eventBus: ${event.runtimeType}');
      // Cast the event, as the stream from subscribe might be Stream<dynamic> or Stream<Object>
      if (event is EvtLocalAddressesUpdated) {
        if (!_closed && _started) { // Ensure DHT is active and not closed
          // Using a print statement for now to observe this path being taken during tests.
          // Consider a more formal logging mechanism for production.
          print('IpfsDHT: Detected local address update. Triggering bootstrap/self-walk.');
          bootstrap().then((_) {
            print('IpfsDHT: Bootstrap after address update completed.');
          }).catchError((e, s) { // Added StackTrace
            print('IpfsDHT: Error during bootstrap triggered by address update: $e\n$s');
            // Potentially log this error more formally
          });
        }
      }
    });
    
    // Start the refresh manager if it exists
    if (_refreshManager != null) {
      _refreshManager!.start();
      _log.info('$logPrefix RtRefreshManager started');
      await _refreshManager!.refresh(true);
    }
    
    print('[IpfsDHT.start] Subscribed to EvtLocalAddressesUpdated. Start method continuing.');
  }

  /// Starts the auto mode checker using Future.delayed instead of Timer.periodic.
  /// This prevents unhandled exceptions that can occur with Timer callbacks.
  void _startAutoModeChecker() async {
    final logPrefix = '[${_host.id.toBase58().substring(0, 6)}.autoModeChecker]';
    try {
      while (!_closed && _started && _mode == DHTMode.auto) {
        await Future.any([
          Future.delayed(Duration(minutes: 1)),
          _autoModeCompleter!.future,
        ]);
        
        if (_closed || !_started || _mode != DHTMode.auto) {
          _log.fine('$logPrefix DHT closed or mode changed, stopping auto mode checker.');
          break;
        }

        try {
          final tableSize = await _routingTable.size();
          _log.finer('$logPrefix Auto mode check: current table size = $tableSize, serverModeMinPeers = ${AminoConstants.serverModeMinPeers}');
          
          // Switch to server mode if we have enough peers in our routing table
          if (tableSize >= AminoConstants.serverModeMinPeers) {
            _log.info('$logPrefix Auto mode: table size ($tableSize) >= minPeers (${AminoConstants.serverModeMinPeers}). Switching to server mode.');
            _mode = DHTMode.server;
            _setupProtocolHandlers();
            _log.info('$logPrefix Switched to server mode.');
            break; // Exit the loop since we're no longer in auto mode
          }
        } catch (e, s) {
          _log.warning('$logPrefix Error during auto mode check: $e', e, s);
        }
      }
    } catch (e, s) {
      _log.severe('$logPrefix Auto mode checker failed: $e', e, s);
    }
  }

  /// Sets up protocol handlers for incoming requests
  void _setupProtocolHandlers() {
    print('Setting up protocol handlers for ${AminoConstants.protocolID} directly on host.');
    // Changed from _host.network.setStreamHandler to _host.setStreamHandler
    // to match where MockHost.newStream looks for handlers.
    _host.setStreamHandler(AminoConstants.protocolID, _handleIncomingStream);
  }

  /// Handles an incoming stream
  // Reverted stream type to dynamic to match potential StreamHandler typedef, will cast internally.
  Future<void> _handleIncomingStream(dynamic streamInput, PeerId remotePeer) async { 
    // Cast to P2PStream<Uint8List> for type safety within the method.
    // This assumes the actual stream passed will conform to this.
    final P2PStream<Uint8List> stream = streamInput as P2PStream<Uint8List>;

    // Extract remote peer addresses from the connection
    List<MultiAddr>? remotePeerAddrs;
    try {
      // Try to get the remote address from the stream's connection
      final conn = stream.conn;
      final remoteAddr = conn.remoteMultiaddr;
      remotePeerAddrs = [remoteAddr];
      _log.fine('[${_host.id.toBase58().substring(0,6)}._handleIncomingStream] Extracted remote address for ${remotePeer.toBase58().substring(0,6)}: $remoteAddr');
    } catch (e) {
      _log.fine('[${_host.id.toBase58().substring(0,6)}._handleIncomingStream] Could not extract remote address for ${remotePeer.toBase58().substring(0,6)}: $e');
    }

    try {
      // Read the message from the stream using read()
      final dynamic rawMessageData = await stream.read(); 
      Uint8List messageBytes;

      if (rawMessageData is Uint8List) {
        messageBytes = rawMessageData;
      } else if (rawMessageData is List<int>) {
        // This case should ideally be handled by MockStream directly returning Uint8List,
        // but as a fallback, convert List<int> to Uint8List.
        print('[IpfsDHT._handleIncomingStream] Warning: Received List<int>, converting to Uint8List. Peer: $remotePeer');
        messageBytes = Uint8List.fromList(rawMessageData);
      } else {
        print('[IpfsDHT._handleIncomingStream] Error: Unexpected data type from stream.first: ${rawMessageData.runtimeType}. Peer: $remotePeer. Data: $rawMessageData');
        // Reset the stream as we can't process this.
        await stream.reset();
        return;
      }

      // Parse the message (protobuf with varint-length framing)
      final message = decodeMessage(messageBytes);

      // Store remote peer addresses in peerstore if we have them
      if (remotePeerAddrs != null && remotePeerAddrs.isNotEmpty) {
        try {
          await _host.peerStore.addrBook.addAddrs(remotePeer, remotePeerAddrs, Duration(hours: 1));
          _log.fine('[${_host.id.toBase58().substring(0,6)}._handleIncomingStream] Stored ${remotePeerAddrs.length} addresses for ${remotePeer.toBase58().substring(0,6)} in peerstore');
        } catch (e) {
          _log.warning('[${_host.id.toBase58().substring(0,6)}._handleIncomingStream] Error storing addresses for ${remotePeer.toBase58().substring(0,6)}: $e');
        }
      }

      // Get the handler for this message type
      final handler = _handlers.handlerForMsgType(message.type);

      // Handle the message
      final response = await handler(remotePeer, message);

      // ADD_PROVIDER is fire-and-forget per the libp2p spec — no response sent
      if (message.type == MessageType.addProvider) {
        await stream.close();
      } else {
        // Send the response back on the stream (protobuf with varint-length framing)
        final responseBytes = encodeMessage(response);
        await stream.write(responseBytes);
        await stream.close();
      }
    } catch (e) {
      // If there was an error, reset the stream to signal the failure to the other side
      // A more sophisticated error handling might involve sending an error message if the protocol supports it.
      print('[IpfsDHT._handleIncomingStream] Error handling incoming stream from $remotePeer: $e');
      // Ensure the stream is terminated. reset() is often used for abrupt termination.
      // MockStream's reset also calls close().
      await stream.reset(); 
    }
  }

  /// Closes the DHT and releases resources
  Future<void> close() async {
    final logPrefix = '[${_host.id.toBase58().substring(0, 6)}.close]';
    if (_closed) {
      _log.fine('$logPrefix DHT already closed.');
      return;
    }
    _log.info('$logPrefix Closing DHT...');

    _closed = true;
    _started = false;

    // Cancel all async operations
    _backgroundRefreshCompleter?.complete();
    _backgroundRefreshCompleter = null;
    _log.fine('$logPrefix Cancelled background refresh operations.');

    _autoModeCompleter?.complete();
    _autoModeCompleter = null;
    _log.fine('$logPrefix Cancelled auto mode operations.');

    // Cancel event subscriptions
    await _addressUpdateSubscription?.cancel();
    _addressUpdateSubscription = null;
    _log.fine('$logPrefix Cancelled address update subscription.');

    // Remove protocol handlers to prevent new incoming streams
    _host.removeStreamHandler(AminoConstants.protocolID);
    _log.fine('$logPrefix Removed protocol handlers.');

    // Dispose of all active QueryRunner instances
    _log.info('$logPrefix Disposing ${_activeQueryRunners.length} active QueryRunner instances...');
    final queryRunnerDisposals = <Future>[];
    for (final runner in _activeQueryRunners) {
      queryRunnerDisposals.add(runner.dispose());
    }
    await Future.wait(queryRunnerDisposals);
    _activeQueryRunners.clear();
    _log.fine('$logPrefix All QueryRunner instances disposed.');

    // Close the provider manager
    await _providerManager.close();
    _log.fine('$logPrefix Provider manager closed.');

    // Close the refresh manager
    if (_refreshManager != null) {
      await _refreshManager!.close();
      _log.fine('$logPrefix RtRefreshManager closed.');
    }

    // Close the host's network to clean up any remaining connections/streams
    try {
      await _host.network.close();
      _log.fine('$logPrefix Host network closed.');
    } catch (e) {
      _log.warning('$logPrefix Error closing host network: $e');
    }

    _log.info('$logPrefix DHT closed.');
  }

  /// Finds a peer in the local routing table
  Future<AddrInfo?> findLocalPeer(PeerId id) async {
    // Check if the peer is in our routing table
    final peerIdFromTable = await _routingTable.find(id);
    if (peerIdFromTable != null) {
      // Get the peer's addresses from the local peerstore
      final peerInfoFromStore = await _host.peerStore.getPeer(peerIdFromTable);
      return AddrInfo(peerIdFromTable, peerInfoFromStore?.addrs.toList() ?? []);
    }
    return null;
  }

  /// Gets the closest peers to a target
  /// 
  /// This method first checks the local routing table, and if insufficient peers
  /// are found, performs network queries to discover additional peers.
  Future<List<AddrInfo>> getClosestPeers(PeerId target, {bool networkQueryEnabled = true}) async {
    final logPrefix = '[${_host.id.toBase58().substring(0, 6)}.getClosestPeers]';
    final targetShortId = target.toBase58().substring(0, 6);
    print('$logPrefix *** DEBUG: Finding closest peers to $targetShortId (networkQuery: $networkQueryEnabled)');
    print('$logPrefix *** DEBUG: _options.resiliency = ${_options.resiliency}');

    // Phase 1: Get peers from local routing table
    final localPeerIds = await _routingTable.nearestPeers(target.toBytes(), _options.resiliency);
    print('$logPrefix *** DEBUG: Found ${localPeerIds.length} peers in local routing table');
    for (int i = 0; i < localPeerIds.length; i++) {
      print('$logPrefix *** DEBUG: Local peer $i: ${localPeerIds[i].toBase58().substring(0,6)}');
    }

    // Convert PeerId objects to AddrInfo objects
    final localResult = <AddrInfo>[];
    for (final peerId in localPeerIds) {
      // Get the peer's addresses from the peerstore
      final peerInfoFromStore = await _host.peerStore.getPeer(peerId);
      localResult.add(AddrInfo(peerId, peerInfoFromStore?.addrs.toList() ?? []));
    }

    print('$logPrefix *** DEBUG: Local result count: ${localResult.length}, resiliency: ${_options.resiliency}, networkQueryEnabled: $networkQueryEnabled');

    // If we have sufficient peers from local routing table, return them
    if (localResult.length >= _options.resiliency || !networkQueryEnabled) {
      print('$logPrefix *** DEBUG: EARLY RETURN - Returning ${localResult.length} peers from local routing table (sufficient or network query disabled)');
      return localResult;
    }

    // Phase 2: Network query for additional peers if local results are insufficient
    print('$logPrefix *** DEBUG: NETWORK QUERY TRIGGERED - Local routing table has only ${localResult.length} peers (< ${_options.resiliency}). Performing network query...');

    if (!_started) {
      _log.fine('$logPrefix DHT not started, calling start() before network query.');
      await start();
    }

    try {
      // Use existing runLookupWithFollowup infrastructure to query the network
      // We'll collect both peer IDs and their addresses from network responses
      final networkPeersWithAddrs = <PeerId, AddrInfo>{};
      
      final networkResult = await runLookupWithFollowup(
        target: target.toBytes(),
        queryFn: (peer) async {
          final queryFnLogPrefix = '$logPrefix [networkQuery.queryFn for ${peer.toBase58().substring(0,6)}]';
          _log.fine('$queryFnLogPrefix Sending FIND_NODE for target $targetShortId');
          
          final message = Message(
            type: MessageType.findNode,
            key: target.toBytes(),
          );
          
          final response = await _sendMessage(peer, message);
          _log.fine('$queryFnLogPrefix Got FIND_NODE response with ${response.closerPeers.length} closer peers');
          
          // Convert response peers to AddrInfo objects AND store them for later use
          final addrInfoList = response.closerPeers.map((p) {
            final peerId = PeerId.fromBytes(p.id);
            final addrs = p.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList();
            final addrInfo = AddrInfo(peerId, addrs);
            
            // Store the peer with its addresses from the network response
            // This preserves the addresses that came directly from the bootstrap server
            networkPeersWithAddrs[peerId] = addrInfo;
            _log.fine('$queryFnLogPrefix Stored peer ${peerId.toBase58().substring(0,6)} with ${addrs.length} addresses from network response');
            
            return addrInfo;
          }).toList();
          
          return addrInfoList;
        },
        stopFn: (peerset) {
          // Stop when we've queried enough peers or found sufficient diverse peers
          final queriedCount = peerset.getClosestInStates([PeerState.queried]).length;
          final totalPeersFound = peerset.getClosestInStates([
            PeerState.queried, 
            PeerState.heard, 
            PeerState.waiting
          ]).length;
          
          final stop = queriedCount >= _options.resiliency || totalPeersFound >= (_options.resiliency * 2);
          _log.finer('$logPrefix [networkQuery.stopFn] Queried: $queriedCount, Total found: $totalPeersFound, Resiliency: ${_options.resiliency}. Stop: $stop');
          return stop;
        },
      );

      // Combine local and network results, removing duplicates
      final combinedPeers = <PeerId, AddrInfo>{};
      
      // Add local peers first (they're already connected)
      for (final localPeer in localResult) {
        combinedPeers[localPeer.id] = localPeer;
      }
      
      // Add network-discovered peers using the addresses we preserved from network responses
      for (final networkPeerId in networkResult.peers) {
        if (!combinedPeers.containsKey(networkPeerId)) {
          // Use the addresses we stored from the actual network response
          // This preserves the addresses that came from bootstrap servers
          final networkPeerWithAddrs = networkPeersWithAddrs[networkPeerId];
          if (networkPeerWithAddrs != null) {
            combinedPeers[networkPeerId] = networkPeerWithAddrs;
            _log.fine('$logPrefix Using preserved addresses for network peer ${networkPeerId.toBase58().substring(0,6)}: ${networkPeerWithAddrs.addrs.length} addresses');
          } else {
            // Fallback to peerstore if somehow not found in our preserved map
            final peerInfoFromStore = await _host.peerStore.getPeer(networkPeerId);
            combinedPeers[networkPeerId] = AddrInfo(
              networkPeerId, 
              peerInfoFromStore?.addrs.toList() ?? []
            );
            _log.warning('$logPrefix Fallback to peerstore for network peer ${networkPeerId.toBase58().substring(0,6)} (${peerInfoFromStore?.addrs.length ?? 0} addresses)');
          }
        }
      }

      final finalResult = combinedPeers.values.toList();
      _log.info('$logPrefix Network query completed. Combined result: ${finalResult.length} peers (${localResult.length} local + ${finalResult.length - localResult.length} network)');
      
      // Log the peer IDs for debugging
      for (int i = 0; i < finalResult.length; i++) {
        final peer = finalResult[i];
        final source = localResult.any((p) => p.id == peer.id) ? 'local' : 'network';
        _log.fine('$logPrefix Result peer $i: ${peer.id.toBase58().substring(0,6)} ($source, ${peer.addrs.length} addrs)');
      }
      
      return finalResult;
      
    } catch (e, s) {
      _log.warning('$logPrefix Network query failed: $e', e, s);
      // Fall back to local results even if insufficient
      _log.info('$logPrefix Falling back to ${localResult.length} local peers due to network query failure');
      return localResult;
    }
  }

  /// Checks the local datastore for a value
  Future<Record?> checkLocalDatastore(Uint8List key) async {
    final Logger log = Logger('IpfsDHT.checkLocalDatastore');
    final keyString = base64Encode(key);
    final record = _datastore[keyString];
    if (record != null) {
      log.fine('[${_host.id.toBase58().substring(0,6)}] Found record for key "$keyString". Value: "${utf8.decode(record.value, allowMalformed: true)}" (Length: ${record.value.length})');
    } else {
      log.fine('[${_host.id.toBase58().substring(0,6)}] No record found for key "$keyString".');
    }
    return record;
  }

  /// Validates a record
  Future<bool> validateRecord(Record record) async {
    // In a real implementation, this would validate the signature
    // For now, just return true
    return true;
  }

  /// Puts a record to the datastore
  Future<void> putRecordToDatastore(Record record) async {
    final Logger log = Logger('IpfsDHT.putRecordToDatastore');
    final keyString = base64Encode(record.key);
    log.fine('[${_host.id.toBase58().substring(0,6)}] Storing record for key "$keyString". Value: "${utf8.decode(record.value, allowMalformed: true)}" (Length: ${record.value.length}), Author: ${PeerId.fromBytes(record.author).toBase58()}');
    _datastore[keyString] = record;
  }

  /// Gets local providers for a key
  Future<List<AddrInfo>> getLocalProviders(Uint8List key) async {
    // Get providers from the provider manager
    return await _providerManager.getProviders(CID.fromBytes(key));
  }

  /// Adds a provider for a key
  Future<void> addProvider(Uint8List key, AddrInfo provider) async {
    // Add the provider to the provider manager
    await _providerManager.addProvider(CID.fromBytes(key), provider);
  }

  /// Dials a peer
  Future<void> dialPeer(PeerId peer) async {
    final Logger dialLogger = Logger('IpfsDHT.dialPeer');
    dialLogger.info('[${_host.id.toBase58().substring(0,6)}] Attempting to dial peer ${peer.toBase58().substring(0,6)}');

    // If dialing self, we can assume the host is already "connected" to itself.
    // Skip the explicit _host.connect() call to avoid issues with repeated self-connections.
    if (peer == _host.id) {
      dialLogger.info('[${_host.id.toBase58().substring( 0, 6)}] Self-dial detected for ${peer.toBase58().substring( 0, 6)}. Skipping _host.connect().');
      return;
    }

    // Get AddrInfo for the peer from the peerstore
    final peerInfo = await _host.peerStore.getPeer(peer); 
    if (peerInfo == null || peerInfo.addrs.isEmpty) {
      dialLogger.warning('[${_host.id.toBase58().substring(0,6)}] No addresses found for peer ${peer.toBase58().substring(0,6)} in peerstore. Cannot dial.');
      return; 
    }

    List<MultiAddr> addrsToUse = peerInfo.addrs.toList();
    
    // Transform 0.0.0.0 addresses to 127.0.0.1 for connection attempts,
    // as 0.0.0.0 is a listen address, not a connectable target from another local process.
    final List<MultiAddr> effectiveAddrs = [];
    for (final addr in addrsToUse) {
      String addrStr = addr.toString();
      if (addrStr.startsWith('/ip4/0.0.0.0/')) {
        try {
          effectiveAddrs.add(MultiAddr(addrStr.replaceFirst('/ip4/0.0.0.0/', '/ip4/127.0.0.1/')));
        } catch (e) {
          dialLogger.warning("Failed to transform 0.0.0.0 address '$addrStr' to 127.0.0.1 for connect: $e");
          effectiveAddrs.add(addr); // Fallback to original on error
        }
      } else {
        effectiveAddrs.add(addr);
      }
    }
    dialLogger.fine('[${_host.id.toBase58().substring(0,6)}] Original addrs for ${peer.toBase58().substring(0,6)}: ${addrsToUse.map((a) => a.toString()).join(", ")}. Effective addrs for connect: ${effectiveAddrs.map((a) => a.toString()).join(", ")}.');

    try {
      final addrInfoToConnect = AddrInfo(peer, effectiveAddrs); // Use transformed addresses
      await _host.connect(addrInfoToConnect);
      dialLogger.info('[${_host.id.toBase58().substring(0,6)}] Successfully connected to peer ${peer.toBase58().substring(0,6)}.');
    } catch (e, s) {
      dialLogger.severe('[${_host.id.toBase58().substring(0,6)}] Error connecting to peer ${peer.toBase58().substring(0,6)}: $e', e, s);
      rethrow; // Rethrow the error so the caller (e.g., _sendMessage) can handle it.
    }
  }

  /// Gets bootstrap peers for the query
  Future<List<AddrInfo>> getBootstrapPeers() async {
    final Logger bootstrapLogger = Logger('IpfsDHT.getBootstrapPeers');
    final List<AddrInfo> result = [];

    // 1. Try peers from our routing table first
    final rtDhtPeerInfos = await _routingTable.listPeers(); // These are DhtPeerInfo
    for (final rtDhtPeerInfo in rtDhtPeerInfos) {
      // Get PeerInfo (which contains addrs) from the peerstore
      final storedPeerInfo = await _host.peerStore.getPeer(rtDhtPeerInfo.id); // rtDhtPeerInfo.id is correct (PeerId)
      if (storedPeerInfo != null && storedPeerInfo.addrs.isNotEmpty) {
        // Only add if we have addresses for them
        // PeerInfo from peerstore should have 'peerId', not 'id'
        result.add(AddrInfo(storedPeerInfo.peerId, storedPeerInfo.addrs.toList()));
      }
    }
    bootstrapLogger.info('[${_host.id.toBase58().substring(0,6)}] Initially got ${result.length} peers from routing table with addresses.');

    // 2. If routing table yielded no usable peers (e.g., empty or peers have no known addrs),
    //    use configured bootstrap peers from DHTOptions.
    if (result.isEmpty && _options.bootstrapPeers != null && _options.bootstrapPeers!.isNotEmpty) {
      bootstrapLogger.info('[${_host.id.toBase58().substring(0,6)}] Routing table yielded no usable peers. Using configured bootstrapPeers from DHTOptions.');
      for (final ma in _options.bootstrapPeers!) {
        try {
          final p2pComponent = ma.valueForProtocol(Protocols.p2p.name);
          if (p2pComponent == null) {
            bootstrapLogger.warning('[${_host.id.toBase58().substring(0,6)}] Configured bootstrap peer $ma is missing /p2p component. Skipping.');
            continue;
          }
          final peerId = PeerId.fromString(p2pComponent);

          // Skip adding self if it's in the bootstrap list
          if (peerId == _host.id) {
            bootstrapLogger.finer('[${_host.id.toBase58().substring(0,6)}] Skipping self from configured bootstrap peers: $peerId');
            continue;
          }
          
          final addrOnly = ma.decapsulate(Protocols.p2p.name);
          if (addrOnly != null && addrOnly.toString().isNotEmpty) {
            result.add(AddrInfo(peerId, [addrOnly]));
          } else {
             bootstrapLogger.warning('[${_host.id.toBase58().substring(0,6)}] Configured bootstrap multiaddress $ma has no connectable address part after decapsulating /p2p. Skipping.');
          }
        } catch (e, s) {
          bootstrapLogger.warning('[${_host.id.toBase58().substring(0,6)}] Error processing configured bootstrap multiaddress $ma: $e\n$s. Skipping.');
        }
      }
      bootstrapLogger.info('[${_host.id.toBase58().substring(0,6)}] After processing DHTOptions.bootstrapPeers, result has ${result.length} peers.');
    }
    
    // Deduplicate, prioritizing entries that might have come from routing table (though current logic adds them first)
    final finalPeers = <PeerId, AddrInfo>{};
    for (var ai in result) {
        finalPeers.putIfAbsent(ai.id, () => ai);
    }

    bootstrapLogger.info('[${_host.id.toBase58().substring(0,6)}] Raw DhtPeerInfo from routingTable.listPeers(): ${rtDhtPeerInfos.map((p) => p.id.toBase58().substring(0,6)).toList()} (Count: ${rtDhtPeerInfos.length})');
    bootstrapLogger.info('[${_host.id.toBase58().substring(0,6)}] Returning ${finalPeers.values.length} unique bootstrap peers for lookup: ${finalPeers.values.map((ai) => '${ai.id.toBase58().substring(0,6)}(${ai.addrs.length} addrs)').toList()}');
    return finalPeers.values.toList();
  }

  @override
  Future<void> bootstrap({bool quickConnectOnly = false, Duration? periodicRefreshInterval}) async {
    final logPrefix = '[${_host.id.toBase58().substring(0, 6)}.bootstrap]';
    _log.info('$logPrefix Starting bootstrap process (quickConnectOnly: $quickConnectOnly, periodicRefresh: $periodicRefreshInterval).');

    if (_closed) {
      _log.warning('$logPrefix Attempted to bootstrap a closed DHT.');
      return;
    }
    if (!_started) {
      _log.info('$logPrefix DHT not started, calling start() from bootstrap.');
      await start();
    }

    // --- Phase 1: Quick Connect to a limited number of Explicit Bootstrap Peers ---
    int explicitPeersToQuickConnect = 2; // Max peers for the "quick" part
    int connectedExplicitly = 0;

    if (_options.bootstrapPeers != null && _options.bootstrapPeers!.isNotEmpty) {
      _log.info('$logPrefix Processing ${_options.bootstrapPeers!.length} explicit bootstrap peers for initial connection phase.');
      for (final ma in _options.bootstrapPeers!) {
        if (connectedExplicitly >= explicitPeersToQuickConnect && quickConnectOnly) {
            _log.fine('$logPrefix Reached quick connect limit ($explicitPeersToQuickConnect). Further explicit peers will be handled by background task if any.');
            break;
        }
        try {
          final p2pComponent = ma.valueForProtocol(Protocols.p2p.name);
          if (p2pComponent == null) {
            _log.warning('$logPrefix Configured bootstrap peer $ma is missing /p2p component. Skipping.');
            continue;
          }
          final peerId = PeerId.fromString(p2pComponent);
          final connectAddr = ma.decapsulate(Protocols.p2p.name);

          if (connectAddr != null && connectAddr.toString().isNotEmpty) {
            final addrInfo = AddrInfo(peerId, [connectAddr]);
            final peerShortId = addrInfo.id.toBase58().substring(0,6);
            _log.info('$logPrefix Attempting to connect to explicit bootstrap peer: $peerShortId via ${addrInfo.addrs}');
            _host.peerStore.addrBook.addAddrs(addrInfo.id, addrInfo.addrs, Duration(hours: 24)); // Add to peerstore
            _log.finer('$logPrefix Before _host.connect for $peerShortId');
            await _host.connect(addrInfo); // Connect
            _log.finer('$logPrefix After _host.connect for $peerShortId, before tryAddPeer.');
            bool addedToRt = await _routingTable.tryAddPeer(addrInfo.id, queryPeer: true); // Add to routing table
            _log.finer('$logPrefix After tryAddPeer for $peerShortId. Result addedToRt: $addedToRt.');
            final currentSize = await _routingTable.size();
            _log.finer('$logPrefix After _routingTable.size(). Current RT Size: $currentSize.');
            _log.info('$logPrefix Explicit bootstrap peer $peerShortId connected and processed. Added to RT: $addedToRt. RT Size: $currentSize');
            connectedExplicitly++;
          } else {
            _log.warning('$logPrefix Configured bootstrap multiaddress $ma has no connectable address part. Skipping.');
          }
        } catch (e, s) {
          _log.warning('$logPrefix Error processing explicit bootstrap multiaddress $ma: $e\n$s. Skipping.');
        }
      }
    } else {
      _log.info('$logPrefix No explicit bootstrap peers configured in _options.bootstrapPeers for initial connection.');
    }
    _log.info('$logPrefix Initial explicit peer connection phase completed. Connected to $connectedExplicitly peers.');

    // --- Phase 2: Deeper population and periodic refresh ---
    if (quickConnectOnly) {
      _log.info('$logPrefix Quick bootstrap requested. Initiating background tasks for fuller population and returning.');
      _initiateBackgroundTasks(periodicRefreshInterval);
      return;
    }

    // If not quickConnectOnly, perform the deeper population now and await it.
    _log.info('$logPrefix Full bootstrap requested. Performing deeper routing table population now.');
    await _populateRoutingTable(); // Await the first full population
    _initiateBackgroundTasks(periodicRefreshInterval); // Then set up background tasks (mainly for periodic refresh if interval provided)
    _log.info('$logPrefix Full bootstrap process (including initial deep population) finished.');
  }

  void _initiateBackgroundTasks(Duration? periodicRefreshInterval) {
    final logPrefix = '[${_host.id.toBase58().substring(0, 6)}.backgroundTasks]';
    if (_closed) {
        _log.info('$logPrefix DHT is closed, not initiating background tasks.');
        return;
    }

    if (!_backgroundTasksInitiated) {
      _backgroundTasksInitiated = true; // Set flag early to prevent re-entry
      _log.info('$logPrefix First time initiation: Starting one-off background routing table population.');
      _populateRoutingTable().catchError((e, s) {
        _log.severe('$logPrefix Error during initial background routing table population: $e\n$s');
        // Potentially reset _backgroundTasksInitiated = false; if you want it to be re-triggerable on error
        // For now, keep it true to avoid repeated attempts on persistent errors without a cool-down.
      }).whenComplete(() {
        _log.info('$logPrefix Initial background population task completed (or errored).');
      });
    } else {
      _log.info('$logPrefix Background population task was already initiated. Skipping one-off run.');
    }

    if (periodicRefreshInterval != null) {
      _backgroundRefreshCompleter?.complete(); // Cancel any existing refresh
      _backgroundRefreshCompleter = Completer<void>();
      _log.info('$logPrefix Setting up periodic background refresh every $periodicRefreshInterval.');
      _startPeriodicRefresh(periodicRefreshInterval);
    } else {
       _log.info('$logPrefix No periodicRefreshInterval provided, periodic refresh will not be scheduled.');
    }
  }

  Future<void> _populateRoutingTable() async {
    final logPrefix = '[${_host.id.toBase58().substring(0, 6)}.populateRoutingTable]';
    if (_closed) {
        _log.info('$logPrefix DHT is closed, aborting population task.');
        return;
    }
    _log.info('$logPrefix Starting deeper routing table population task.');

    // Part 1: Process peers from getBootstrapPeers()
    // These are peers already in our routing table. Connecting to them again helps ensure liveness
    // and refreshes their status.
    try {
        final peersFromTable = await getBootstrapPeers(); // This gets AddrInfo from RT
        _log.info('$logPrefix Processing ${peersFromTable.length} peers already in routing table.');
        for (final peerAddrInfo in peersFromTable) {
            if (_closed) break; // Check if DHT closed during long loop
            final peerShortId = peerAddrInfo.id.toBase58().substring(0,6);
            
            // Skip self-dial attempts - prevent trying to connect to our own peer ID
            if (peerAddrInfo.id == _host.id) {
                _log.fine('$logPrefix Skipping self-dial attempt for local peer $peerShortId in routing table population.');
                continue;
            }
            
            try {
                _log.finer('$logPrefix Connecting to/refreshing peer from table: $peerShortId');
                await _host.connect(peerAddrInfo);
                // queryPeer: false because we are just refreshing, not expecting them to be new for query purposes.
                bool added = await _routingTable.tryAddPeer(peerAddrInfo.id, queryPeer: false);
                _log.finer('$logPrefix Refreshed peer from table $peerShortId. Added to RT (likely updated): $added. RT size: ${await _routingTable.size()}');
            } catch (e, s) {
                _log.warning('$logPrefix Error refreshing peer from table $peerShortId: $e\n$s');
            }
        }
    } catch (e,s) {
        _log.severe('$logPrefix Error in _populateRoutingTable while processing existing RT peers: $e\n$s');
    }


    if (_closed) {
        _log.info('$logPrefix DHT closed, aborting before random lookup.');
        return;
    }

    // Part 2: Perform a random key lookup to discover new peers
    final currentTableSize = await _routingTable.size();
    _log.info('$logPrefix Current routing table size before random lookup: $currentTableSize.');
    if (currentTableSize > 0) {
      final randomKey = Uint8List.fromList(
        List.generate(32, (_) => math.Random().nextInt(256)),
      );
      _log.info('$logPrefix Performing random key lookup for key: ${base64Encode(randomKey).substring(0,10)}... to populate routing table.');

      try {
        await runLookupWithFollowup(
          target: randomKey,
          queryFn: (peer) async {
            final queryFnLogPrefix = '$logPrefix [randomLookup.queryFn for ${peer.toBase58().substring(0,6)}]';
            _log.fine('$queryFnLogPrefix Sending FIND_NODE for random key.');
            final message = Message(
              type: MessageType.findNode,
              key: randomKey,
            );
            final response = await _sendMessage(peer, message); // _sendMessage has its own logging
            _log.fine('$queryFnLogPrefix Got FIND_NODE response. CloserPeers: ${response.closerPeers.length}');
            
            // Try adding the queried peer to RT; queryPeer:false as its liveness is confirmed by response.
            bool added = await _routingTable.tryAddPeer(peer, queryPeer: false);
            _log.finer('$queryFnLogPrefix Tried adding peer ${peer.toBase58().substring(0,6)} to RT (queryPeer:false). Success: $added. Current RT size: ${await _routingTable.size()}');

            return response.closerPeers.map((p) => AddrInfo(
              PeerId.fromBytes(p.id),
              p.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList(),
            )).toList();
          },
          stopFn: (peerset) {
            final stop = peerset.getClosestInStates([PeerState.queried]).length >= _options.resiliency;
            _log.finer('$logPrefix [randomLookup.stopFn] Queried peers: ${peerset.getClosestInStates([PeerState.queried]).length}, Resiliency: ${_options.resiliency}. Stop: $stop');
            return stop;
          },
        );
        _log.info('$logPrefix Random key lookup completed. Final RT Size: ${await _routingTable.size()}');
      } catch (e,s) {
        _log.severe('$logPrefix Error during random key lookup: $e\n$s');
      }
    } else {
      _log.info('$logPrefix No bootstrap peers found or routing table empty. Skipping random key lookup.');
    }
    _log.info('$logPrefix Deeper routing table population task finished.');
  }

  /// Starts periodic refresh using Future.delayed instead of Timer.periodic.
  /// This prevents unhandled exceptions that can occur with Timer callbacks.
  void _startPeriodicRefresh(Duration interval) async {
    final logPrefix = '[${_host.id.toBase58().substring(0, 6)}.periodicRefresh]';
    try {
      while (!_closed && _started) {
        await Future.any([
          Future.delayed(interval),
          _backgroundRefreshCompleter!.future,
        ]);
        
        if (_closed || !_started) {
          _log.info('$logPrefix DHT closed, stopping periodic refresh.');
          break;
        }

        try {
          _log.info('$logPrefix Periodic background refresh triggered.');
          await _populateRoutingTable();
        } catch (e, s) {
          _log.severe('$logPrefix Error during periodic background routing table population: $e', e, s);
        }
      }
    } catch (e, s) {
      _log.severe('$logPrefix Periodic refresh failed: $e', e, s);
    }
  }

  @override
  Future<void> provide(CID cid, bool announce) async {
    final logPrefix = '[${_host.id.toBase58().substring(0, 6)}.provide]';
    _log.info('$logPrefix Called for CID: ${cid.toString()}, announce: $announce');

    if (!_started) {
      _log.fine('$logPrefix DHT not started, calling start().');
      await start();
      _log.fine('$logPrefix DHT start() completed.');
    }

    _log.fine('$logPrefix Adding self as provider for CID: ${cid.toString()}');
    await _providerManager.addProvider(cid, AddrInfo(
      _host.id,
      _host.addrs,
    ));
    _log.info('$logPrefix Self added as provider for CID: ${cid.toString()}');

    if (announce) {
      _log.info('$logPrefix Announcing provide for CID: ${cid.toString()}. Finding closest peers...');
      final result = await runLookupWithFollowup(
        target: cid.toBytes(),
        queryFn: (peer) async {
          final queryFnLogPrefix = '$logPrefix [provideLookup.queryFn for ${peer.toBase58().substring(0,6)}]';
          _log.finer('$queryFnLogPrefix Sending FIND_NODE for CID ${cid.toString()}.');
          final message = Message(
            type: MessageType.findNode,
            key: cid.toBytes(),
          );
          final response = await _sendMessage(peer, message);
          _log.finer('$queryFnLogPrefix Got FIND_NODE response. CloserPeers: ${response.closerPeers.length}');
          return response.closerPeers.map((p) => AddrInfo(
            PeerId.fromBytes(p.id),
            p.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList(),
          )).toList();
        },
        stopFn: (peerset) {
          final stop = peerset.getClosestInStates([PeerState.queried]).length >= _options.resiliency;
          _log.finer('$logPrefix [provideLookup.stopFn] For CID ${cid.toString()}: Queried peers: ${peerset.getClosestInStates([PeerState.queried]).length}, Resiliency: ${_options.resiliency}. Stop: $stop');
          return stop;
        },
      );

      _log.info('$logPrefix Lookup for CID ${cid.toString()} completed. Found ${result.peers.length} peers to send ADD_PROVIDER to: ${result.peers.map((p) => p.toBase58().substring(0,6)).join(', ')}');
      if (result.peers.isEmpty) {
        _log.warning('$logPrefix No peers found by lookup for CID ${cid.toString()} to send ADD_PROVIDER messages to. Advertisement might not be effective.');
      }

      for (final peer in result.peers) {
        final peerShortId = peer.toBase58().substring(0,6);
        try {
          _log.fine('$logPrefix Sending ADD_PROVIDER for CID ${cid.toString()} to peer $peerShortId');
          final message = Message(
            type: MessageType.addProvider,
            key: cid.toBytes(),
            providerPeers: [
              Peer(
                id: _host.id.toBytes(),
                addrs: _host.addrs.map((addr) => addr.toBytes()).toList(),
                connection: ConnectionType.connected,
              ),
            ],
          );
          await _sendMessageFireAndForget(peer, message);
          _log.info('$logPrefix Successfully sent ADD_PROVIDER for CID ${cid.toString()} to peer $peerShortId');
        } catch (e, s) {
          _log.warning('$logPrefix Error sending ADD_PROVIDER for CID ${cid.toString()} to peer $peerShortId: $e\n$s');
        }
      }
    } else {
      _log.info('$logPrefix provide called with announce=false for CID: ${cid.toString()}. Not announcing to network.');
    }
    _log.info('$logPrefix provide for CID: ${cid.toString()} completed.');
  }

  @override
  Stream<AddrInfo> findProvidersAsync(CID cid, int count) {
    // Create a controller to emit providers as we find them
    final controller = StreamController<AddrInfo>();

    // Run the provider lookup in the background
    _findProvidersAsync(cid, count, controller);

    // Return the stream of providers
    return controller.stream;
  }

  @override
  Stream<Uint8List> searchValue(String key, RoutingOptions? options) {
    // Create a controller to emit values as we find them
    final controller = StreamController<Uint8List>();

    // Run the value lookup in the background
    _searchValueAsync(key, options, controller);

    // Return the stream of values
    return controller.stream;
  }

  /// Asynchronously searches for values for a key and adds them to the controller
  Future<void> _searchValueAsync(String key, RoutingOptions? options, StreamController<Uint8List> controller) async {
    try {
      if (!_started) {
        await start();
      }

      // Apply default quorum if relevant
      options ??= RoutingOptions();
      final quorumValue = DHTRouting.getQuorum(options);

      // Convert the key to bytes
      final keyBytes = Uint8List.fromList(key.codeUnits);

      // Create a channel for received values
      final valCh = StreamController<ReceivedValue>();
      final stopCh = StreamController<void>();

      // Check if the value is stored locally
      final localRecord = await checkLocalDatastore(keyBytes);
      if (localRecord != null) {
        valCh.add(ReceivedValue(
          val: localRecord.value,
          from: _host.id,
        ));
      }

      // Find the closest peers to the key
      runLookupWithFollowup(
        target: keyBytes,
        queryFn: (peer) async {
          // Query the peer for the value
          final message = Message(
            type: MessageType.getValue,
            key: keyBytes,
          );

          // Send the message to the peer
          final response = await _sendMessage(peer, message);

          // Check if the response contains the value
          if (response.record != null) {
            valCh.add(ReceivedValue(
              val: response.record!.value,
              from: peer,
            ));
          }

          // Convert the response to AddrInfo objects
          return response.closerPeers.map((p) => AddrInfo(
            PeerId.fromBytes(p.id),
            p.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList(),
          )).toList();
        },
        stopFn: (peerset) {
          // Check if we should stop the query
          if (stopCh.isClosed) {
            return true;
          }

          // Stop when we've queried enough peers
          return peerset.getClosestInStates([PeerState.queried]).length >= _options.resiliency;
        },
      ).then((_) {
        // Close the value channel when the lookup is done
        valCh.close();
      }).catchError((e) {
        // Close the value channel on error
        valCh.close();
      });

      // Process values from the value channel
      var numResponses = 0;
      // Updated call to processValues with _recordValidator and adjusted callback
      await DHTRouting.processValues(key, valCh.stream, _recordValidator, (receivedValue, isCurrentlyBest) {
        if (isCurrentlyBest) { // Add to stream if it's the current best among valid ones
          controller.add(receivedValue.val);
        }

        // If we've received enough responses, stop the query
        // Note: The definition of "enough responses" might change with validator logic.
        // Quorum might mean enough distinct valid values or enough peers confirming the *same* best value.
        // For now, just counting any valid value received.
        if (quorumValue > 0 && ++numResponses >= quorumValue) { // Changed to >=
          if (!stopCh.isClosed) stopCh.close();
          return true; // Abort further processing
        }
        return false; // Continue processing
      });
    } catch (e) {
      // Ignore errors
    } finally {
      // Close the controller when done
      await controller.close();
    }
  }

  /// Asynchronously finds providers for a CID and adds them to the controller
  Future<void> _findProvidersAsync(CID cid, int count, StreamController<AddrInfo> controller) async {
    try {
      if (!_started) {
        await start();
      }

      // Check the local provider store for providers
      final localProviders = await _providerManager.getProviders(cid);

      // Add local providers to the stream
      for (final provider in localProviders) {
        controller.add(provider);
        count--;
        if (count <= 0) {
          await controller.close();
          return;
        }
      }

      // If we need more providers, perform a lookup
      if (count > 0) {
        // Track providers we've already seen
        final seenProviders = Set<PeerId>();
        for (final provider in localProviders) {
          seenProviders.add(provider.id);
        }

        // Find the closest peers to the CID
        final result = await runLookupWithFollowup(
          target: cid.toBytes(),
          queryFn: (peer) async {
            // Query the peer for providers
            final message = Message(
              type: MessageType.getProviders,
              key: cid.toBytes(),
            );

            // Send the message to the peer
            final response = await _sendMessage(peer, message);

            // Add providers to the stream
            for (final p in response.providerPeers) {
              final provider = AddrInfo(
                PeerId.fromBytes(p.id),
                p.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList(),
              );

              if (!seenProviders.contains(provider.id)) {
                seenProviders.add(provider.id);
                controller.add(provider);
                count--;
                if (count <= 0) {
                  break;
                }
              }
            }

            // Convert the response to AddrInfo objects for closer peers
            return response.closerPeers.map((p) => AddrInfo(
              PeerId.fromBytes(p.id),
               p.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList(),
            )).toList();
          },
          stopFn: (peerset) {
            // Stop when we've found enough providers or queried enough peers
            return count <= 0 || peerset.getClosestInStates([PeerState.queried]).length >= _options.resiliency;
          },
        );
      }
    } catch (e) {
      // Ignore errors
    } finally {
      // Close the controller when done
      await controller.close();
    }
  }

  @override
  Future<AddrInfo?> findPeer(PeerId id, {RoutingOptions? options}) async {
    final logPrefix = '[${_host.id.toBase58().substring(0, 6)}.findPeer]';
    final targetShortId = id.toBase58().substring(0,6);
    _log.info('$logPrefix Attempting to find peer $targetShortId (${id.toString()})');

    if (!_started) {
      _log.fine('$logPrefix DHT not started, calling start().');
      await start();
    }

    // Always perform network lookup to verify peer reachability
    // This ensures unreachable peers are detected and evicted from routing table
    _log.info('$logPrefix Performing network lookup for $targetShortId to verify reachability.');
    
    final targetBytes = id.toBytes();
    final result = await runLookupWithFollowup(
      target: targetBytes,
      queryFn: (peer) async {
        final queryFnLogPrefix = '$logPrefix [lookup.queryFn for ${peer.toBase58().substring(0,6)}]';
        _log.fine('$queryFnLogPrefix Sending FIND_NODE for target $targetShortId.');
        final message = Message(
          type: MessageType.findNode,
          key: targetBytes,
        );
        final response = await _sendMessage(peer, message);
        _log.fine('$queryFnLogPrefix Got FIND_NODE response. CloserPeers: ${response.closerPeers.length}.');
        
        // Try adding the queried peer to RT; queryPeer:false as its liveness is confirmed by response.
        bool added = await _routingTable.tryAddPeer(peer, queryPeer: false);
        _log.finer('$queryFnLogPrefix Tried adding peer ${peer.toBase58().substring(0,6)} to RT (queryPeer:false). Success: $added. Current RT size: ${await _routingTable.size()}');
        
        for (final p in response.closerPeers) {
          if (_bytesEqual(p.id, targetBytes)) {
            _log.info('$queryFnLogPrefix Target peer $targetShortId found in response from ${peer.toBase58().substring(0,6)}.');
            // Return a list containing only the target peer to potentially stop the lookup early if stopFn allows.
            return [
              AddrInfo(
                PeerId.fromBytes(p.id),
                p.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList(),
              ),
            ];
          }
        }
        return response.closerPeers.map((p) => AddrInfo(
          PeerId.fromBytes(p.id),
          p.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList(),
        )).toList();
      },
      stopFn: (peerset) {
        for (final p in peerset.getClosestInStates([PeerState.queried, PeerState.waiting, PeerState.heard])) {
          if (_bytesEqual(p.toBytes(), targetBytes)) {
            _log.fine('$logPrefix [lookup.stopFn] Target peer $targetShortId found in peerset. Stopping lookup.');
            return true;
          }
        }
        final stop = peerset.getClosestInStates([PeerState.queried]).length >= _options.resiliency;
        if (stop) {
          _log.fine('$logPrefix [lookup.stopFn] Queried enough peers (${_options.resiliency}). Stopping lookup for $targetShortId.');
        }
        return stop;
      },
    );

    _log.info('$logPrefix Lookup for $targetShortId completed. TerminationReason: ${result.terminationReason}. Found ${result.peers.length} peers in result set: ${result.peers.map((p) => p.toBase58().substring(0,6)).toList()}');
    
    final listEquality = ListEquality();
    for (final p_id_from_result in result.peers) {
      if (listEquality.equals(p_id_from_result.toBytes(), targetBytes)) {
        _log.info('$logPrefix Target peer $targetShortId matched in lookup result.peers. Fetching AddrInfo from local peerstore.');
        final peerInfoFromStore = await _host.peerStore.getPeer(p_id_from_result);
        if (peerInfoFromStore != null) {
          _log.info('$logPrefix For target $targetShortId, AddrInfo retrieved from local peerstore. Addrs count: ${peerInfoFromStore.addrs.length}. Addrs: ${peerInfoFromStore.addrs.map((a) => a.toString()).join(", ")}.');
          if (peerInfoFromStore.addrs.isNotEmpty) {
            return AddrInfo(p_id_from_result, peerInfoFromStore.addrs.toList());
          } else {
            _log.warning('$logPrefix For target $targetShortId, PeerInfo found in peerstore BUT addrs list is EMPTY. Returning AddrInfo with empty addrs.');
            return AddrInfo(p_id_from_result, []);
          }
        } else {
          _log.warning('$logPrefix For target $targetShortId, PeerInfo was NOT found in local peerstore after lookup. Returning AddrInfo with empty addrs.');
          return AddrInfo(p_id_from_result, []);
        }
      }
    }
    _log.warning('$logPrefix Target peer $targetShortId was NOT found in the final result.peers list from lookup. Returning null.');
    return null;
  }

  @override
  Future<void> putValue(String key, Uint8List value, {RoutingOptions? options}) async {
    final Logger putLogger = Logger('IpfsDHT.putValue');
    putLogger.info('[${_host.id.toBase58().substring(0,6)}] putValue called for key: $key');

    if (!_started) {
      putLogger.fine('[${_host.id.toBase58().substring(0,6)}] DHT not started, calling start().');
      await start();
      putLogger.fine('[${_host.id.toBase58().substring(0,6)}] DHT start() completed.');
    }

    // Create a record with the key and value.
    // Use codeUnits (not utf8.encode) to preserve raw binary bytes in keys
    // like /pk/<multihash-bytes> where the suffix is raw binary, not UTF-8 text.
    final keyBytes = Uint8List.fromList(key.codeUnits);
    final record = Record(
      key: keyBytes,
      value: Uint8List.fromList(value),
      timeReceived: DateTime.now().millisecondsSinceEpoch,
      author: _host.id.toBytes(),
      signature: Uint8List(0), // In a real implementation, this would be a signature
    );

    // Store the record locally
    putLogger.fine('[${_host.id.toBase58().substring(0,6)}] Storing record locally for key: $key...');
    await putRecordToDatastore(record);
    putLogger.info('[${_host.id.toBase58().substring(0,6)}] Record stored locally for key: $key. Datastore size: ${_datastore.length}');

    // Find the closest peers to the key
    putLogger.fine('[${_host.id.toBase58().substring(0,6)}] Finding closest peers for key: $key...');
    final result = await runLookupWithFollowup(
      target: keyBytes,
      queryFn: (peer) async {
        // Query the peer for peers close to the key
        final message = Message(
          type: MessageType.findNode,
          key: keyBytes,
        );

        // Send the message to the peer
        final response = await _sendMessage(peer, message);

        // Convert the response to AddrInfo objects
        return response.closerPeers.map((p) => AddrInfo(
          PeerId.fromBytes(p.id),
          p.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList(),
        )).toList();
      },
      stopFn: (peerset) {
        // Stop when we've queried enough peers
        return peerset.getClosestInStates([PeerState.queried]).length >= _options.resiliency;
      },
    );

    // Send PUT_VALUE messages to the closest peers
    for (final peer in result.peers) {
      try {
        final message = Message(
          type: MessageType.putValue,
          key: keyBytes,
          record: record,
        );

        await _sendMessage(peer, message);
      } catch (e) {
        // Ignore errors
      }
    }
  }

  @override
  Future<Uint8List?> getValue(String key, RoutingOptions? options) async {
    final Logger getValueLogger = Logger('IpfsDHT.getValue');
    getValueLogger.info('[${_host.id.toBase58().substring(0,6)}] getValue called for key: $key. Options: $options');

    if (!_started) {
      await start();
    }

    // Convert the key to bytes
    final keyBytes = Uint8List.fromList(key.codeUnits);

    // Check if the value is stored locally
    final localRecord = await checkLocalDatastore(keyBytes);
    if (localRecord != null) {
      getValueLogger.info('[${_host.id.toBase58().substring(0,6)}] getValue for key "$key": Found in local datastore. Returning value.');
      return localRecord.value;
    }
    getValueLogger.info('[${_host.id.toBase58().substring(0,6)}] getValue for key "$key": Not found in local datastore. Proceeding with network lookup.');

    final controller = StreamController<Record>();
    LookupWithFollowupResult lookupResult;

    getValueLogger.info('[${_host.id.toBase58().substring(0,6)}] getValue for key "$key": About to call runLookupWithFollowup.');
    try {
      lookupResult = await runLookupWithFollowup(
        target: keyBytes,
        queryFn: (peer) async {
          final message = Message(
            type: MessageType.getValue,
            key: keyBytes,
          );
          final response = await _sendMessage(peer, message);
          getValueLogger.fine('[${_host.id.toBase58().substring(0,6)}] getValue.queryFn for key "$key" from peer ${peer.toBase58().substring(0,6)}: response.record is ${response.record != null ? "NOT null (value: ${utf8.decode(response.record!.value, allowMalformed: true)})" : "null"}. CloserPeers: ${response.closerPeers.length}');
          if (response.record != null) {
            if (!controller.isClosed) controller.add(response.record!);
          }
          return response.closerPeers.map((p) => AddrInfo(
            PeerId.fromBytes(p.id),
            p.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList(),
          )).toList();
        },
        stopFn: (peerset) {
          return peerset.getClosestInStates([PeerState.queried]).length >= _options.resiliency;
        },
      );
    } catch (e, s) {
      getValueLogger.severe('[${_host.id.toBase58().substring(0,6)}] getValue for key "$key": runLookupWithFollowup call FAILED directly: $e\n$s', e, s);
      if (e is MaxRetriesExceededException) { // If runLookupWithFollowup itself somehow throws this
        throw e;
      }
      // For other catastrophic errors from runLookupWithFollowup, wrap and rethrow or handle as appropriate.
      // For now, let's assume it means no value can be retrieved.
      throw Exception('Lookup process for key "$key" failed catastrophically: $e');
    } finally {
        if (!controller.isClosed) {
            getValueLogger.fine('[${_host.id.toBase58().substring(0,6)}] getValue for key "$key": Closing record controller in finally block after runLookupWithFollowup.');
            controller.close();
        }
    }
    
    getValueLogger.info('[${_host.id.toBase58().substring(0,6)}] getValue for key "$key": runLookupWithFollowup completed. TerminationReason: ${lookupResult.terminationReason}, ErrorsInResult: ${lookupResult.errors.length}');
    for (final err in lookupResult.errors) {
        getValueLogger.warning('[${_host.id.toBase58().substring(0,6)}] getValue for key "$key": Error reported in lookupResult: $err');
    }

    List<Record> receivedRecords = [];
    await for (final record in controller.stream) {
        receivedRecords.add(record);
    }
    getValueLogger.info('[${_host.id.toBase58().substring(0,6)}] getValue for key "$key": Collected ${receivedRecords.length} records from controller stream.');

    final maxRetriesError = lookupResult.errors.firstWhereOrNull((err) => err is MaxRetriesExceededException);

    if (receivedRecords.isEmpty) {
      if (maxRetriesError != null) {
        getValueLogger.warning('[${_host.id.toBase58().substring(0,6)}] getValue for key "$key": No records received AND MaxRetriesExceededException found in lookup result. Rethrowing.');
        throw maxRetriesError;
      }
      getValueLogger.info('[${_host.id.toBase58().substring(0,6)}] getValue for key "$key": No records received from network (after processing controller). Returning null.');
      return null; 
    }
    
    getValueLogger.info('[${_host.id.toBase58().substring(0,6)}] getValue for key "$key": Received ${receivedRecords.length} records from network. Proceeding with validation.');

    List<Uint8List> validRecordValues = [];
    for (final record in receivedRecords) {
        try {
            getValueLogger.finer('[${_host.id.toBase58().substring(0,6)}] getValue for key "$key": Validating record (${record.value.length} bytes)');
            _recordValidator.validate(key, record.value); 
            getValueLogger.finer('[${_host.id.toBase58().substring(0,6)}] getValue for key "$key": Record PASSED validation.');
            validRecordValues.add(record.value);
        } catch (e) {
            getValueLogger.warning('[${_host.id.toBase58().substring(0,6)}] getValue for key "$key": Record failed validation: $e.');
        }
    }

    if (validRecordValues.isEmpty) {
        if (maxRetriesError != null) {
            getValueLogger.warning('[${_host.id.toBase58().substring(0,6)}] getValue for key "$key": No VALID records AND MaxRetriesExceededException found in lookup result. Rethrowing.');
            throw maxRetriesError;
        }
        getValueLogger.warning('[${_host.id.toBase58().substring(0,6)}] getValue for key "$key": No records passed validation. Returning null.');
        return null;
    }
    
    getValueLogger.info('[${_host.id.toBase58().substring(0,6)}] getValue for key "$key": ${validRecordValues.length} records passed validation. Selecting best.');

    final bestValueIndex = await _recordValidator.select(key, validRecordValues);
    final bestValue = validRecordValues[bestValueIndex];
    
    getValueLogger.info('[${_host.id.toBase58().substring(0,6)}] getValue for key "$key": final bestValue selected (len: ${bestValue.length}). Returning value.');
    return bestValue;
  }

  /// Sends a message to a peer and returns the response
  Future<Message> _sendMessage(PeerId peer, Message message) async {
    final String shortPeerId = peer.toBase58().substring(0, 6);
    final String selfShortId = _host.id.toBase58().substring(0, 6);
    _log.info('[$selfShortId] Attempting to send ${message.type} to $shortPeerId. Key: ${message.key != null ? base64Encode(message.key!) : 'N/A'}');

    int attempt = 0;
    dynamic lastError;

    while (attempt < _options.maxRetryAttempts) {
      attempt++;
      P2PStream<Uint8List>? stream;
      List<int> responseBytes = [];

      try {
        _log.fine('[$selfShortId] Attempt $attempt: Dialing $shortPeerId for ${message.type}.');
        await dialPeer(peer); // dialPeer includes its own logging and rethrows on failure
        _log.fine('[$selfShortId] Attempt $attempt: Dial to $shortPeerId successful. Opening new stream.');

        // Create stream with timeout but handle timeout exceptions gracefully
        // This maintains protection against hanging operations while preventing app crashes
        try {
          stream = await _host.newStream(peer, [AminoConstants.protocolID], Context())
              .timeout(Duration(seconds: 10)) as P2PStream<Uint8List>?;
        } on TimeoutException catch (e) {
          _log.warning('[$selfShortId] Attempt $attempt: Stream creation timed out for $shortPeerId: $e');
          throw Exception('Stream creation timed out: $e');
        }
        
        if (stream == null) { // Should not happen if newStream throws on failure, but good for robustness
          throw Exception('Failed to create stream, newStream returned null.');
        }
        _log.fine('[$selfShortId] Attempt $attempt: Stream ${stream!.id()} opened to $shortPeerId.');

        final messageBytes = encodeMessage(message);
        _log.fine('[$selfShortId] Attempt $attempt: Writing protobuf message to stream ${stream.id()} (Size: ${messageBytes.length})');
        
        // Add timeout protection to stream operations
        await stream.write(messageBytes).timeout(Duration(seconds: 5), onTimeout: () {
          _log.warning('[$selfShortId] Attempt $attempt: Write operation timed out for $shortPeerId');
          throw TimeoutException('Write operation timed out', Duration(seconds: 5));
        });
        
        _log.fine('[$selfShortId] Attempt $attempt: Message written to stream ${stream.id()}. Reading response...');

        responseBytes = await stream.read().timeout(Duration(seconds: 10), onTimeout: () {
          _log.warning('[$selfShortId] Attempt $attempt: Read operation timed out for $shortPeerId');
          throw TimeoutException('Read operation timed out', Duration(seconds: 10));
        });
        
        _log.info('[$selfShortId] Attempt $attempt: Response received from $shortPeerId on stream ${stream.id()}. Length: ${responseBytes.length}');
        
        await stream.close();
        _log.fine('[$selfShortId] Attempt $attempt: Client-side stream ${stream.id()} closed after successful communication.');
        
        stream = null; // Clear stream variable after successful close

        // Parse the protobuf response
        Message responseMessage;
        try {
          responseMessage = decodeMessage(Uint8List.fromList(responseBytes));
          _log.info('[$selfShortId] Attempt $attempt: Parsed ${responseMessage.type} response from $shortPeerId. Success.');
          if (responseMessage.record != null) {
            _log.finer('[$selfShortId] Received record in response: key=${base64Encode(responseMessage.record!.key)}, value=${base64Encode(responseMessage.record!.value)} (decoded: ${utf8.decode(responseMessage.record!.value, allowMalformed: true)})');
          }
          return responseMessage;
        } catch (e, s) {
          _log.severe('[$selfShortId] Attempt $attempt: Error decoding protobuf response from $shortPeerId. Length: ${responseBytes.length}. Error: $e', e, s);
          throw Exception('Failed to decode protobuf response from $shortPeerId: $e');
        }

      } catch (e, s) {
        lastError = e;
        _log.warning('[$selfShortId] Attempt $attempt to send ${message.type} to $shortPeerId failed: $e', e, s);

        if (stream != null) {
          try {
            await stream!.reset(); // Use reset for abrupt closure on error
            _log.fine('[$selfShortId] Stream ${stream.id()} reset after error on attempt $attempt.');
          } catch (resetErr, resetStack) {
            _log.warning('[$selfShortId] Error resetting stream ${stream.id()} after error on attempt $attempt: $resetErr', resetErr, resetStack);
          }
          stream = null;
        }

        if (_isRetryableConnectionError(e) && attempt < _options.maxRetryAttempts) {
          num baseBackoffMillis = _options.retryInitialBackoff.inMilliseconds * math.pow(_options.retryBackoffFactor, attempt - 1);
          double currentBackoffMillis = baseBackoffMillis.toDouble();

          if (currentBackoffMillis > _options.retryMaxBackoff.inMilliseconds) {
            currentBackoffMillis = _options.retryMaxBackoff.inMilliseconds.toDouble();
          }
          // Add jitter: +/- 20% of current backoff
          final jitterRange = currentBackoffMillis * 0.2;
          final jitter = (math.Random().nextDouble() * (2 * jitterRange)) - jitterRange;
          final delayMillis = (currentBackoffMillis + jitter).toInt();
          final delay = Duration(milliseconds: math.max(0, delayMillis)); // Ensure non-negative

          _log.info('[$selfShortId] Retryable error on attempt $attempt for ${message.type} to $shortPeerId. Retrying in $delay...');
          await Future.delayed(delay);
          continue; // Next attempt
        } else {
          _log.severe('[$selfShortId] Final attempt $attempt failed for ${message.type} to $shortPeerId or error not retryable: $e', e, s);
          if (_isRetryableConnectionError(e)) { // Max attempts reached for a retryable error
            throw MaxRetriesExceededException(
                'Failed to send ${message.type} to ${peer.toBase58()} after $attempt attempts', e);
          }
          rethrow; // Non-retryable error
        }
      }
    }
    // Should not be reached if logic is correct, but as a safeguard:
    throw MaxRetriesExceededException(
        'Exhausted retries sending ${message.type} to ${peer.toBase58()} after $attempt attempts', lastError);
  }

  /// Sends a message to a peer without expecting a response (fire-and-forget).
  /// Used for ADD_PROVIDER per the libp2p Kademlia DHT spec.
  Future<void> _sendMessageFireAndForget(PeerId peer, Message message) async {
    final String shortPeerId = peer.toBase58().substring(0, 6);
    final String selfShortId = _host.id.toBase58().substring(0, 6);
    _log.info('[$selfShortId] Sending fire-and-forget ${message.type} to $shortPeerId');

    P2PStream<Uint8List>? stream;
    try {
      await dialPeer(peer);

      stream = await _host.newStream(peer, [AminoConstants.protocolID], Context())
          .timeout(Duration(seconds: 10)) as P2PStream<Uint8List>?;

      if (stream == null) {
        throw Exception('Failed to create stream, newStream returned null.');
      }

      final messageBytes = encodeMessage(message);
      await stream.write(messageBytes).timeout(Duration(seconds: 5));
      await stream.close();
      stream = null;
      _log.info('[$selfShortId] Fire-and-forget ${message.type} sent to $shortPeerId');
    } catch (e, s) {
      _log.warning('[$selfShortId] Fire-and-forget ${message.type} to $shortPeerId failed: $e', e, s);
      if (stream != null) {
        try { await stream!.reset(); } catch (_) {}
      }
      rethrow;
    }
  }

  /// Helper method to compare byte arrays
  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Gets the routing table
  RoutingTable get routingTable => _routingTable;

  /// Gets the network size estimator
  Estimator get nsEstimator => _nsEstimator;

  /// Gets the provider manager
  ProviderManager get providerManager => _providerManager;

  /// Gets the DHT options
  DHTOptions get options => _options;

  /// Sends a message to a peer and returns the response (public version of _sendMessage)
  Future<Message> sendMessage(PeerId peer, Message message) async {
    return _sendMessage(peer, message);
  }

  bool _isRetryableConnectionError(dynamic error) {
    if (error is Exception) {
      final errorString = error.toString().toLowerCase();
      // Specific exception from previous task
      if (errorString.contains('connection is closed')) {
        return true;
      }
      // Common socket-level errors
      if (errorString.contains('connection refused') ||
          errorString.contains('connection reset by peer') ||
          errorString.contains('network is unreachable') ||
          errorString.contains('host is down') ||
          errorString.contains('broken pipe') ||
          errorString.contains('socketexception') || // Generic socket issues
          errorString.contains('os error: connection timed out')) { // OS-level timeout
        return true;
      }
    }
    // Add more checks for multiplexer errors if their string representations are known
    // e.g., "stream reset", "session is closed"
    return false;
  }

  /// Runs a lookup with followup using the new QueryRunner implementation.
  /// 
  /// This replaces the old broken query implementation with our robust QueryRunner.
  /// Maintains API compatibility with the existing DHT operations.
  Future<LookupWithFollowupResult> runLookupWithFollowup({
    required Uint8List target,
    required Future<List<AddrInfo>> Function(PeerId peer) queryFn,
    required bool Function(QueryPeerset peerset) stopFn,
  }) async {
    final id =_host.id.toBase58();
    final logPrefix = '[${id.substring(id.length -6)}.runLookupWithFollowup]';
    _log.info('$logPrefix Starting lookup for target: ${base64Encode(target).substring(0, 10)}...');

    // Get bootstrap peers for the query
    final bootstrapPeers = await getBootstrapPeers();
    if (bootstrapPeers.isEmpty) {
      _log.warning('$logPrefix No bootstrap peers available for lookup');
      return LookupWithFollowupResult(
        peers: [],
        terminationReason: LookupTerminationReason.noMorePeers,
        errors: [],
      );
    }

    // Create QueryRunner with our configuration
    final runner = QueryRunner(
      target: target,
      queryFn: queryFn,
      stopFn: stopFn,
      initialPeers: bootstrapPeers.map((p) => p.id).toList(),
      alpha: _options.resiliency, // Use DHT's resiliency setting for concurrency
      timeout: Duration(seconds: 30), // Configurable timeout
    );

    // Track the QueryRunner for proper cleanup
    _activeQueryRunners.add(runner);

    try {
      // Run the query
      final result = await runner.run();
      
      _log.info('$logPrefix Query completed with reason: ${result.reason}. Found ${result.peerset.getClosestInStates([PeerState.queried, PeerState.heard]).length} peers');

      // Handle peer eviction for failed queries
      final unreachablePeers = result.peerset.getClosestInStates([PeerState.unreachable]);
      if (unreachablePeers.isNotEmpty) {
        _log.info('$logPrefix Evicting ${unreachablePeers.length} unreachable peers from routing table');
        for (final peer in unreachablePeers) {
          try {
            await _routingTable.removePeer(peer);
            _log.fine('$logPrefix Evicted peer ${peer.toBase58().substring(0,6)} from routing table after failed query');
          } catch (e) {
            _log.warning('$logPrefix Failed to evict peer ${peer.toBase58().substring(0,6)} from routing table: $e');
          }
        }
      }

      // Convert QueryResult to LookupWithFollowupResult for API compatibility
      return LookupWithFollowupResult(
        peers: result.peerset.getClosestInStates([
          PeerState.queried,
          PeerState.heard,
          PeerState.waiting,
        ]),
        terminationReason: _mapTerminationReason(result.reason),
        errors: result.errors,
      );
    } catch (e, s) {
      _log.severe('$logPrefix Query failed with exception: $e', e, s);
      return LookupWithFollowupResult(
        peers: [],
        terminationReason: LookupTerminationReason.cancelled,
        errors: [e],
      );
    } finally {
      // Always clean up resources and remove from tracking
      _activeQueryRunners.remove(runner);
      await runner.dispose();
    }
  }

  /// Maps QueryRunner termination reasons to legacy lookup termination reasons
  LookupTerminationReason _mapTerminationReason(QueryTerminationReason reason) {
    switch (reason) {
      case QueryTerminationReason.Success:
        return LookupTerminationReason.success;
      case QueryTerminationReason.Timeout:
        return LookupTerminationReason.timeout;
      case QueryTerminationReason.Cancelled:
        return LookupTerminationReason.cancelled;
      case QueryTerminationReason.NoMorePeers:
        return LookupTerminationReason.noMorePeers;
    }
  }

  // --- Discovery Interface Methods ---

  @override
  Future<Duration> advertise(String ns, [List<DiscoveryOption> options = const []]) async {
    final Logger advertiseLogger = Logger('IpfsDHT.advertise');
    advertiseLogger.info('[${_host.id.toBase58().substring(0,6)}] advertise called for namespace: "$ns"');

    if (!_started) {
      advertiseLogger.fine('[${_host.id.toBase58().substring(0,6)}] DHT not started, calling start().');
      await start();
      advertiseLogger.fine('[${_host.id.toBase58().substring(0,6)}] DHT start() completed.');
    }

    // final discoveryOpts = DiscoveryOptions().apply(options); // Process options if needed for TTL later
    // For now, the TTL of the advertisement is governed by the DHT's provider record validity.
    advertiseLogger.fine('[${_host.id.toBase58().substring(0,6)}] Converting namespace "$ns" to CID.');
    final cid = CID.fromString(ns); // Ensure this CID conversion is robust for namespaces.
                                    // Consider if namespaces need a specific prefix or format
                                    // before being turned into CIDs.
    advertiseLogger.info('[${_host.id.toBase58().substring(0,6)}] Namespace "$ns" converted to CID: ${cid.toString()}. Calling provide(announce: true).');

    // Announce that this node provides the "content" identified by the namespace CID.
    // The `provide` method internally uses `_providerManager.addProvider`
    // and then announces to the network.
    await provide(cid, true); // true to announce
    advertiseLogger.info('[${_host.id.toBase58().substring(0,6)}] provide(announce: true) for CID ${cid.toString()} completed.');

    // Return the effective TTL of this advertisement.
    // This would be the duration for which provider records are kept.
    advertiseLogger.info('[${_host.id.toBase58().substring(0,6)}] Advertisement for "$ns" (CID: ${cid.toString()}) completed. Returning TTL: ${_options.provideValidity}');
    return _options.provideValidity;
  }

  @override
  Future<Stream<AddrInfo>> findPeers(String ns, [List<DiscoveryOption> options = const []]) async {
    if (!_started) {
      await start();
    }

    final discoveryOpts = DiscoveryOptions().apply(options);
    final effectiveLimit = discoveryOpts.limit ?? 0; // 0 for unbounded in findProvidersAsync

    final cid = CID.fromString(ns); // Same ns to CID consideration as above.

    // findProvidersAsync will return a stream of peers who have "provided" this namespace CID.
    return findProvidersAsync(cid, effectiveLimit);
  }

  /// Generates a refresh key for a given Common Prefix Length (CPL)
  Future<String> _generateRefreshKey(int cpl) async {
    return cpl.toString();
  }

  /// Performs a refresh query to discover peers for a given key
  Future<void> _performRefreshQuery(String key) async {
    if (!_started) return;
    
    final cplToQuery = int.tryParse(key);
    if (cplToQuery == null) {
      _log.fine('RefreshQuery: key "$key" is not a CPL, skipping.');
      return;
    }
    
    _log.fine('RefreshQuery: Performing lookup for CPL $cplToQuery');
    
    try {
      // Generate a target key for this CPL
      final targetKey = await _routingTable.genRandomPeerIdWithCpl(cplToQuery);
      
      // Perform a network query to discover peers
      final result = await getClosestPeers(targetKey, networkQueryEnabled: true);
      
      // Add discovered peers to routing table
      var addedCount = 0;
      for (final addrInfo in result) {
        if (addrInfo.id != _host.id) { // Don't add self
          final added = await _routingTable.tryAddPeer(addrInfo.id, queryPeer: true);
          if (added) {
            addedCount++;
            // Store addresses in peerstore
            await _host.peerStore.addrBook.addAddrs(addrInfo.id, addrInfo.addrs, Duration(hours: 1));
          }
        }
      }
      
      _log.fine('RefreshQuery: Added $addedCount new peers for CPL $cplToQuery');
    } catch (e, s) {
      _log.warning('RefreshQuery: Error during query for CPL $cplToQuery: $e', e, s);
    }
  }

  /// Performs a ping to verify peer connectivity
  Future<void> _performRefreshPing(PeerId peerId) async {
    if (!_started) return;
    
    try {
      // Try to dial the peer to verify connectivity
      await dialPeer(peerId);
      _log.fine('RefreshPing: Successfully pinged ${peerId.toBase58().substring(0, 6)}');
    } catch (e) {
      _log.fine('RefreshPing: Failed to ping ${peerId.toBase58().substring(0, 6)}: $e');
      // Remove unreachable peer from routing table
      await _routingTable.removePeer(peerId);
    }
  }
}
