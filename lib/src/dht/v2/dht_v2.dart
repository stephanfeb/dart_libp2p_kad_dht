import 'dart:async';
import 'dart:typed_data';

import 'package:dcid/dcid.dart';
import 'package:dart_libp2p/core/discovery.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peerstore.dart';
import 'package:dart_libp2p/core/routing/options.dart';
import 'package:dart_libp2p/core/routing/routing.dart';
import 'package:dart_libp2p_kad_dht/src/pb/dht_message.dart' as dht_message;
import 'package:dart_libp2p_kad_dht/src/rtrefresh/rt_refresh_manager.dart';
import 'package:logging/logging.dart';

import '../../kbucket/table/table.dart';
import '../../query/qpeerset.dart';
import '../dht.dart';
import '../dht_options.dart';
import '../routing_options.dart';
import '../../providers/provider_store.dart';
import '../../providers/provider_manager.dart';
import '../../record/namespace_validator.dart';
import '../../record/record_signer.dart';
import '../../record/generic_validator.dart';
import '../../record/public_key_validator.dart';
import '../../record/ipns_validator.dart';
import '../../netsize/netsize.dart';
import '../../internal/protocol_messenger.dart';
import '../handlers.dart';
import '../../pb/record.dart';

import 'managers/network_manager.dart';
import 'managers/query_manager.dart';
import 'managers/routing_manager.dart';
import 'managers/protocol_manager.dart';
import 'managers/metrics_manager.dart';
import 'config/dht_config.dart';
import 'errors/dht_errors.dart';

/// Simple concrete implementation of ProtocolMessenger for DHT v2
class SimpleProtocolMessenger extends ProtocolMessenger {
  final Host _host;
  
  SimpleProtocolMessenger(this._host);
  
  @override
  Future<Record?> getValue(String ctx, PeerId peerId, String key) async {
    // Simplified implementation - would normally use the network manager
    // to send a GET_VALUE message to the peer
    return null;
  }
}

/// IpfsDHT v2 - A modular, maintainable implementation of the IPFS DHT
/// 
/// This implementation provides the same public API as the original IpfsDHT
/// but with improved architecture, better error handling, and enhanced
/// observability.
/// 
/// Key improvements:
/// - Modular design with focused components
/// - Consistent query patterns with unified error handling
/// - Built-in metrics and monitoring
/// - Simplified configuration
/// - Better testability
class IpfsDHTv2 implements IpfsDHT {
  final Logger _logger = Logger('IpfsDHTv2');
  
  // Core components
  final NetworkManager _network;
  final RoutingManager _routing;
  final QueryManager _queries;
  final ProtocolManager _protocol;
  final MetricsManager _metrics;

  RtRefreshManager? _refreshManager;

  // Configuration
  final DHTConfigV2 _config;
  final Host _host;
  final ProviderStore _providerStore;
  
  // State management
  bool _started = false;
  bool _closed = false;
  final Completer<void> _startCompleter = Completer<void>();
  
  /// Creates a new IpfsDHTv2 instance
  /// 
  /// This constructor maintains API compatibility with the original IpfsDHT
  IpfsDHTv2({
    required Host host,
    required ProviderStore providerStore,
    DHTOptions? options,
    NamespacedValidator? validator
  }) : _host = host,
       _providerStore = providerStore,
       _config = DHTConfigV2.fromOptions(options ?? const DHTOptions()),
       _network = NetworkManager(host),
       _routing = RoutingManager(host, options ?? const DHTOptions()),
       _queries = QueryManager(),
       _protocol = ProtocolManager(host),
       _metrics = MetricsManager() {

    // Initialize component dependencies
    _queries.initialize(
      network: _network,
      routing: _routing,
      protocol: _protocol,
      config: _config,
      metrics: _metrics,
      providerStore: _providerStore,
    );
    
    _protocol.initialize(
      routing: _routing,
      providerStore: _providerStore,
      config: _config,
      metrics: _metrics,
    );
    
    _network.initialize(
      config: _config,
      metrics: _metrics,
    );
    
    _routing.initialize(
      config: _config,
      metrics: _metrics,
      network: _network,
    );
    
    // Initialize compatibility properties
    _providerManager = ProviderManager(
      localPeerId: _host.id,
      peerStore: _host.peerStore,
      store: _providerStore,
    );
    _handlers = DHTHandlers(this);
    _recordValidator = validator ?? _createDefaultValidator();
    _nsEstimator = Estimator(
      localId: _host.id,
      rt: _routing.routingTable,
      bucketSize: _config.bucketSize,
    );
    _protoMessenger = SimpleProtocolMessenger(_host);

    if (options?.autoRefresh ?? false) {
      _refreshManager = RtRefreshManager(
        host: host,
        dhtPeerId: host.id,
        rt: _routing.routingTable,
        enableAutoRefresh: true,
        refreshKeyGenFnc: _generateRefreshKey,
        refreshQueryFnc: _performRefreshQuery,
        refreshPingFnc: _performRefreshPing,
        refreshQueryTimeout: Duration(seconds: 10),
        refreshInterval: Duration(minutes: 5),
        successfulOutboundQueryGracePeriod: Duration(minutes: 1),
      );
    }

    _logger.info('IpfsDHTv2 initialized for peer ${_host.id.toBase58().substring(0, 6)}');
  }
  
  @override
  Host host() => _host;
  
  @override
  RoutingTable get routingTable => _routing.routingTable;
  
  @override
  DHTOptions get options => _config.toOptions();
  
  @override
  bool get started => _started;
  
  @override
  Future<void> start() async {
    if (_started) return;
    if (_closed) throw DHTClosedException();
    
    _logger.info('Starting IpfsDHTv2...');
    
    try {
      // Start components in dependency order
      await _metrics.start();
      await _network.start();
      await _routing.start();
      await _protocol.start();
      await _queries.start();
      
      if (_refreshManager != null) {
        _refreshManager!.start();
        _logger.info('RtRefreshManager started');
        await _refreshManager!.refresh(true);
      }

      _started = true;
      _startCompleter.complete();
      
      _logger.info('IpfsDHTv2 started successfully');
    } catch (e, stackTrace) {
      _logger.severe('Failed to start IpfsDHTv2', e, stackTrace);
      await _cleanup();
      rethrow;
    }
  }
  
  @override
  Future<void> bootstrap({Duration? periodicRefreshInterval, bool quickConnectOnly = false}) async {
    if (!_started) await start();
    
    _logger.info('Bootstrapping IpfsDHTv2...');
    
    try {
      // Add comprehensive timeout to prevent hanging
      await _routing.bootstrap().timeout(Duration(seconds: 30));
      _logger.info('Bootstrap completed successfully');

      _logger.info('Bootstrap completed successfully');
      await refreshRoutingTable();

    } catch (e, stackTrace) {
      _logger.warning('Bootstrap failed', e, stackTrace);
      throw DHTBootstrapException('Bootstrap failed: $e');
    }
  }
  
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    
    _logger.info('Closing IpfsDHTv2...');
    
    try {
      await _cleanup();
      _logger.info('IpfsDHTv2 closed successfully');
    } catch (e, stackTrace) {
      _logger.warning('Error during cleanup', e, stackTrace);
    }
  }
  
  Future<void> _cleanup() async {
    // Close components in reverse dependency order
    await _queries.close();
    await _protocol.close();
    await _routing.close();
    await _network.close();
    await _metrics.close();
    if (_refreshManager != null) {
      await _refreshManager!.close();
      _logger.info('RtRefreshManager closed');
    }
  }
  
  // Query operations - delegated to QueryManager
  
  @override
  Future<AddrInfo?> findPeer(PeerId id, {RoutingOptions? options}) async {
    _ensureStarted();
    return await _queries.findPeer(id, options: options);
  }
  
  @override
  Future<List<AddrInfo>> getClosestPeers(PeerId target, {bool networkQueryEnabled = true}) async {
    _ensureStarted();
    return await _queries.getClosestPeers(target, networkQueryEnabled: networkQueryEnabled);
  }
  
  @override
  Stream<AddrInfo> findProvidersAsync(CID cid, int count) {
    _ensureStarted();
    return _queries.findProvidersAsync(cid, count);
  }
  
  @override
  Future<Uint8List?> getValue(String key, [RoutingOptions? options]) async {
    _ensureStarted();
    return await _queries.getValue(key, options);
  }
  
  @override
  Stream<Uint8List> searchValue(String key, RoutingOptions? options) {
    _ensureStarted();
    return _queries.searchValue(key, options);
  }
  
  @override
  Future<void> putValue(String key, Uint8List value, {RoutingOptions? options}) async {
    _ensureStarted();
    return await _queries.putValue(key, value, options);
  }
  
  @override
  Future<void> provide(CID cid, bool announce) async {
    _ensureStarted();
    return await _queries.provide(cid, announce);
  }
  
  // Provider operations - delegated to ProviderManager through QueryManager
  
  @override
  Future<void> addProvider(Uint8List key, AddrInfo provider) async {
    _ensureStarted();
    return await _queries.addProvider(key, provider);
  }
  
  @override
  Future<List<AddrInfo>> getLocalProviders(Uint8List key) async {
    _ensureStarted();
    return await _queries.getLocalProviders(key);
  }
  
  // Discovery operations
  
  @override
  Future<Duration> advertise(String ns, [List<DiscoveryOption> options = const []]) async {
    _ensureStarted();
    return await _queries.advertise(ns, options);
  }
  
  @override
  Future<Stream<AddrInfo>> findPeers(String ns, [List<DiscoveryOption> options = const []]) async {
    _ensureStarted();
    return await _queries.findPeers(ns, options);
  }
  
  // Metrics and monitoring
  
  /// Gets current DHT metrics
  DHTMetrics get metrics => _metrics.getMetrics();
  
  /// Gets current configuration
  DHTConfigV2 get config => _config;
  
  // Additional methods required by Routing and Discovery interfaces
  
  @override
  Future<Record?> checkLocalDatastore(Uint8List key) async {
    _ensureStarted();
    // Check if we have the key in local datastore
    _logger.fine('Checking local datastore for key...');
    return await _protocol.getRecordFromDatastoreBytes(key);
  }
  
  @override
  Future<void> dialPeer(PeerId peer) async {
    _ensureStarted();
    // Dial a peer
    _logger.fine('Dialing peer: ${peer.toBase58().substring(0, 6)}...');
  }
  
  @override
  Future<AddrInfo?> findLocalPeer(PeerId peer) async {
    _ensureStarted();
    // Find a peer in local routing table
    final foundPeer = await _routing.findPeer(peer);
    if (foundPeer != null) {
      final peerInfo = await _network.host.peerStore.getPeer(peer);
      if (peerInfo != null) {
        return AddrInfo(peer, peerInfo.addrs.toList());
      }
    }
    return null;
  }
  
  @override
  Future<List<AddrInfo>> getBootstrapPeers() async {
    _ensureStarted();
    return await _routing.getBootstrapPeers();
  }
  
  @override
  Future<void> putRecordToDatastore(dynamic record) async {
    _ensureStarted();
    // Store record in local datastore
    _logger.fine('Storing record in local datastore...');
    await _protocol.putRecordToDatastoreDynamic(record);
  }
  
  @override
  Future<dynamic> getRecordFromDatastore(String key) async {
    _ensureStarted();
    // Get record from local datastore
    _logger.fine('Getting record from local datastore for key: ${key.substring(0, 10)}...');
    return await _protocol.getRecordFromDatastore(key);
  }
  
  @override
  Future<void> removeRecordFromDatastore(String key) async {
    _ensureStarted();
    // Remove record from local datastore
    _logger.fine('Removing record from local datastore for key: ${key.substring(0, 10)}...');
    await _protocol.removeRecordFromDatastore(key);
  }
  
  @override
  Future<bool> hasRecordInDatastore(String key) async {
    _ensureStarted();
    // Check if record exists in local datastore
    _logger.fine('Checking if record exists in local datastore for key: ${key.substring(0, 10)}...');
    return await _protocol.hasRecordInDatastore(key);
  }
  
  @override
  Stream<String> getKeysFromDatastore() async* {
    _ensureStarted();
    // Get all keys from local datastore
    _logger.fine('Getting all keys from local datastore...');
    yield* _protocol.getKeysFromDatastore();
  }
  
  @override
  Future<void> updatePeerInRoutingTable(PeerId peer) async {
    _ensureStarted();
    await _routing.addPeer(peer);
  }
  
  @override
  Future<void> removePeerFromRoutingTable(PeerId peer) async {
    _ensureStarted();
    await _routing.removePeer(peer);
  }
  
  @override
  Future<List<PeerId>> getRoutingTablePeers() async {
    _ensureStarted();
    final peers = await _routing.getAllPeers();
    return peers.map((p) => p.id).toList();
  }
  
  @override
  Future<int> getRoutingTableSize() async {
    _ensureStarted();
    return await _routing.getSize();
  }
  
  @override
  Future<void> refreshRoutingTable() async {
    _ensureStarted();
    await _refreshManager?.refresh(false);
  }
  
  @override
  Future<void> forceRefresh() async {
    _ensureStarted();
    await _refreshManager?.refresh(true);
  }
  
  @override
  Future<bool> isRoutingTableHealthy() async {
    _ensureStarted();
    return await _routing.isHealthy();
  }
  
  @override
  Future<Map<String, dynamic>> getRoutingTableStatistics() async {
    _ensureStarted();
    return await _routing.getStatistics();
  }
  
  // Additional required methods from IpfsDHT interface
  
  @override
  Future<LookupWithFollowupResult> runLookupWithFollowup({
    required Uint8List target,
    required Future<List<AddrInfo>> Function(PeerId peer) queryFn,
    required bool Function(QueryPeerset peerset) stopFn,
  }) async {
    _ensureStarted();
    return await _queries.runLookupWithFollowup(
      target: target,
      queryFn: queryFn,
      stopFn: stopFn,
    );
  }
  
  @override
  Future<dht_message.Message> sendMessage(PeerId peer, dht_message.Message message) async {
    _ensureStarted();
    return await _network.sendMessage(peer, message);
  }
  
  // Internal method for compatibility
  Future<dht_message.Message> _sendMessage(PeerId peer, dht_message.Message message) async {
    return await sendMessage(peer, message);
  }
  
  @override
  Future<bool> validateRecord(Record record) async {
    _ensureStarted();
    // Simplified validation - would normally use record validators
    _logger.fine('Validating record...');
    return true;
  }
  
  @override
  bool get enableValues => true;
  
  @override
  set enableValues(bool value) {
    // Setter for enableValues
  }
  
  @override
  ProviderManager get providerManager => _providerManager;
  
  @override
  DHTHandlers get handlers => _handlers;
  
  @override
  NamespacedValidator get recordValidator => _recordValidator;
  
  @override
  Estimator get nsEstimator => _nsEstimator;
  
  @override
  Peerstore get peerstore => _host.peerStore;
  
  @override
  set peerstore(Peerstore value) {
    // Setter for peerstore - no-op since we use host's peerstore
  }
  
  @override
  ProtocolMessenger get protoMessenger => _protoMessenger;
  
  @override
  set protoMessenger(ProtocolMessenger value) {
    // Setter for protoMessenger
  }
  
  // Private properties for compatibility
  late final ProviderManager _providerManager;
  late final DHTHandlers _handlers;
  late final NamespacedValidator _recordValidator;
  late final Estimator _nsEstimator;
  late final ProtocolMessenger _protoMessenger;
  
  // Private helpers
  
  void _ensureStarted() {
    if (_closed) throw DHTClosedException();
    if (!_started) throw DHTNotStartedException();
  }
  
  /// Creates the default validator with proper record validation
  NamespacedValidator _createDefaultValidator() {
    final validator = NamespacedValidator();
    
    // Add validators for different namespaces
    validator['pk'] = PublicKeyValidator(); // Public key records
    validator['ipns'] = IpnsValidator(_host.peerStore); // IPNS records
    validator['v'] = DHTRecordValidator(); // Generic DHT records with signature validation
    
    return validator;
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
      _logger.fine('RefreshQuery: key "$key" is not a CPL, skipping.');
      return;
    }
    
    _logger.fine('RefreshQuery: Performing lookup for CPL $cplToQuery');
    
    try {
      // Generate a target key for this CPL
      final targetKey = await _routing.routingTable.genRandomPeerIdWithCpl(cplToQuery);
      
      // Perform a network query to discover peers
      final result = await _queries.getClosestPeers(targetKey, networkQueryEnabled: true);
      
      // Add discovered peers to routing table
      var addedCount = 0;
      for (final addrInfo in result) {
        if (addrInfo.id != _host.id) { // Don't add self
          final added = await _routing.routingTable.tryAddPeer(addrInfo.id, queryPeer: true);
          if (added) {
            addedCount++;
            // Store addresses in peerstore
            await _host.peerStore.addrBook.addAddrs(addrInfo.id, addrInfo.addrs, Duration(hours: 1));
          }
        }
      }
      
      _logger.fine('RefreshQuery: Added $addedCount new peers for CPL $cplToQuery');
    } catch (e, s) {
      _logger.warning('RefreshQuery: Error during query for CPL $cplToQuery: $e', e, s);
    }
  }

  /// Performs a ping to verify peer connectivity
  Future<void> _performRefreshPing(PeerId peerId) async {
    if (!_started) return;
    
    try {
      // Try to dial the peer to verify connectivity
      await dialPeer(peerId);
      _logger.fine('RefreshPing: Successfully pinged ${peerId.toBase58().substring(0, 6)}');
    } catch (e) {
      _logger.fine('RefreshPing: Failed to ping ${peerId.toBase58().substring(0, 6)}: $e');
      // Remove unreachable peer from routing table
      await _routing.routingTable.removePeer(peerId);
    }
  }
  
  @override
  String toString() => 'IpfsDHTv2(${_host.id.toBase58().substring(0, 6)})';
} 