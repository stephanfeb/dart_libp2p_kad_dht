/// High-Performance Server Node Example
/// 
/// This example demonstrates how to create a high-performance P2P server node
/// using the Dart libp2p Kademlia DHT optimized for server environments.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

class ServerP2PNode {
  late final Host host;
  late final IpfsDHT dht;
  late final ProviderStore providerStore;
  late final String nodeId;
  
  Timer? _metricsTimer;
  Timer? _healthCheckTimer;
  bool _isRunning = false;
  
  // Server-specific configuration
  static const Duration metricsInterval = Duration(minutes: 5);
  static const Duration healthCheckInterval = Duration(minutes: 2);
  static const int maxRoutingTableSize = 2000;
  static const int maxProviderCacheSize = 10000;
  static const int serverPort = 4001;
  
  // Performance metrics
  int _totalQueries = 0;
  int _successfulQueries = 0;
  int _totalProvides = 0;
  int _totalBootstraps = 0;
  DateTime? _startTime;
  
  /// Initialize the high-performance server node
  Future<void> initialize({
    List<MultiAddr>? bootstrapPeers,
    int? listenPort,
    bool enableMetrics = true,
    bool enableHealthChecks = true,
  }) async {
    print('Initializing high-performance server node...');
    _startTime = DateTime.now();
    
    // Create the libp2p host with server-optimized settings
    final port = listenPort ?? serverPort;
    final nodeDetails = await createLibp2pNode(
      udxInstance: UDX(),
      resourceManager: NullResourceManager(),
      connManager: p2p_conn_mgr.ConnectionManager(),
      hostEventBus: p2p_event_bus.BasicBus(),
      // Listen on all interfaces for server deployment
      listenAddrsOverride: [
        MultiAddr('/ip4/0.0.0.0/tcp/$port'),
        MultiAddr('/ip4/0.0.0.0/udp/$port/quic'),
      ],
    );
    host = nodeDetails.host;
    nodeId = host.id.toBase58().substring(0, 8);
    
    print('[$nodeId] Server node created with ID: ${host.id.toBase58()}');
    print('[$nodeId] Listening on port: $port');
    
    // Create provider store with large cache for server workloads
    providerStore = MemoryProviderStore(
      ProviderManagerOptions(
        cacheSize: maxProviderCacheSize,
        cleanupInterval: Duration(minutes: 10),
      ),
    );
    
    // Server-optimized DHT configuration
    final dhtOptions = <DHTOption>[
      mode(DHTMode.server),           // Full server mode
      bucketSize(20),                 // Larger routing table buckets
      concurrency(10),                // High network concurrency
      resiliency(3),                  // More required responses for reliability
      maxDhtMessageRetries(3),        // More retry attempts
      dhtMessageRetryMaxBackoff(Duration(seconds: 30)),
      // Auto-refresh is enabled by default for server mode
      // Server-specific optimizations
      maxPeersPerBucket(30),          // More peers per bucket for servers
      dht_opts.maxRoutingTableSize(maxRoutingTableSize), // Large routing table
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
      
      dhtOptions.add(dht_opts.bootstrapPeers(addrInfos));
    }
    
    // Create and start the DHT
    dht = await DHT.new_(host, providerStore, dhtOptions);
    await dht.start();
    print('[$nodeId] Server DHT started in server mode');
    
    // Initial bootstrap
    await dht.bootstrap();
    _totalBootstraps++;
    print('[$nodeId] Initial bootstrap completed');
    
    // Set up server monitoring
    if (enableMetrics) {
      _setupMetricsReporting();
    }
    
    if (enableHealthChecks) {
      _setupHealthChecks();
    }
    
    _isRunning = true;
    print('[$nodeId] High-performance server node is ready!');
    print('[$nodeId] Server listening addresses:');
    for (final addr in host.addrs) {
      print('  - $addr');
    }
  }
  
  /// Set up metrics reporting for server monitoring
  void _setupMetricsReporting() {
    print('[$nodeId] Setting up metrics reporting');
    
    _metricsTimer = Timer.periodic(metricsInterval, (_) async {
      if (!_isRunning) return;
      
      try {
        await _reportMetrics();
      } catch (e) {
        print('[$nodeId] Error during metrics reporting: $e');
      }
    });
  }
  
  /// Set up health checks for server monitoring
  void _setupHealthChecks() {
    print('[$nodeId] Setting up health checks');
    
    _healthCheckTimer = Timer.periodic(healthCheckInterval, (_) async {
      if (!_isRunning) return;
      
      try {
        await _performHealthCheck();
      } catch (e) {
        print('[$nodeId] Error during health check: $e');
      }
    });
  }
  
  /// Report server metrics
  Future<void> _reportMetrics() async {
    final uptime = _startTime != null 
        ? DateTime.now().difference(_startTime!).inMinutes 
        : 0;
    
    final tableSize = await dht.routingTable.size();
    final successRate = _totalQueries > 0 
        ? (_successfulQueries / _totalQueries * 100).toStringAsFixed(1)
        : '0.0';
    
    print('[$nodeId] === Server Metrics Report ===');
    print('  - Uptime: ${uptime} minutes');
    print('  - Routing table size: $tableSize peers');
    print('  - Total queries handled: $_totalQueries');
    print('  - Query success rate: $successRate%');
    print('  - Total provides: $_totalProvides');
    print('  - Total bootstraps: $_totalBootstraps');
    print('  - Memory usage: ${_getMemoryUsage()} MB');
  }
  
  /// Perform health check
  Future<void> _performHealthCheck() async {
    final issues = <String>[];
    
    // Check routing table health
    final tableSize = await dht.routingTable.size();
    if (tableSize < 10) {
      issues.add('Low routing table size: $tableSize peers');
    }
    
    // Check network connectivity
    try {
      await dht.bootstrap(quickConnectOnly: true);
    } catch (e) {
      issues.add('Bootstrap connectivity issue: $e');
    }
    
    // Check provider store health
    // Note: In a real implementation, you'd check provider store metrics
    
    if (issues.isEmpty) {
      print('[$nodeId] Health check: OK');
    } else {
      print('[$nodeId] Health check: ISSUES DETECTED');
      for (final issue in issues) {
        print('  - $issue');
      }
    }
  }
  
  /// Get approximate memory usage in MB
  double _getMemoryUsage() {
    // This is a simplified memory estimation
    // In a real server, you'd use proper memory monitoring
    return ProcessInfo.currentRss / (1024 * 1024);
  }
  
  /// Find a peer with server-grade reliability
  Future<AddrInfo?> findPeer(String peerIdString, {Duration? timeout}) async {
    if (!_isRunning) throw StateError('Node not running');
    
    final peerId = PeerId.fromString(peerIdString);
    print('[$nodeId] Server finding peer: ${peerIdString.substring(0, 8)}...');
    
    _totalQueries++;
    
    try {
      final peerInfo = await dht.findPeer(peerId).timeout(
        timeout ?? Duration(minutes: 2),
      );
      
      if (peerInfo != null) {
        _successfulQueries++;
        print('[$nodeId] Server found peer ${peerIdString.substring(0, 8)}');
        return peerInfo;
      } else {
        print('[$nodeId] Server: peer ${peerIdString.substring(0, 8)} not found');
        return null;
      }
    } on TimeoutException {
      print('[$nodeId] Server timeout finding peer ${peerIdString.substring(0, 8)}');
      return null;
    }
  }
  
  /// Find content providers with server-grade performance
  Future<List<AddrInfo>> findContentProviders(
    String contentId, {
    int maxProviders = 20,
    Duration? timeout,
  }) async {
    if (!_isRunning) throw StateError('Node not running');
    
    final cid = CID.fromString(contentId);
    print('[$nodeId] Server finding providers for: $contentId (max: $maxProviders)');
    
    _totalQueries++;
    final providers = <AddrInfo>[];
    
    try {
      final stream = dht.findProvidersAsync(cid, maxProviders);
      
      await for (final provider in stream.timeout(timeout ?? Duration(minutes: 3))) {
        providers.add(provider);
        print('[$nodeId] Server found provider: ${provider.id.toBase58().substring(0, 8)}');
        
        if (providers.length >= maxProviders) break;
      }
      
      if (providers.isNotEmpty) {
        _successfulQueries++;
      }
    } on TimeoutException {
      print('[$nodeId] Server timeout finding providers for $contentId');
    }
    
    print('[$nodeId] Server found ${providers.length} providers for $contentId');
    return providers;
  }
  
  /// Store a value with server reliability
  Future<bool> storeValue(String key, String value, {Duration? timeout}) async {
    if (!_isRunning) throw StateError('Node not running');
    
    print('[$nodeId] Server storing value for key: $key');
    
    _totalQueries++;
    
    try {
      final valueBytes = utf8.encode(value);
      await dht.putValue(key, valueBytes).timeout(
        timeout ?? Duration(minutes: 2),
      );
      
      _successfulQueries++;
      _totalProvides++;
      print('[$nodeId] Server successfully stored value for key: $key');
      return true;
    } on TimeoutException {
      print('[$nodeId] Server timeout storing value for key: $key');
      return false;
    } catch (e) {
      print('[$nodeId] Server error storing value for key $key: $e');
      return false;
    }
  }
  
  /// Retrieve a value with server performance
  Future<String?> retrieveValue(String key, {Duration? timeout}) async {
    if (!_isRunning) throw StateError('Node not running');
    
    print('[$nodeId] Server retrieving value for key: $key');
    
    _totalQueries++;
    
    try {
      final valueBytes = await dht.getValue(key, null).timeout(
        timeout ?? Duration(minutes: 2),
      );
      
      if (valueBytes != null) {
        _successfulQueries++;
        final value = utf8.decode(valueBytes);
        print('[$nodeId] Server retrieved value: $value');
        return value;
      } else {
        print('[$nodeId] Server: no value found for key: $key');
        return null;
      }
    } on TimeoutException {
      print('[$nodeId] Server timeout retrieving value for key: $key');
      return null;
    }
  }
  
  /// Provide content to the network
  Future<bool> provideContent(String contentId, {Duration? timeout}) async {
    if (!_isRunning) throw StateError('Node not running');
    
    final cid = CID.fromString(contentId);
    print('[$nodeId] Server providing content: $contentId');
    
    _totalQueries++;
    
    try {
      await dht.provide(cid, true).timeout(
        timeout ?? Duration(minutes: 2),
      );
      
      _successfulQueries++;
      _totalProvides++;
      print('[$nodeId] Server successfully provided content: $contentId');
      return true;
    } on TimeoutException {
      print('[$nodeId] Server timeout providing content: $contentId');
      return false;
    } catch (e) {
      print('[$nodeId] Server error providing content $contentId: $e');
      return false;
    }
  }
  
  /// Find service providers with server performance
  Future<List<AddrInfo>> findServiceProviders(
    String serviceName, {
    int maxPeers = 50,
    Duration? timeout,
  }) async {
    if (!_isRunning) throw StateError('Node not running');
    
    print('[$nodeId] Server finding service providers: $serviceName (max: $maxPeers)');
    
    _totalQueries++;
    final providers = <AddrInfo>[];
    
    try {
      final stream = await dht.findPeers(serviceName);
      
      await for (final peer in stream.timeout(timeout ?? Duration(minutes: 3))) {
        providers.add(peer);
        print('[$nodeId] Server found service provider: ${peer.id.toBase58().substring(0, 8)}');
        
        if (providers.length >= maxPeers) break;
      }
      
      if (providers.isNotEmpty) {
        _successfulQueries++;
      }
    } on TimeoutException {
      print('[$nodeId] Server timeout finding service providers for: $serviceName');
    }
    
    print('[$nodeId] Server found ${providers.length} providers for service: $serviceName');
    return providers;
  }
  
  /// Get comprehensive server statistics
  Future<ServerNetworkStats> getNetworkStats() async {
    if (!_isRunning) throw StateError('Node not running');
    
    final tableSize = await dht.routingTable.size();
    final uptime = _startTime != null 
        ? DateTime.now().difference(_startTime!) 
        : Duration.zero;
    
    int? networkSize;
    try {
      networkSize = await dht.nsEstimator.networkSize();
    } catch (e) {
      print('[$nodeId] Could not estimate network size: $e');
    }
    
    return ServerNetworkStats(
      routingTableSize: tableSize,
      estimatedNetworkSize: networkSize,
      localPeerId: host.id.toBase58(),
      uptime: uptime,
      totalQueries: _totalQueries,
      successfulQueries: _successfulQueries,
      totalProvides: _totalProvides,
      totalBootstraps: _totalBootstraps,
      memoryUsageMB: _getMemoryUsage(),
      isMetricsActive: _metricsTimer?.isActive ?? false,
      isHealthCheckActive: _healthCheckTimer?.isActive ?? false,
    );
  }
  
  /// Print comprehensive server statistics
  Future<void> printNetworkStats() async {
    final stats = await getNetworkStats();
    
    print('[$nodeId] === Server Network Statistics ===');
    print('  - Uptime: ${stats.uptime.inMinutes} minutes');
    print('  - Routing table size: ${stats.routingTableSize} peers');
    if (stats.estimatedNetworkSize != null) {
      print('  - Estimated network size: ${stats.estimatedNetworkSize} peers');
    } else {
      print('  - Estimated network size: Unable to estimate');
    }
    print('  - Local peer ID: ${stats.localPeerId}');
    print('  - Total queries: ${stats.totalQueries}');
    print('  - Successful queries: ${stats.successfulQueries}');
    final successRate = stats.totalQueries > 0 
        ? (stats.successfulQueries / stats.totalQueries * 100).toStringAsFixed(1)
        : '0.0';
    print('  - Success rate: $successRate%');
    print('  - Total provides: ${stats.totalProvides}');
    print('  - Total bootstraps: ${stats.totalBootstraps}');
    print('  - Memory usage: ${stats.memoryUsageMB.toStringAsFixed(1)} MB');
    print('  - Metrics reporting: ${stats.isMetricsActive ? "Active" : "Inactive"}');
    print('  - Health checks: ${stats.isHealthCheckActive ? "Active" : "Inactive"}');
  }
  
  /// Perform server maintenance
  Future<void> performMaintenance() async {
    if (!_isRunning) throw StateError('Node not running');
    
    print('[$nodeId] Performing server maintenance...');
    
    // Force bootstrap to refresh connections
    await dht.bootstrap();
    _totalBootstraps++;
    
    // Trigger health check
    await _performHealthCheck();
    
    // Report current metrics
    await _reportMetrics();
    
    print('[$nodeId] Server maintenance completed');
  }
  
  /// Shutdown the server node
  Future<void> shutdown() async {
    if (!_isRunning) return;
    
    print('[$nodeId] Shutting down server node...');
    
    _isRunning = false;
    
    // Cancel monitoring tasks
    _metricsTimer?.cancel();
    _healthCheckTimer?.cancel();
    
    // Final metrics report
    await _reportMetrics();
    
    // Close DHT and related resources
    await dht.close();
    await providerStore.close();
    await host.close();
    
    print('[$nodeId] Server node shutdown complete');
  }
}

/// Server-specific network statistics
class ServerNetworkStats {
  final int routingTableSize;
  final int? estimatedNetworkSize;
  final String localPeerId;
  final Duration uptime;
  final int totalQueries;
  final int successfulQueries;
  final int totalProvides;
  final int totalBootstraps;
  final double memoryUsageMB;
  final bool isMetricsActive;
  final bool isHealthCheckActive;
  
  ServerNetworkStats({
    required this.routingTableSize,
    this.estimatedNetworkSize,
    required this.localPeerId,
    required this.uptime,
    required this.totalQueries,
    required this.successfulQueries,
    required this.totalProvides,
    required this.totalBootstraps,
    required this.memoryUsageMB,
    required this.isMetricsActive,
    required this.isHealthCheckActive,
  });
}

/// Example usage for server deployments
Future<void> main(List<String> args) async {
  // Setup comprehensive logging for server
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    final timestamp = DateTime.now().toIso8601String();
    print('[$timestamp] ${record.level.name}: ${record.message}');
  });
  
  // Parse command line arguments
  List<MultiAddr>? bootstrapPeers;
  int? listenPort;
  
  for (int i = 0; i < args.length; i++) {
    if (args[i] == '--bootstrap' && i + 1 < args.length) {
      bootstrapPeers = args[i + 1].split(',').map((addr) => MultiAddr(addr)).toList();
    } else if (args[i] == '--port' && i + 1 < args.length) {
      listenPort = int.tryParse(args[i + 1]);
    }
  }
  
  if (bootstrapPeers != null) {
    print('Using bootstrap peers: $bootstrapPeers');
  }
  if (listenPort != null) {
    print('Using listen port: $listenPort');
  }
  
  final node = ServerP2PNode();
  
  // Handle shutdown gracefully
  ProcessSignal.sigint.watch().listen((_) async {
    print('\nReceived SIGINT, shutting down gracefully...');
    await node.shutdown();
    exit(0);
  });
  
  try {
    // Initialize the server node
    await node.initialize(
      bootstrapPeers: bootstrapPeers,
      listenPort: listenPort,
      enableMetrics: true,
      enableHealthChecks: true,
    );
    
    // Run server operations
    await _runServerOperations(node);
    
  } catch (e, stackTrace) {
    print('Server error: $e');
    print('Stack trace: $stackTrace');
  } finally {
    await node.shutdown();
  }
}

/// Run typical server operations
Future<void> _runServerOperations(ServerP2PNode node) async {
  print('\n=== High-Performance Server Operations ===');
  
  // Initial network stats
  await node.printNetworkStats();
  
  // Store some test values
  print('\n--- Server storing test values ---');
  await node.storeValue('server-config', '{"version": "1.0", "mode": "production"}');
  await node.storeValue('server-status', 'online');
  
  // Provide some test content
  print('\n--- Server providing test content ---');
  await node.provideContent('QmServerContent123');
  await node.provideContent('QmServerData456');
  
  // Demonstrate server queries
  print('\n--- Server performing queries ---');
  await node.findContentProviders('QmExampleContent789', maxProviders: 10);
  await node.retrieveValue('test-key');
  await node.findServiceProviders('distributed-storage', maxPeers: 20);
  
  // Perform maintenance
  print('\n--- Server maintenance ---');
  await node.performMaintenance();
  
  // Keep server running
  print('\n--- Server running (press Ctrl+C to stop) ---');
  while (true) {
    await Future.delayed(Duration(seconds: 30));
    await node.printNetworkStats();
  }
}
