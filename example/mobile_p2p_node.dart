/// Mobile-Optimized P2P Node Example
/// 
/// This example demonstrates how to create a mobile-friendly P2P node using the
/// Dart libp2p Kademlia DHT with optimizations for battery life and memory usage.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dcid/dcid.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:dart_libp2p_kad_dht/src/dht/dht_options.dart' as dht_opts;
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_mgr;
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;
import 'package:dart_udx/dart_udx.dart';
import 'package:logging/logging.dart';

import '../test/real_net_stack.dart';

class MobileP2PNode {
  late final Host host;
  late final IpfsDHT dht;
  late final ProviderStore providerStore;
  late final String nodeId;
  
  Timer? _refreshTimer;
  Timer? _cleanupTimer;
  bool _isRunning = false;
  
  // Mobile-specific configuration
  static const Duration refreshInterval = Duration(minutes: 15);
  static const Duration cleanupInterval = Duration(minutes: 30);
  static const int maxRoutingTableSize = 200;
  static const int maxProviderCacheSize = 100;
  
  /// Initialize the mobile-optimized P2P node
  Future<void> initialize({
    List<MultiAddr>? bootstrapPeers,
    bool enableBackgroundRefresh = true,
  }) async {
    print('Initializing mobile-optimized P2P node...');
    
    // Create the libp2p host with mobile-friendly settings
    final nodeDetails = await createLibp2pNode(
      udxInstance: UDX(),
      resourceManager: NullResourceManager(),
      connManager: p2p_conn_mgr.ConnectionManager(),
      hostEventBus: p2p_event_bus.BasicBus(),
      // Use empty listen addresses for client-only mode
      listenAddrsOverride: [],
    );
    host = nodeDetails.host;
    nodeId = host.id.toBase58().substring(0, 8);
    
    print('[$nodeId] Mobile node created with ID: ${host.id.toBase58()}');
    
    // Create provider store with limited cache size
    providerStore = MemoryProviderStore(
      ProviderManagerOptions(
        cacheSize: maxProviderCacheSize,
        cleanupInterval: cleanupInterval,
      ),
    );
    
    // Mobile-optimized DHT configuration
    final dhtOptions = <DHTOption>[
      mode(DHTMode.client),           // Client-only mode for battery efficiency
      bucketSize(10),                 // Smaller routing table
      concurrency(3),                 // Lower network concurrency
      resiliency(2),                  // Fewer required responses
      maxDhtMessageRetries(2),        // Fewer retry attempts
      dhtMessageRetryMaxBackoff(Duration(seconds: 10)),
      disableAutoRefresh(),           // Manual refresh control
    ];
    
    // Add bootstrap configuration if provided
    if (bootstrapPeers != null && bootstrapPeers.isNotEmpty) {
      final addrInfos = bootstrapPeers.map((addr) {
        final p2pComponent = addr.valueForProtocol('p2p');
        if (p2pComponent != null) {
          final peerId = PeerId.fromString(p2pComponent);
          final connectAddr = addr.decapsulate('p2p');
          return AddrInfo(peerId, connectAddr != null ? [connectAddr] : []);
        }
        throw ArgumentError('Invalid bootstrap peer address: $addr');
      }).toList();
      
      // Import the bootstrapPeers function from dht_options with an alias to avoid naming conflict
      dhtOptions.add(dht_opts.bootstrapPeers(addrInfos));
    }
    
    // Create and start the DHT
    dht = await DHT.new_(host, providerStore, dhtOptions);
    await dht.start();
    print('[$nodeId] Mobile DHT started in client mode');
    
    // Initial bootstrap
    await dht.bootstrap(quickConnectOnly: true);
    print('[$nodeId] Initial bootstrap completed');
    
    // Set up background tasks if enabled
    if (enableBackgroundRefresh) {
      _setupBackgroundTasks();
    }
    
    _isRunning = true;
    print('[$nodeId] Mobile P2P node is ready!');
  }
  
  /// Set up battery-friendly background tasks
  void _setupBackgroundTasks() {
    print('[$nodeId] Setting up battery-friendly background tasks');
    
    // Periodic refresh (less frequent than server nodes)
    _refreshTimer = Timer.periodic(refreshInterval, (_) async {
      if (!_isRunning) return;
      
      try {
        print('[$nodeId] Performing periodic refresh...');
        await dht.bootstrap(quickConnectOnly: true);
        print('[$nodeId] Periodic refresh completed');
      } catch (e) {
        print('[$nodeId] Error during periodic refresh: $e');
      }
    });
    
    // Periodic cleanup to manage memory usage
    _cleanupTimer = Timer.periodic(cleanupInterval, (_) async {
      if (!_isRunning) return;
      
      try {
        await _performCleanup();
      } catch (e) {
        print('[$nodeId] Error during cleanup: $e');
      }
    });
  }
  
  /// Perform memory cleanup
  Future<void> _performCleanup() async {
    print('[$nodeId] Performing memory cleanup...');
    
    // Check routing table size
    final tableSize = await dht.routingTable.size();
    print('[$nodeId] Current routing table size: $tableSize');
    
    if (tableSize > maxRoutingTableSize) {
      print('[$nodeId] Routing table size ($tableSize) exceeds limit ($maxRoutingTableSize)');
      // In a real implementation, you might implement table trimming
      // For now, just log the situation
    }
    
    // Provider store cleanup is handled automatically by MemoryProviderStore
    print('[$nodeId] Memory cleanup completed');
  }
  
  /// Find a peer (with mobile-friendly timeout)
  Future<AddrInfo?> findPeer(String peerIdString, {Duration? timeout}) async {
    if (!_isRunning) throw StateError('Node not running');
    
    final peerId = PeerId.fromString(peerIdString);
    print('[$nodeId] Looking for peer: ${peerIdString.substring(0, 8)}...');
    
    try {
      final peerInfo = await dht.findPeer(peerId).timeout(
        timeout ?? Duration(seconds: 30),
      );
      
      if (peerInfo != null) {
        print('[$nodeId] Found peer ${peerIdString.substring(0, 8)}');
        return peerInfo;
      } else {
        print('[$nodeId] Peer ${peerIdString.substring(0, 8)} not found');
        return null;
      }
    } on TimeoutException {
      print('[$nodeId] Timeout finding peer ${peerIdString.substring(0, 8)}');
      return null;
    }
  }
  
  /// Find content providers (with mobile-friendly limits)
  Future<List<AddrInfo>> findContentProviders(
    String contentId, {
    int maxProviders = 3,
    Duration? timeout,
  }) async {
    if (!_isRunning) throw StateError('Node not running');
    
    final cid = CID.fromString(contentId);
    print('[$nodeId] Looking for providers of content: $contentId (max: $maxProviders)');
    
    final providers = <AddrInfo>[];
    
    try {
      final stream = dht.findProvidersAsync(cid, maxProviders);
      
      await for (final provider in stream.timeout(timeout ?? Duration(seconds: 30))) {
        providers.add(provider);
        print('[$nodeId] Found provider: ${provider.id.toBase58().substring(0, 8)}');
        
        if (providers.length >= maxProviders) break;
      }
    } on TimeoutException {
      print('[$nodeId] Timeout finding providers for $contentId');
    }
    
    print('[$nodeId] Found ${providers.length} providers for $contentId');
    return providers;
  }
  
  /// Retrieve a value (with mobile-friendly timeout)
  Future<String?> retrieveValue(String key, {Duration? timeout}) async {
    if (!_isRunning) throw StateError('Node not running');
    
    print('[$nodeId] Retrieving value for key: $key');
    
    try {
      final valueBytes = await dht.getValue(key, null).timeout(
        timeout ?? Duration(seconds: 20),
      );
      
      if (valueBytes != null) {
        final value = utf8.decode(valueBytes);
        print('[$nodeId] Retrieved value: $value');
        return value;
      } else {
        print('[$nodeId] No value found for key: $key');
        return null;
      }
    } on TimeoutException {
      print('[$nodeId] Timeout retrieving value for key: $key');
      return null;
    }
  }
  
  /// Find service providers (with mobile-friendly limits)
  Future<List<AddrInfo>> findServiceProviders(
    String serviceName, {
    int maxPeers = 3,
    Duration? timeout,
  }) async {
    if (!_isRunning) throw StateError('Node not running');
    
    print('[$nodeId] Looking for service providers: $serviceName (max: $maxPeers)');
    
    final providers = <AddrInfo>[];
    
    try {
      final stream = await dht.findPeers(serviceName);
      
      await for (final peer in stream.timeout(timeout ?? Duration(seconds: 30))) {
        providers.add(peer);
        print('[$nodeId] Found service provider: ${peer.id.toBase58().substring(0, 8)}');
        
        if (providers.length >= maxPeers) break;
      }
    } on TimeoutException {
      print('[$nodeId] Timeout finding service providers for: $serviceName');
    }
    
    print('[$nodeId] Found ${providers.length} providers for service: $serviceName');
    return providers;
  }
  
  /// Get mobile-friendly network statistics
  Future<MobileNetworkStats> getNetworkStats() async {
    if (!_isRunning) throw StateError('Node not running');
    
    final tableSize = await dht.routingTable.size();
    
    // Network size estimation might fail on mobile due to limited data
    int? networkSize;
    try {
      networkSize = await dht.nsEstimator.networkSize();
    } catch (e) {
      print('[$nodeId] Could not estimate network size: $e');
    }
    
    return MobileNetworkStats(
      routingTableSize: tableSize,
      estimatedNetworkSize: networkSize,
      localPeerId: host.id.toBase58(),
      isRefreshActive: _refreshTimer?.isActive ?? false,
      isCleanupActive: _cleanupTimer?.isActive ?? false,
    );
  }
  
  /// Print mobile-friendly network statistics
  Future<void> printNetworkStats() async {
    final stats = await getNetworkStats();
    
    print('[$nodeId] Mobile Network Statistics:');
    print('  - Routing table size: ${stats.routingTableSize} peers');
    if (stats.estimatedNetworkSize != null) {
      print('  - Estimated network size: ${stats.estimatedNetworkSize} peers');
    } else {
      print('  - Estimated network size: Unable to estimate');
    }
    print('  - Local peer ID: ${stats.localPeerId}');
    print('  - Background refresh: ${stats.isRefreshActive ? "Active" : "Inactive"}');
    print('  - Memory cleanup: ${stats.isCleanupActive ? "Active" : "Inactive"}');
  }
  
  /// Manually trigger a refresh (useful for foreground app events)
  Future<void> refresh() async {
    if (!_isRunning) throw StateError('Node not running');
    
    print('[$nodeId] Manual refresh triggered');
    try {
      await dht.bootstrap(quickConnectOnly: true);
      print('[$nodeId] Manual refresh completed');
    } catch (e) {
      print('[$nodeId] Error during manual refresh: $e');
    }
  }
  
  /// Pause background tasks (useful when app goes to background)
  void pauseBackgroundTasks() {
    print('[$nodeId] Pausing background tasks for battery saving');
    _refreshTimer?.cancel();
    _cleanupTimer?.cancel();
  }
  
  /// Resume background tasks (useful when app comes to foreground)
  void resumeBackgroundTasks() {
    if (!_isRunning) return;
    
    print('[$nodeId] Resuming background tasks');
    _setupBackgroundTasks();
  }
  
  /// Shutdown the mobile node
  Future<void> shutdown() async {
    if (!_isRunning) return;
    
    print('[$nodeId] Shutting down mobile node...');
    
    _isRunning = false;
    
    // Cancel background tasks
    _refreshTimer?.cancel();
    _cleanupTimer?.cancel();
    
    // Close DHT and related resources
    await dht.close();
    await providerStore.close();
    await host.close();
    
    print('[$nodeId] Mobile node shutdown complete');
  }
}

/// Mobile-specific network statistics
class MobileNetworkStats {
  final int routingTableSize;
  final int? estimatedNetworkSize;
  final String localPeerId;
  final bool isRefreshActive;
  final bool isCleanupActive;
  
  MobileNetworkStats({
    required this.routingTableSize,
    this.estimatedNetworkSize,
    required this.localPeerId,
    required this.isRefreshActive,
    required this.isCleanupActive,
  });
}

/// Example usage for mobile applications
Future<void> main(List<String> args) async {
  // Setup minimal logging for mobile
  Logger.root.level = Level.WARNING;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.message}');
  });
  
  // Parse bootstrap peers from command line
  List<MultiAddr>? bootstrapPeers;
  if (args.isNotEmpty) {
    bootstrapPeers = args.map((addr) => MultiAddr(addr)).toList();
    print('Using bootstrap peers: $bootstrapPeers');
  }
  
  final node = MobileP2PNode();
  
  try {
    // Initialize the mobile node
    await node.initialize(
      bootstrapPeers: bootstrapPeers,
      enableBackgroundRefresh: true,
    );
    
    // Simulate mobile app lifecycle
    await _simulateMobileUsage(node);
    
  } catch (e, stackTrace) {
    print('Error: $e');
    print('Stack trace: $stackTrace');
  } finally {
    await node.shutdown();
  }
}

/// Simulate typical mobile app usage patterns
Future<void> _simulateMobileUsage(MobileP2PNode node) async {
  print('\n=== Mobile P2P Node Usage Simulation ===');
  
  // Initial network stats
  await node.printNetworkStats();
  
  // Simulate finding some content
  print('\n--- Simulating content discovery ---');
  await node.findContentProviders('QmExampleContent123', maxProviders: 2);
  
  // Simulate retrieving a value
  print('\n--- Simulating value retrieval ---');
  await node.retrieveValue('mobile-test-key');
  
  // Simulate finding a service
  print('\n--- Simulating service discovery ---');
  await node.findServiceProviders('mobile-chat-service', maxPeers: 2);
  
  // Simulate app going to background (pause background tasks)
  print('\n--- Simulating app backgrounding ---');
  node.pauseBackgroundTasks();
  await Future.delayed(Duration(seconds: 5));
  
  // Simulate app coming to foreground (resume background tasks)
  print('\n--- Simulating app foregrounding ---');
  node.resumeBackgroundTasks();
  
  // Manual refresh when user actively uses the app
  print('\n--- Simulating manual refresh ---');
  await node.refresh();
  
  // Final network stats
  print('\n--- Final network statistics ---');
  await node.printNetworkStats();
  
  print('\n--- Mobile simulation completed ---');
}
