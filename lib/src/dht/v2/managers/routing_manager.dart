import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:logging/logging.dart';

import '../../../kbucket/table/table.dart';
import '../../dht.dart';
import '../../dht_options.dart';
import '../../../amino/defaults.dart';
import '../../../pb/dht_message.dart';
import '../config/dht_config.dart';
import '../config/bootstrap_config.dart';
import '../errors/dht_errors.dart';
import 'metrics_manager.dart';
import 'network_manager.dart';

/// Manages routing table operations for DHT v2
/// 
/// This component handles:
/// - Routing table management
/// - Peer addition and removal
/// - Bootstrap operations
/// - Routing table refresh
/// - Peer discovery
class RoutingManager {
  static final Logger _logger = Logger('RoutingManager');
  
  final Host _host;
  late final RoutingTable _routingTable;
  
  // Configuration
  DHTConfigV2? _config;
  MetricsManager? _metrics;
  NetworkManager? _network;
  
  // State
  bool _started = false;
  bool _closed = false;
  Timer? _refreshTimer;
  
  RoutingManager(this._host, DHTOptions options) {
    _routingTable = RoutingTable(
      local: _host.id,
      bucketSize: options.bucketSize,
      maxLatency: AminoConstants.defaultMaxLatency,
      metrics: SimplePeerLatencyMetrics(),
      usefulnessGracePeriod: AminoConstants.defaultUsefulnessGracePeriod,
    );
  }
  
  /// Gets the routing table instance
  RoutingTable get routingTable => _routingTable;
  
  /// Initializes the routing manager
  void initialize({
    required DHTConfigV2 config,
    required MetricsManager metrics,
    required NetworkManager network,
  }) {
    _config = config;
    _metrics = metrics;
    _network = network;
  }
  
  /// Starts the routing manager
  Future<void> start() async {
    if (_started || _closed) return;
    
    _logger.info('Starting RoutingManager...');
    
    // Start automatic refresh if enabled
    if (_config?.autoRefresh == true) {
      _startPeriodicRefresh();
    }
    
    _started = true;
    _logger.info('RoutingManager started');
  }
  
  /// Stops the routing manager
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    
    _logger.info('Closing RoutingManager...');
    
    _refreshTimer?.cancel();
    _refreshTimer = null;
    
    // Note: RoutingTable doesn't have a close method, so we just clean up our state
    _logger.info('RoutingManager closed');
  }
  
  /// Performs bootstrap operations
  Future<void> bootstrap() async {
    _ensureStarted();
    
    _logger.info('Starting bootstrap process...');
    
    try {
      // Phase 1: Connect to explicitly configured bootstrap peers
      await _connectToBootstrapPeers();
      
      // Phase 2: Perform routing table population (if we have any peers)
      final currentSize = await _routingTable.size();
      if (currentSize > 0) {
        await _populateRoutingTable();
      } else {
        _logger.info('No peers available for routing table population - skipping');
      }
      
      _logger.info('Bootstrap process completed successfully');
    } catch (e, stackTrace) {
      _logger.severe('Bootstrap failed', e, stackTrace);
      
      // Only throw exception for critical failures, not for network connectivity issues
      if (e is TimeoutException || e.toString().contains('TimeoutException')) {
        // Log the timeout but complete bootstrap gracefully
        _logger.warning('Bootstrap timed out but completing gracefully: $e');
        _logger.info('Bootstrap process completed with timeout (graceful completion)');
      } else {
        // For other types of exceptions, still throw
        throw DHTBootstrapException('Bootstrap failed: $e', cause: e, stackTrace: stackTrace);
      }
    }
  }
  
  /// Connects to explicitly configured bootstrap peers
  Future<void> _connectToBootstrapPeers() async {
    final bootstrapPeers = _config?.bootstrapPeers;
    if (bootstrapPeers == null || bootstrapPeers.isEmpty) {
      _logger.info('No explicit bootstrap peers configured');
      return;
    }
    
    _logger.info('Connecting to ${bootstrapPeers.length} bootstrap peers...');
    
    int connected = 0;
    final errors = <String>[];
    
    for (final addr in bootstrapPeers) {
      try {
        // Extract peer ID from multiaddr
        final peerId = _extractPeerIdFromMultiaddr(addr);
        if (peerId == null) {
          final error = 'Cannot extract peer ID from address: $addr';
          _logger.warning(error);
          errors.add(error);
          continue;
        }
        
        // Create connectable address without p2p component
        final connectAddr = addr.decapsulate('p2p');
        if (connectAddr == null) {
          final error = 'Cannot create connectable address from: $addr';
          _logger.warning(error);
          errors.add(error);
          continue;
        }
        
        final addrInfo = AddrInfo(peerId, [connectAddr]);
        
        // Add to peerstore
        await _host.peerStore.addOrUpdatePeer(peerId, addrs: [connectAddr]);
        
        // CRITICAL FIX: Actually try to connect to the peer via network
        // This is what was missing in the v2 implementation
        await _host.connect(addrInfo).timeout(Duration(seconds: 10));
        
        // Add to routing table only after successful connection
        final added = await _routingTable.tryAddPeer(peerId, queryPeer: false);
        if (added) {
          connected++;
          _metrics?.recordPeerAdded();
          _logger.info('Successfully connected to bootstrap peer: ${peerId.toBase58().substring(0, 6)}');
          
          // Protect DHT routing table peer to maintain stable connections
          _host.connManager.protect(peerId, 'dht-routing-table');
          _logger.fine('Protected DHT routing table peer: ${peerId.toBase58().substring(0, 6)}');
        }
      } catch (e) {
        final error = 'Failed to connect to bootstrap peer $addr: $e';
        _logger.warning(error);
        errors.add(error);
      }
    }
    
    _logger.info('Connected to $connected out of ${bootstrapPeers.length} bootstrap peers');
    
    // If we have bootstrap peers configured but failed to connect to all of them, log warning but don't throw
    // This allows the DHT to continue operating even with unreachable bootstrap peers
    if (bootstrapPeers.isNotEmpty && connected == 0) {
      _logger.warning('Failed to connect to any bootstrap peers: ${errors.join(', ')}');
      // Don't throw exception - let bootstrap complete gracefully
    }
  }
  
  /// Extracts peer ID from multiaddr
  PeerId? _extractPeerIdFromMultiaddr(MultiAddr addr) {
    try {
      final peerIdValue = addr.valueForProtocol('p2p');
      if (peerIdValue != null && peerIdValue.isNotEmpty) {
        return PeerId.fromString(peerIdValue);
      }
    } catch (e) {
      _logger.warning('Error extracting peer ID from $addr: $e');
    }
    return null;
  }
  
  /// Populates the routing table with peers
  Future<void> _populateRoutingTable() async {
    _logger.info('Starting comprehensive routing table population...');
    
    try {
      // Phase 1: Refresh existing peers and verify connectivity
      await _refreshExistingPeers().timeout(Duration(seconds: 15));
      
      // Phase 2: Perform peer discovery through random key lookups
      await _performPeerDiscovery().timeout(Duration(seconds: 15));
      
      // Phase 3: Verify network health and connectivity
      await _verifyNetworkHealth().timeout(Duration(seconds: 10));
      
      final finalSize = await _routingTable.size();
      _logger.info('Routing table population completed. Final size: $finalSize');
      
      // Record metrics
      _metrics?.recordPeerAdded(); // Use existing method for now
    } catch (e, stackTrace) {
      _logger.severe('Failed to populate routing table', e, stackTrace);
      // Don't rethrow - allow bootstrap to complete even if population fails
      _logger.warning('Bootstrap continuing despite routing table population failure');
    }
  }
  
  /// Refreshes existing peers and verifies connectivity
  Future<void> _refreshExistingPeers() async {
    _logger.info('Refreshing existing peers...');
    
    // Get current peers from routing table
    final currentPeers = await _routingTable.listPeers();
    _logger.info('Current routing table has ${currentPeers.length} peers');
    
    var refreshedCount = 0;
    var removedCount = 0;
    
    for (final peer in currentPeers) {
      try {
        // Skip self
        if (peer.id == _host.id) continue;
        
        // Verify connectivity to the peer with timeout
        final isConnected = await _verifyPeerConnectivity(peer.id).timeout(Duration(seconds: 3));
        
        if (isConnected) {
          // Try to refresh the peer
          final refreshed = await _routingTable.tryAddPeer(peer.id, queryPeer: false);
          if (refreshed) {
            refreshedCount++;
            // Protect refreshed peer
            _host.connManager.protect(peer.id, 'dht-routing-table');
            _logger.fine('Protected refreshed DHT peer: ${peer.id.toBase58().substring(0, 6)}');
          }
          _logger.fine('Refreshed peer ${peer.id.toBase58().substring(0, 6)}: $refreshed');
        } else {
          // Remove unresponsive peer
          await _routingTable.removePeer(peer.id);
          removedCount++;
          _logger.warning('Removed unresponsive peer ${peer.id.toBase58().substring(0, 6)}');
          
          // Unprotect removed peer
          _host.connManager.unprotect(peer.id, 'dht-routing-table');
          _logger.fine('Unprotected removed DHT peer: ${peer.id.toBase58().substring(0, 6)}');
        }
      } catch (e) {
        _logger.warning('Failed to refresh peer ${peer.id.toBase58().substring(0, 6)}: $e');
        // Try to remove problematic peer
        try {
          await _routingTable.removePeer(peer.id);
          removedCount++;
          
          // Unprotect removed peer
          _host.connManager.unprotect(peer.id, 'dht-routing-table');
          _logger.fine('Unprotected problematic DHT peer: ${peer.id.toBase58().substring(0, 6)}');
        } catch (removeError) {
          _logger.warning('Failed to remove problematic peer: $removeError');
        }
      }
    }
    
    _logger.info('Peer refresh completed. Refreshed: $refreshedCount, Removed: $removedCount');
  }
  
  /// Performs comprehensive peer discovery
  Future<void> _performPeerDiscovery() async {
    _logger.info('Starting peer discovery...');
    
    final targetSize = (_config?.resiliency ?? AminoConstants.defaultResiliency) * 2;
    var currentSize = await _routingTable.size();
    
    _logger.info('Target routing table size: $targetSize, Current size: $currentSize');
    
    // If we have no peers to query, skip peer discovery
    if (currentSize == 0) {
      _logger.info('No peers available for discovery - skipping peer discovery phase');
      return;
    }
    
    // Perform multiple rounds of discovery if needed
    var round = 0;
    while (currentSize < targetSize && round < 3) {
      round++;
      _logger.info('Discovery round $round: Current size: $currentSize, Target: $targetSize');
      
      // Check if we still have peers to query
      final availablePeers = await _routingTable.listPeers();
      if (availablePeers.isEmpty) {
        _logger.info('No peers available for discovery in round $round - stopping');
        break;
      }
      
      // Perform random key lokup with timeout
      await _performRandomKeyLookup().timeout(Duration(seconds: 15)); //FIXME: Configure timeout on how long we take to run this ting
      
      // Perform self lookup (refresh our own routing table) with timeout
      await _performSelfLookup().timeout(Duration(seconds: 15)); //FIXME: Configure timeout on how long we take to run this ting
      
      currentSize = await _routingTable.size();
      _logger.info('Discovery round $round completed. New size: $currentSize');
      
      // Break if we're not making progress
      if (currentSize == 0) {
        _logger.warning('No peers discovered in round $round. Breaking discovery loop.');
        break;
      }
    }
    
    _logger.info('Peer discovery completed. Final size: $currentSize');
  }
  
  /// Verifies network health and connectivity
  Future<void> _verifyNetworkHealth() async {
    _logger.info('Verifying network health...');
    
    final currentSize = await _routingTable.size();
    final minSize = _config?.resiliency ?? AminoConstants.defaultResiliency;
    
    if (currentSize < minSize) {
      _logger.warning('Routing table size ($currentSize) is below minimum ($minSize)');
      
      // Try to connect to more bootstrap peers if available
      await _connectToAdditionalBootstrapPeers();
      
      final finalSize = await _routingTable.size();
      if (finalSize < minSize) {
        _logger.warning('Network health check failed. Final size: $finalSize, Required: $minSize');
      } else {
        _logger.info('Network health restored. Final size: $finalSize');
      }
    } else {
      _logger.info('Network health check passed. Routing table size: $currentSize');
    }
  }
  
  /// Connects to additional bootstrap peers if available
  Future<void> _connectToAdditionalBootstrapPeers() async {
    _logger.info('Attempting to connect to additional bootstrap peers...');
    
    // Get default bootstrap peers if none configured
    final additionalPeers = await _getDefaultBootstrapPeers();
    
    var connected = 0;
    for (final addrInfo in additionalPeers) {
      try {
        // Skip if already in routing table
        final existing = await _routingTable.find(addrInfo.id);
        if (existing != null) continue;
        
        // Try to connect with timeout
        await _host.connect(addrInfo).timeout(Duration(seconds: 5));
        
        // Add to routing table
        final added = await _routingTable.tryAddPeer(addrInfo.id, queryPeer: false);
        if (added) {
          connected++;
          _metrics?.recordPeerAdded();
          _logger.info('Connected to additional bootstrap peer: ${addrInfo.id.toBase58().substring(0, 6)}');
          
          // Protect additional bootstrap peer
          _host.connManager.protect(addrInfo.id, 'dht-routing-table');
          _logger.fine('Protected additional bootstrap DHT peer: ${addrInfo.id.toBase58().substring(0, 6)}');
        }
      } catch (e) {
        _logger.warning('Failed to connect to additional bootstrap peer ${addrInfo.id.toBase58().substring(0, 6)}: $e');
      }
    }
    
    _logger.info('Connected to $connected additional bootstrap peers');
  }
  
  /// Gets default bootstrap peers
  Future<List<AddrInfo>> _getDefaultBootstrapPeers() async {
    try {
      // Use the bootstrap configuration to get default peers
      final defaultPeers = BootstrapConfig.getDefaultBootstrapPeerAddrInfos();
      
      _logger.info('Retrieved ${defaultPeers.length} default bootstrap peers');
      return defaultPeers;
    } catch (e) {
      _logger.warning('Failed to get default bootstrap peers: $e');
      return [];
    }
  }
  
  /// Verifies connectivity to a peer
  Future<bool> _verifyPeerConnectivity(PeerId peerId) async {
    try {
      // Try to send a PING message to verify connectivity
      final message = Message(
        type: MessageType.ping,
        key: Uint8List.fromList([]),
      );
      
      final response = await _network?.sendMessage(peerId, message);
      return response != null;
    } catch (e) {
      _logger.fine('Peer connectivity check failed for ${peerId.toBase58().substring(0, 6)}: $e');
      return false;
    }
  }
  
  /// Performs a random key lookup to discover more peers
  Future<void> _performRandomKeyLookup() async {
    final randomKey = Uint8List.fromList(
      List.generate(32, (_) => math.Random().nextInt(256)),
    );
    
    _logger.info('Performing random key lookup for peer discovery...');
    
    try {
      // Perform a network lookup using the random key
      var discoveredPeers = 0;
      
      // Get current peers to query
      final currentPeers = await _routingTable.listPeers();
      
      for (final peer in currentPeers.take(3)) { // Query up to 3 peers
        try {
          // Send FIND_NODE message for the random key
          final message = Message(
            type: MessageType.findNode,
            key: randomKey,
          );
          
          final response = await _network?.sendMessage(peer.id, message);
          
          if (response != null) {
            // Process the response and add new peers
            for (final responsePeer in response.closerPeers) {
              try {
                final peerId = PeerId.fromBytes(responsePeer.id);
                
                // CRITICAL FIX: Store addresses in peerstore BEFORE adding to routing table
                // This ensures addresses are available when we need to dial these peers later
                if (responsePeer.addrs.isNotEmpty) {
                  final addresses = responsePeer.addrs
                      .map((addr) => MultiAddr.fromBytes(addr))
                      .toList();
                  await _host.peerStore.addOrUpdatePeer(peerId, addrs: addresses);
                  _logger.fine('Stored ${addresses.length} address(es) for discovered peer ${peerId.toBase58().substring(0, 6)}');
                }
                
                final added = await _routingTable.tryAddPeer(peerId, queryPeer: true);
                if (added) {
                  discoveredPeers++;
                  _metrics?.recordPeerAdded();
                  
                  // Protect discovered peer
                  _host.connManager.protect(peerId, 'dht-routing-table');
                  _logger.fine('Protected discovered DHT peer: ${peerId.toBase58().substring(0, 6)}');
                }
              } catch (e) {
                _logger.fine('Failed to add discovered peer: $e');
              }
            }
          }
        } catch (e) {
          _logger.fine('Failed to query peer ${peer.id.toBase58().substring(0, 6)}: $e');
        }
      }
      
      _logger.info('Random key lookup completed. Discovered $discoveredPeers new peers');
    } catch (e) {
      _logger.warning('Random key lookup failed: $e');
    }
  }
  
  /// Performs a self lookup to refresh our own position in the network
  Future<void> _performSelfLookup() async {
    _logger.info('Performing self lookup for routing table refresh...');
    
    try {
      final selfId = _host.id.toBytes();
      var discoveredPeers = 0;
      
      // Get current peers to query
      final currentPeers = await _routingTable.listPeers();
      
      for (final peer in currentPeers.take(3)) { // Query up to 3 peers
        try {
          // Send FIND_NODE message for our own ID
          final message = Message(
            type: MessageType.findNode,
            key: selfId,
          );
          
          final response = await _network?.sendMessage(peer.id, message);
          
          if (response != null) {
            // Process the response and add new peers
            for (final responsePeer in response.closerPeers) {
              try {
                final peerId = PeerId.fromBytes(responsePeer.id);
                // Skip self
                if (peerId == _host.id) continue;
                
                // CRITICAL FIX: Store addresses in peerstore BEFORE adding to routing table
                // This ensures addresses are available when we need to dial these peers later
                if (responsePeer.addrs.isNotEmpty) {
                  final addresses = responsePeer.addrs
                      .map((addr) => MultiAddr.fromBytes(addr))
                      .toList();
                  await _host.peerStore.addOrUpdatePeer(peerId, addrs: addresses);
                  _logger.fine('Stored ${addresses.length} address(es) for discovered peer ${peerId.toBase58().substring(0, 6)}');
                }
                
                final added = await _routingTable.tryAddPeer(peerId, queryPeer: true);
                if (added) {
                  discoveredPeers++;
                  _metrics?.recordPeerAdded();
                  
                  // Protect discovered peer from self lookup
                  _host.connManager.protect(peerId, 'dht-routing-table');
                  _logger.fine('Protected peer discovered in self lookup: ${peerId.toBase58().substring(0, 6)}');
                }
              } catch (e) {
                _logger.fine('Failed to add discovered peer: $e');
              }
            }
          }
        } catch (e) {
          _logger.fine('Failed to query peer ${peer.id.toBase58().substring(0, 6)}: $e');
        }
      }
      
      _logger.info('Self lookup completed. Discovered $discoveredPeers new peers');
    } catch (e) {
      _logger.warning('Self lookup failed: $e');
    }
  }
  
  /// Starts periodic refresh of the routing table
  void _startPeriodicRefresh() {
    final interval = _config?.refreshInterval ?? Duration(seconds: 15); /// FIXME: Note where we set this interval !
    _refreshTimer = Timer.periodic(interval, (_) => _performPeriodicRefresh());
    _logger.info('Started periodic refresh with interval: $interval');
  }
  
  /// Performs periodic refresh of the routing table
  void _performPeriodicRefresh() async {
    if (!_started || _closed) return;
    
    _logger.info('Performing periodic routing table refresh...');
    _metrics?.recordBucketRefresh();
    
    try {
      await _populateRoutingTable();
    } catch (e) {
      _logger.warning('Periodic refresh failed: $e');
    }
  }
  
  /// Adds a peer to the routing table
  Future<bool> addPeer(PeerId peer, {bool queryPeer = true, bool isReplaceable = true}) async {
    _ensureStarted();
    
    try {
      final added = await _routingTable.tryAddPeer(peer, queryPeer: queryPeer, isReplaceable: isReplaceable);
      if (added) {
        _metrics?.recordPeerAdded();
        _metrics?.recordRoutingTableSize(await _routingTable.size());
        _logger.fine('Added peer ${peer.toBase58().substring(0, 6)} to routing table');
      }
      return added;
    } catch (e) {
      throw DHTRoutingException('Failed to add peer to routing table: $e', peerId: peer, cause: e);
    }
  }
  
  /// Removes a peer from the routing table
  Future<bool> removePeer(PeerId peer) async {
    _ensureStarted();
    
    try {
      await _routingTable.removePeer(peer);
      _metrics?.recordPeerRemoved();
      // Get size after removal to avoid deadlock
      final size = await _routingTable.size();
      _metrics?.recordRoutingTableSize(size);
      _logger.fine('Removed peer ${peer.toBase58().substring(0, 6)} from routing table');
      return true;
    } catch (e) {
      // Handle "No such element" error gracefully - peer wasn't in table
      if (e.toString().contains('No such element')) {
        _logger.fine('Peer ${peer.toBase58().substring(0, 6)} not found in routing table for removal');
        return false;
      }
      throw DHTRoutingException('Failed to remove peer from routing table: $e', peerId: peer, cause: e);
    }
  }
  
  /// Finds a peer in the routing table
  Future<PeerId?> findPeer(PeerId peer) async {
    _ensureStarted();
    
    try {
      return await _routingTable.find(peer);
    } catch (e) {
      throw DHTRoutingException('Failed to find peer in routing table: $e', peerId: peer, cause: e);
    }
  }
  
  /// Gets the closest peers to a target
  Future<List<PeerId>> getNearestPeers(Uint8List target, int count) async {
    _ensureStarted();
    
    try {
      return await _routingTable.nearestPeers(target, count);
    } catch (e) {
      throw DHTRoutingException('Failed to get nearest peers: $e', cause: e);
    }
  }
  
  /// Gets all peers in the routing table
  Future<List<AddrInfo>> getAllPeers() async {
    _ensureStarted();
    
    try {
      final peers = await _routingTable.listPeers();
      return peers.map((p) => AddrInfo(p.id, [])).toList();
    } catch (e) {
      throw DHTRoutingException('Failed to list peers: $e', cause: e);
    }
  }
  
  /// Gets the current size of the routing table
  Future<int> getSize() async {
    _ensureStarted();
    
    try {
      return await _routingTable.size();
    } catch (e) {
      throw DHTRoutingException('Failed to get routing table size: $e', cause: e);
    }
  }
  
  /// Gets bootstrap peers from the routing table
  Future<List<AddrInfo>> getBootstrapPeers() async {
    _ensureStarted();
    
    try {
      final peers = await _routingTable.listPeers();
      final bootstrapPeers = <AddrInfo>[];
      
      for (final peer in peers) {
        final peerInfo = await _host.peerStore.getPeer(peer.id);
        if (peerInfo != null && peerInfo.addrs.isNotEmpty) {
          bootstrapPeers.add(AddrInfo(peer.id, peerInfo.addrs.toList()));
        }
      }
      
      return bootstrapPeers;
    } catch (e) {
      throw DHTRoutingException('Failed to get bootstrap peers: $e', cause: e);
    }
  }
  
  /// Checks if the routing table is healthy
  Future<bool> isHealthy() async {
    _ensureStarted();
    
    try {
      final size = await _routingTable.size();
      final minSize = _config?.resiliency ?? AminoConstants.defaultResiliency;
      return size >= minSize;
    } catch (e) {
      _logger.warning('Failed to check routing table health: $e');
      return false;
    }
  }
  
  /// Gets routing table statistics
  Future<Map<String, dynamic>> getStatistics() async {
    _ensureStarted();
    
    try {
      final size = await _routingTable.size();
      final peers = await _routingTable.listPeers();
      
      return {
        'size': size,
        'peers': peers.length,
        'healthy': await isHealthy(),
        'last_refresh': _refreshTimer != null ? DateTime.now().toIso8601String() : null,
      };
    } catch (e) {
      throw DHTRoutingException('Failed to get routing table statistics: $e', cause: e);
    }
  }
  
  /// Ensures the routing manager is started
  void _ensureStarted() {
    if (_closed) throw DHTClosedException();
    if (!_started) throw DHTNotStartedException();
  }
  
  @override
  String toString() => 'RoutingManager(${_host.id.toBase58().substring(0, 6)})';
} 