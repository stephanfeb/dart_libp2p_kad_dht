/// Basic P2P Node Example
/// 
/// This example demonstrates how to create a basic P2P node using the Dart libp2p
/// Kademlia DHT. It shows peer discovery, content routing, and value storage.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dcid/dcid.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_mgr;
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;
import 'package:dart_udx/dart_udx.dart';
import 'package:logging/logging.dart';

// Import your real network stack utilities
// This would be your actual libp2p host creation logic
import '../test/real_net_stack.dart';

class BasicP2PNode {
  late final Host host;
  late final IpfsDHT dht;
  late final ProviderStore providerStore;
  late final String nodeId;
  
  bool _isRunning = false;
  
  /// Initialize the P2P node
  Future<void> initialize({List<MultiAddr>? bootstrapPeers}) async {
    print('Initializing P2P node...');
    
    // Create the libp2p host
    final nodeDetails = await createLibp2pNode(
      udxInstance: UDX(),
      resourceManager: NullResourceManager(),
      connManager: p2p_conn_mgr.ConnectionManager(),
      hostEventBus: p2p_event_bus.BasicBus(),
    );
    host = nodeDetails.host;
    nodeId = host.id.toBase58().substring(0, 8);
    
    print('[$nodeId] Node created with ID: ${host.id.toBase58()}');
    print('[$nodeId] Listening on: ${host.addrs}');
    
    // Create provider store for content routing
    providerStore = MemoryProviderStore();
    
    // Configure DHT with bootstrap peers if provided
    final dhtOptions = DHTOptions(
      mode: DHTMode.auto,
      bucketSize: 20,
      concurrency: 10,
      resiliency: 3,
      bootstrapPeers: bootstrapPeers,
    );
    
    // Create and start the DHT
    dht = IpfsDHT(
      host: host,
      providerStore: providerStore,
      options: dhtOptions,
    );
    
    await dht.start();
    print('[$nodeId] DHT started');
    
    // Bootstrap into the network
    await dht.bootstrap();
    print('[$nodeId] DHT bootstrapped');
    
    _isRunning = true;
    print('[$nodeId] P2P node is ready!');
  }
  
  /// Find a peer by their ID
  Future<AddrInfo?> findPeer(String peerIdString) async {
    if (!_isRunning) throw StateError('Node not running');
    
    final peerId = PeerId.fromString(peerIdString);
    print('[$nodeId] Looking for peer: ${peerIdString.substring(0, 8)}...');
    
    final peerInfo = await dht.findPeer(peerId);
    if (peerInfo != null) {
      print('[$nodeId] Found peer ${peerIdString.substring(0, 8)} at: ${peerInfo.addrs}');
      return peerInfo;
    } else {
      print('[$nodeId] Peer ${peerIdString.substring(0, 8)} not found');
      return null;
    }
  }
  
  /// Announce that this node provides specific content
  Future<void> announceContent(String contentId) async {
    if (!_isRunning) throw StateError('Node not running');
    
    final cid = CID.fromString(contentId);
    print('[$nodeId] Announcing content: $contentId');
    
    await dht.provide(cid, true); // true = announce to network
    print('[$nodeId] Content announced successfully');
  }
  
  /// Find providers of specific content
  Future<List<AddrInfo>> findContentProviders(String contentId, {int maxProviders = 5}) async {
    if (!_isRunning) throw StateError('Node not running');
    
    final cid = CID.fromString(contentId);
    print('[$nodeId] Looking for providers of content: $contentId');
    
    final providers = <AddrInfo>[];
    final stream = dht.findProvidersAsync(cid, maxProviders);
    
    await for (final provider in stream) {
      providers.add(provider);
      print('[$nodeId] Found provider: ${provider.id.toBase58().substring(0, 8)}');
      
      if (providers.length >= maxProviders) break;
    }
    
    print('[$nodeId] Found ${providers.length} providers for $contentId');
    return providers;
  }
  
  /// Store a key-value pair in the DHT
  Future<void> storeValue(String key, String value) async {
    if (!_isRunning) throw StateError('Node not running');
    
    print('[$nodeId] Storing value for key: $key');
    final valueBytes = utf8.encode(value);
    
    await dht.putValue(key, valueBytes);
    print('[$nodeId] Value stored successfully');
  }
  
  /// Retrieve a value from the DHT
  Future<String?> retrieveValue(String key) async {
    if (!_isRunning) throw StateError('Node not running');
    
    print('[$nodeId] Retrieving value for key: $key');
    
    final valueBytes = await dht.getValue(key, null);
    if (valueBytes != null) {
      final value = utf8.decode(valueBytes);
      print('[$nodeId] Retrieved value: $value');
      return value;
    } else {
      print('[$nodeId] No value found for key: $key');
      return null;
    }
  }
  
  /// Advertise a service in a namespace
  Future<void> advertiseService(String serviceName) async {
    if (!_isRunning) throw StateError('Node not running');
    
    print('[$nodeId] Advertising service: $serviceName');
    
    final ttl = await dht.advertise(serviceName);
    print('[$nodeId] Service advertised with TTL: $ttl');
  }
  
  /// Find peers providing a specific service
  Future<List<AddrInfo>> findServiceProviders(String serviceName, {int maxPeers = 10}) async {
    if (!_isRunning) throw StateError('Node not running');
    
    print('[$nodeId] Looking for service providers: $serviceName');
    
    final providers = <AddrInfo>[];
    final stream = await dht.findPeers(serviceName);
    
    await for (final peer in stream) {
      providers.add(peer);
      print('[$nodeId] Found service provider: ${peer.id.toBase58().substring(0, 8)}');
      
      if (providers.length >= maxPeers) break;
    }
    
    print('[$nodeId] Found ${providers.length} providers for service: $serviceName');
    return providers;
  }
  
  /// Get network statistics
  Future<void> printNetworkStats() async {
    if (!_isRunning) throw StateError('Node not running');
    
    final tableSize = await dht.routingTable.size();
    final networkSize = await dht.nsEstimator.networkSize();
    
    print('[$nodeId] Network Statistics:');
    print('  - Routing table size: $tableSize peers');
    print('  - Estimated network size: $networkSize peers');
    print('  - Local peer ID: ${host.id.toBase58()}');
    print('  - Listening addresses: ${host.addrs}');
  }
  
  /// Shutdown the node
  Future<void> shutdown() async {
    if (!_isRunning) return;
    
    print('[$nodeId] Shutting down...');
    
    _isRunning = false;
    await dht.close();
    await providerStore.close();
    await host.close();
    
    print('[$nodeId] Shutdown complete');
  }
}

/// Example usage and interactive demo
Future<void> main(List<String> args) async {
  // Setup logging
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.loggerName}: ${record.message}');
  });
  
  // Parse command line arguments for bootstrap peers
  List<MultiAddr>? bootstrapPeers;
  if (args.isNotEmpty) {
    bootstrapPeers = args.map((addr) => MultiAddr(addr)).toList();
    print('Using bootstrap peers: $bootstrapPeers');
  }
  
  final node = BasicP2PNode();
  
  try {
    // Initialize the node
    await node.initialize(bootstrapPeers: bootstrapPeers);
    
    // Interactive demo
    await runInteractiveDemo(node);
    
  } catch (e, stackTrace) {
    print('Error: $e');
    print('Stack trace: $stackTrace');
  } finally {
    await node.shutdown();
  }
}

/// Interactive demo showing various DHT operations
Future<void> runInteractiveDemo(BasicP2PNode node) async {
  print('\n=== P2P Node Interactive Demo ===');
  print('Commands:');
  print('  stats - Show network statistics');
  print('  store <key> <value> - Store a key-value pair');
  print('  get <key> - Retrieve a value');
  print('  announce <content-id> - Announce content');
  print('  find-content <content-id> - Find content providers');
  print('  advertise <service> - Advertise a service');
  print('  find-service <service> - Find service providers');
  print('  find-peer <peer-id> - Find a specific peer');
  print('  quit - Exit the demo');
  print('');
  
  while (true) {
    stdout.write('> ');
    final input = stdin.readLineSync()?.trim();
    if (input == null || input.isEmpty) continue;
    
    final parts = input.split(' ');
    final command = parts[0].toLowerCase();
    
    try {
      switch (command) {
        case 'stats':
          await node.printNetworkStats();
          break;
          
        case 'store':
          if (parts.length < 3) {
            print('Usage: store <key> <value>');
            break;
          }
          final key = parts[1];
          final value = parts.sublist(2).join(' ');
          await node.storeValue(key, value);
          break;
          
        case 'get':
          if (parts.length < 2) {
            print('Usage: get <key>');
            break;
          }
          final key = parts[1];
          final value = await node.retrieveValue(key);
          if (value != null) {
            print('Value: $value');
          }
          break;
          
        case 'announce':
          if (parts.length < 2) {
            print('Usage: announce <content-id>');
            break;
          }
          final contentId = parts[1];
          await node.announceContent(contentId);
          break;
          
        case 'find-content':
          if (parts.length < 2) {
            print('Usage: find-content <content-id>');
            break;
          }
          final contentId = parts[1];
          await node.findContentProviders(contentId);
          break;
          
        case 'advertise':
          if (parts.length < 2) {
            print('Usage: advertise <service>');
            break;
          }
          final service = parts[1];
          await node.advertiseService(service);
          break;
          
        case 'find-service':
          if (parts.length < 2) {
            print('Usage: find-service <service>');
            break;
          }
          final service = parts[1];
          await node.findServiceProviders(service);
          break;
          
        case 'find-peer':
          if (parts.length < 2) {
            print('Usage: find-peer <peer-id>');
            break;
          }
          final peerId = parts[1];
          await node.findPeer(peerId);
          break;
          
        case 'quit':
        case 'exit':
          print('Exiting demo...');
          return;
          
        default:
          print('Unknown command: $command');
          break;
      }
    } catch (e) {
      print('Error executing command: $e');
    }
    
    print(''); // Empty line for readability
  }
}
