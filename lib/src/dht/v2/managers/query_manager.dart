import 'dart:async';
import 'dart:typed_data';

import 'package:dcid/dcid.dart';
import 'package:dart_libp2p/core/discovery.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/routing/options.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:logging/logging.dart';

import '../../../query/qpeerset.dart';
import '../../../query/query_runner.dart';
import '../../../pb/dht_message.dart';
import '../../../pb/record.dart';
import '../../../providers/provider_store.dart';
import '../../../record/record_signer.dart';
import '../config/dht_config.dart';
import '../errors/dht_errors.dart';
import 'metrics_manager.dart';
import 'network_manager.dart';
import 'routing_manager.dart';
import 'protocol_manager.dart';
// // Simplified types for DHT v2 compatibility
// class QueryPeerset {
//   const QueryPeerset();
// }

class LookupWithFollowupResult {
  final List<PeerId> peers;
  final LookupTerminationReason terminationReason;
  final List<dynamic> errors;
  
  const LookupWithFollowupResult({
    required this.peers,
    required this.terminationReason,
    required this.errors,
  });
}

enum LookupTerminationReason {
  success,
  timeout,
  cancelled,
  noMorePeers,
}

/// Manages query operations for DHT v2
/// 
/// This component handles:
/// - Peer lookups
/// - Value operations
/// - Provider operations
/// - Discovery operations
/// - Query coordination
class QueryManager {
  static final Logger _logger = Logger('QueryManager');
  
  // Dependencies
  NetworkManager? _network;
  RoutingManager? _routing;
  ProtocolManager? _protocol;
  DHTConfigV2? _config;
  MetricsManager? _metrics;
  ProviderStore? _providerStore;
  
  // State
  bool _started = false;
  bool _closed = false;
  
  QueryManager();
  
  /// Initializes the query manager
  void initialize({
    required NetworkManager network,
    required RoutingManager routing,
    required ProtocolManager protocol,
    required DHTConfigV2 config,
    required MetricsManager metrics,
    required ProviderStore providerStore,
  }) {
    _network = network;
    _routing = routing;
    _protocol = protocol;
    _config = config;
    _metrics = metrics;
    _providerStore = providerStore;
  }
  
  /// Starts the query manager
  Future<void> start() async {
    if (_started || _closed) return;
    
    _logger.info('Starting QueryManager...');
    _started = true;
    _logger.info('QueryManager started');
  }
  
  /// Stops the query manager
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    
    _logger.info('Closing QueryManager...');
    _logger.info('QueryManager closed');
  }
  
  /// Finds a peer by ID
  Future<AddrInfo?> findPeer(PeerId id, {RoutingOptions? options}) async {
    _ensureStarted();
    
    final stopwatch = Stopwatch()..start();
    _metrics?.recordQueryStart();
    
    try {
      _logger.info('Finding peer ${id.toBase58().substring(0, 6)}...');
      
      // Check routing table first
      final existingPeer = await _routing?.findPeer(id);
      if (existingPeer != null) {
        // Get address info from peerstore
        final peerInfo = await _network?.host.peerStore.getPeer(id);
        if (peerInfo != null && peerInfo.addrs.isNotEmpty) {
          // Peer has addresses in peerstore - return them immediately
          stopwatch.stop();
          _metrics?.recordQuerySuccess(stopwatch.elapsed);
          _logger.fine('Found peer ${id.toBase58().substring(0, 6)} with ${peerInfo.addrs.length} peerstore addresses');
          return AddrInfo(id, peerInfo.addrs.toList());
        } else {
          // CRITICAL FIX: Peer exists in routing table but no addresses
          // Proceed with network query to discover addresses
          _logger.fine('Peer ${id.toBase58().substring(0, 6)} in routing table but no addresses - performing network query for address discovery');
        }
      } else {
        _logger.fine('Peer ${id.toBase58().substring(0, 6)} not in routing table - performing network query');
      }
      
      // Perform network query to discover addresses (for both routing table peers without addresses AND unknown peers)
      final result = await _performNetworkQuery(id, QueryType.findPeer, options);
      
      stopwatch.stop();
      _metrics?.recordQuerySuccess(stopwatch.elapsed);
      return result;
    } catch (e) {
      stopwatch.stop();
      _metrics?.recordQueryFailure('find_peer', peer: id);
      _logger.warning('Failed to find peer ${id.toBase58().substring(0, 6)}: $e');
      return null;
    }
  }
  
  /// Gets closest peers to a target
  Future<List<AddrInfo>> getClosestPeers(PeerId target, {bool networkQueryEnabled = true}) async {
    _ensureStarted();
    
    final stopwatch = Stopwatch()..start();
    _metrics?.recordQueryStart();
    
    try {
      _logger.info('Getting closest peers to ${target.toBase58().substring(0, 6)}...');
      
      // Get peers from routing table
      final targetBytes = target.toBytes();
      final closestPeers = await _routing?.getNearestPeers(targetBytes, _config?.bucketSize ?? 20) ?? [];
      
      // Convert to AddrInfo - CRITICAL FIX: Return all routing table peers, even without peerstore addresses
      final result = <AddrInfo>[];
      for (final peerId in closestPeers) {
        // Try to get addresses from peerstore first
        final peerInfo = await _network?.host.peerStore.getPeer(peerId);
        if (peerInfo != null && peerInfo.addrs.isNotEmpty) {
          // Peer has addresses in peerstore - use them
          result.add(AddrInfo(peerId, peerInfo.addrs.toList()));
          _logger.finest('Added peer ${peerId.toBase58().substring(0, 6)} with ${peerInfo.addrs.length} peerstore addresses');
        } else {
          // CRITICAL FIX: Peer is in routing table but not peerstore - still return it!
          // Network maintenance can attempt connection and discover addresses
          result.add(AddrInfo(peerId, [])); // Empty addresses - will be discovered during connection
          _logger.finest('Added peer ${peerId.toBase58().substring(0, 6)} with empty addresses (routing table only)');
        }
      }
      
      stopwatch.stop();
      _metrics?.recordQuerySuccess(stopwatch.elapsed);
      
      _logger.info('Found ${result.length} closest peers (${closestPeers.length} from routing table)');
      return result;
    } catch (e) {
      stopwatch.stop();
      _metrics?.recordQueryFailure('get_closest_peers', peer: target);
      _logger.warning('Failed to get closest peers: $e');
      return [];
    }
  }
  
  /// Finds providers for a CID
  Stream<AddrInfo> findProvidersAsync(CID cid, int count) async* {
    _ensureStarted();
    
    _logger.info('Finding providers for CID ${cid.toString().substring(0, 10)}...');
    
    final stopwatch = Stopwatch()..start();
    _metrics?.recordQueryStart();
    
    try {
      final cidBytes = cid.toBytes();
      final controller = StreamController<AddrInfo>();
      final foundProviders = <PeerId>{};
      
      // Start the provider search asynchronously
      _findProvidersAsync(cidBytes, count, controller, foundProviders);
      
      yield* controller.stream;
      
      stopwatch.stop();
      _metrics?.recordQuerySuccess(stopwatch.elapsed);
      
      _logger.info('Provider search completed for CID ${cid.toString().substring(0, 10)}. Found ${foundProviders.length} providers');
    } catch (e) {
      stopwatch.stop();
      _metrics?.recordQueryFailure('find_providers');
      _logger.warning('Failed to find providers for CID ${cid.toString().substring(0, 10)}: $e');
      rethrow;
    }
  }
  
  /// Gets a value from the DHT
  Future<Uint8List?> getValue(String key, RoutingOptions? options) async {
    _ensureStarted();
    
    final stopwatch = Stopwatch()..start();
    _metrics?.recordQueryStart();
    
    try {
      _logger.info('Getting value for key: ${key.substring(0, 10)}...');
      
      final keyBytes = Uint8List.fromList(key.codeUnits);
      final foundRecords = <Record>[];
      
      // Check local datastore first
      _logger.fine('Checking local datastore for key');
      final localRecord = await _protocol?.getRecordFromDatastore(key);
      if (localRecord != null) {
        stopwatch.stop();
        _metrics?.recordQuerySuccess(stopwatch.elapsed);
        _logger.info('Found value in local datastore for key: ${key.substring(0, 10)}');
        return localRecord.value;
      }
      
      // Perform distributed lookup for the value
      // ignore: unused_local_variable - result not used; records collected via queryFn
      final result = await runLookupWithFollowup(
        target: keyBytes,
        queryFn: (peer) async {
          _logger.fine('Sending GET_VALUE to ${peer.toBase58().substring(0, 6)}');
          
          final message = Message(
            type: MessageType.getValue,
            key: keyBytes,
          );
          
          final response = await _network?.sendMessage(peer, message);
          if (response == null) {
            throw DHTNetworkException('No response from peer', peerId: peer);
          }
          
          // If we found a record, validate and collect it
          if (response.record != null) {
            try {
              // Validate the record signature
              final isValid = await RecordSigner.validateRecordSignature(response.record!);
              if (isValid) {
                foundRecords.add(response.record!);
                _logger.fine('Found and validated record from ${peer.toBase58().substring(0, 6)}');
              } else {
                _logger.warning('Invalid record signature from ${peer.toBase58().substring(0, 6)}');
              }
            } catch (e) {
              _logger.warning('Error validating record from ${peer.toBase58().substring(0, 6)}: $e');
            }
          }
          
          // Return closer peers for continued lookup
          return response.closerPeers.map((p) => AddrInfo(
            PeerId.fromBytes(p.id),
            p.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList(),
          )).toList();
        },
        stopFn: (peerset) {
          // Stop when we've queried enough peers or found valid records
          return foundRecords.isNotEmpty || 
                 peerset.getClosestInStates([PeerState.queried]).length >= (_config?.resiliency ?? 3);
        },
      );
      
      stopwatch.stop();
      _metrics?.recordQuerySuccess(stopwatch.elapsed);
      
      if (foundRecords.isNotEmpty) {
        // Select the most recent valid record
        foundRecords.sort((a, b) => b.timeReceived.compareTo(a.timeReceived));
        final bestRecord = foundRecords.first;
        
        _logger.info('Get value completed for key: ${key.substring(0, 10)} - found ${foundRecords.length} valid records');
        return bestRecord.value;
      } else {
        _logger.info('Get value completed for key: ${key.substring(0, 10)} - no valid records found');
        return null;
      }
    } catch (e) {
      stopwatch.stop();
      _metrics?.recordQueryFailure('get_value');
      _logger.warning('Failed to get value: $e');
      return null;
    }
  }
  
  /// Puts a value in the DHT
  Future<void> putValue(String key, Uint8List value, RoutingOptions? options) async {
    _ensureStarted();
    
    final stopwatch = Stopwatch()..start();
    _metrics?.recordQueryStart();
    
    try {
      _logger.info('Putting value for key: ${key.substring(0, 10)}...');
      
      final keyBytes = Uint8List.fromList(key.codeUnits);
      
      // Create a properly signed record
      final hostPrivateKey = await _network?.host.peerStore.keyBook.privKey(_network!.host.id);
      if (hostPrivateKey == null) {
        throw DHTNetworkException('Cannot sign record: host private key not available');
      }
      
      final signedRecord = await RecordSigner.createSignedRecord(
        key: key,
        value: value,
        privateKey: hostPrivateKey,
        peerId: _network!.host.id,
      );
      
      _logger.fine('Created signed record for key: ${key.substring(0, 10)}... (${signedRecord.signature.length} bytes signature)');
      
      // Store locally first
      await _protocol?.putRecordToDatastore(key, signedRecord);
      _logger.fine('Stored record locally for key: ${key.substring(0, 10)}...');
      
      // Find closest peers to store the value
      final result = await runLookupWithFollowup(
        target: keyBytes,
        queryFn: (peer) async {
          _logger.fine('Sending FIND_NODE to ${peer.toBase58().substring(0, 6)} for put operation');
          
          final message = Message(
            type: MessageType.findNode,
            key: keyBytes,
          );
          
          final response = await _network?.sendMessage(peer, message);
          if (response == null) {
            throw DHTNetworkException('No response from peer', peerId: peer);
          }
          
          return response.closerPeers.map((p) => AddrInfo(
            PeerId.fromBytes(p.id),
            p.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList(),
          )).toList();
        },
        stopFn: (peerset) {
          return peerset.getClosestInStates([PeerState.queried]).length >= (_config?.resiliency ?? 3);
        },
      );
      
      // Send PUT_VALUE to closest peers with the signed record
      final closestPeers = result.peers.take(_config?.resiliency ?? 3);
      var successCount = 0;
      
      for (final peer in closestPeers) {
        try {
          final putMessage = Message(
            type: MessageType.putValue,
            key: keyBytes,
            record: signedRecord,
          );
          
          await _network?.sendMessage(peer, putMessage);
          successCount++;
          _logger.fine('Successfully sent signed record to ${peer.toBase58().substring(0, 6)}');
        } catch (e) {
          _logger.warning('Failed to send signed record to ${peer.toBase58().substring(0, 6)}: $e');
        }
      }
      
      stopwatch.stop();
      _metrics?.recordQuerySuccess(stopwatch.elapsed);
      
      _logger.info('Put value completed for key: ${key.substring(0, 10)} - successfully stored to $successCount/${closestPeers.length} peers');
    } catch (e) {
      stopwatch.stop();
      _metrics?.recordQueryFailure('put_value');
      _logger.warning('Failed to put value: $e');
      rethrow;
    }
  }
  
  /// Searches for values in the DHT
  Stream<Uint8List> searchValue(String key, RoutingOptions? options) async* {
    _ensureStarted();
    
    _logger.info('Searching for values for key: ${key.substring(0, 10)}...');
    
    final keyBytes = Uint8List.fromList(key.codeUnits);
    final controller = StreamController<Uint8List>();
    
    // Run the search asynchronously
    _searchValueAsync(key, keyBytes, options, controller);
    
    yield* controller.stream;
  }
  
  /// Asynchronously searches for values
  Future<void> _searchValueAsync(String key, Uint8List keyBytes, RoutingOptions? options, StreamController<Uint8List> controller) async {
    try {
      // Check local datastore first
      _logger.fine('Checking local datastore for key');
      
      // Perform distributed search
      await runLookupWithFollowup(
        target: keyBytes,
        queryFn: (peer) async {
          _logger.fine('Sending GET_VALUE to ${peer.toBase58().substring(0, 6)} for search');
          
          final message = Message(
            type: MessageType.getValue,
            key: keyBytes,
          );
          
          final response = await _network?.sendMessage(peer, message);
          if (response == null) {
            throw DHTNetworkException('No response from peer', peerId: peer);
          }
          
          // If we found a record, add it to the stream
          if (response.record != null) {
            controller.add(response.record!.value);
          }
          
          return response.closerPeers.map((p) => AddrInfo(
            PeerId.fromBytes(p.id),
            p.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList(),
          )).toList();
        },
        stopFn: (peerset) {
          return peerset.getClosestInStates([PeerState.queried]).length >= (_config?.resiliency ?? 3);
        },
      );
      
      _logger.info('Search value completed for key: ${key.substring(0, 10)}');
    } catch (e) {
      _logger.warning('Search value failed for key: ${key.substring(0, 10)}: $e');
    } finally {
      controller.close();
    }
  }

  /// Asynchronously finds providers for a CID
  Future<void> _findProvidersAsync(Uint8List cidBytes, int count, StreamController<AddrInfo> controller, Set<PeerId> foundProviders) async {
    try {
      // Check local provider store first
      final localProviders = await getLocalProviders(cidBytes);
      for (final provider in localProviders) {
        if (foundProviders.length >= count) break;
        if (foundProviders.add(provider.id)) {
          controller.add(provider);
          _logger.fine('Added local provider ${provider.id.toBase58().substring(0, 6)}');
        }
      }
      
      // If we have enough providers locally, we can finish
      if (foundProviders.length >= count) {
        controller.close();
        return;
      }
      
      // Perform distributed lookup for providers
      await runLookupWithFollowup(
        target: cidBytes,
        queryFn: (peer) async {
          _logger.fine('Sending GET_PROVIDERS to ${peer.toBase58().substring(0, 6)}');
          
          final message = Message(
            type: MessageType.getProviders,
            key: cidBytes,
          );
          
          final response = await _network?.sendMessage(peer, message);
          if (response == null) {
            throw DHTNetworkException('No response from peer', peerId: peer);
          }
          
          // Add any providers found in the response
          for (final providerPeer in response.providerPeers) {
            if (foundProviders.length >= count) break;
            
            final providerId = PeerId.fromBytes(providerPeer.id);
            if (foundProviders.add(providerId)) {
              final providerInfo = AddrInfo(
                providerId,
                providerPeer.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList(),
              );
              controller.add(providerInfo);
              _logger.fine('Found provider ${providerId.toBase58().substring(0, 6)} from ${peer.toBase58().substring(0, 6)}');
            }
          }
          
          // Return closer peers for continued lookup
          return response.closerPeers.map((p) => AddrInfo(
            PeerId.fromBytes(p.id),
            p.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList(),
          )).toList();
        },
        stopFn: (peerset) {
          // Stop when we have enough providers or queried enough peers
          return foundProviders.length >= count || 
                 peerset.getClosestInStates([PeerState.queried]).length >= (_config?.resiliency ?? 3);
        },
      );
      
      _logger.info('Distributed provider search completed. Found ${foundProviders.length} providers');
    } catch (e) {
      _logger.warning('Provider search failed: $e');
    } finally {
      controller.close();
    }
  }
  
  /// Provides a CID to the DHT
  Future<void> provide(CID cid, bool announce) async {
    _ensureStarted();
    
    final stopwatch = Stopwatch()..start();
    _metrics?.recordQueryStart();
    
    try {
      _logger.info('Providing CID ${cid.toString().substring(0, 10)}...');
      
      final cidBytes = cid.toBytes();
      
      // Add ourselves as a provider locally
      final selfInfo = AddrInfo(_network!.host.id, []);
      await addProvider(cidBytes, selfInfo);
      
      if (announce) {
        // Find closest peers to announce to
        final result = await runLookupWithFollowup(
          target: cidBytes,
          queryFn: (peer) async {
            _logger.fine('Sending FIND_NODE to ${peer.toBase58().substring(0, 6)} for provider announcement');
            
            final message = Message(
              type: MessageType.findNode,
              key: cidBytes,
            );
            
            final response = await _network?.sendMessage(peer, message);
            if (response == null) {
              throw DHTNetworkException('No response from peer', peerId: peer);
            }
            
            return response.closerPeers.map((p) => AddrInfo(
              PeerId.fromBytes(p.id),
              p.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList(),
            )).toList();
          },
          stopFn: (peerset) {
            return peerset.getClosestInStates([PeerState.queried]).length >= (_config?.resiliency ?? 3);
          },
        );
        
        // Announce to closest peers
        final announcePeers = result.peers.take(_config?.resiliency ?? 3);
        var successCount = 0;
        
        for (final peer in announcePeers) {
          try {
            // Get our own addresses from peerstore
            final peerInfo = await _network?.host.peerStore.getPeer(_network!.host.id);
            final ourAddrs = peerInfo?.addrs.map((addr) => addr.toBytes()).toList() ?? <Uint8List>[];
            
            final addProviderMessage = Message(
              type: MessageType.addProvider,
              key: cidBytes,
              providerPeers: [
                Peer(
                  id: _network!.host.id.toBytes(),
                  addrs: ourAddrs,
                  connection: ConnectionType.connected,
                ),
              ],
            );
            
            await _network?.sendMessageFireAndForget(peer, addProviderMessage);
            successCount++;
            _logger.fine('Successfully announced provider to ${peer.toBase58().substring(0, 6)}');
          } catch (e) {
            _logger.warning('Failed to announce provider to ${peer.toBase58().substring(0, 6)}: $e');
          }
        }
        
        _logger.info('Provider announcement completed. Successfully announced to $successCount/${announcePeers.length} peers');
      }
      
      stopwatch.stop();
      _metrics?.recordQuerySuccess(stopwatch.elapsed);
      
      _logger.info('CID provided successfully');
    } catch (e) {
      stopwatch.stop();
      _metrics?.recordQueryFailure('provide');
      _logger.warning('Failed to provide CID: $e');
      rethrow;
    }
  }
  
  /// Adds a provider to the DHT
  Future<void> addProvider(Uint8List key, AddrInfo provider) async {
    _ensureStarted();
    
    _logger.info('Adding provider ${provider.id.toBase58().substring(0, 6)}...');
    
    try {
      // Store provider addresses in peerstore
      _network?.host.peerStore.addOrUpdatePeer(provider.id, addrs: provider.addrs);
      
      // Store provider in local provider store
      final cid = CID.fromBytes(key);
      await _providerStore?.addProvider(cid, provider);
      
      _metrics?.recordProviderStored();
      _logger.fine('Provider ${provider.id.toBase58().substring(0, 6)} added successfully');
    } catch (e) {
      _logger.warning('Failed to add provider ${provider.id.toBase58().substring(0, 6)}: $e');
      rethrow;
    }
  }
  
  /// Gets local providers for a key
  Future<List<AddrInfo>> getLocalProviders(Uint8List key) async {
    _ensureStarted();
    
    _logger.fine('Getting local providers for key...');
    
    try {
      // Get providers from the local provider store
      final cid = CID.fromBytes(key);
      final providers = await _providerStore?.getProviders(cid) ?? [];
      
      _metrics?.recordProviderRetrieved();
      _logger.fine('Found ${providers.length} local providers for key');
      
      return providers;
    } catch (e) {
      _logger.warning('Failed to get local providers: $e');
      return [];
    }
  }
  
  /// Advertises a namespace
  Future<Duration> advertise(String ns, [List<DiscoveryOption> options = const []]) async {
    _ensureStarted();
    
    _logger.info('Advertising namespace: $ns');
    
    // Simplified implementation - would normally advertise to network
    return Duration(minutes: 1);
  }
  
  /// Finds peers in a namespace
  Future<Stream<AddrInfo>> findPeers(String ns, [List<DiscoveryOption> options = const []]) async {
    _ensureStarted();
    
    _logger.info('Finding peers in namespace: $ns');
    
    // Simplified implementation - would normally query network
    final emptyController = StreamController<AddrInfo>();
    emptyController.close();
    return emptyController.stream;
  }
  
  /// Runs a lookup with followup - core DHT operation
  Future<LookupWithFollowupResult> runLookupWithFollowup({
    required Uint8List target,
    required Future<List<AddrInfo>> Function(PeerId peer) queryFn,
    required bool Function(QueryPeerset peerset) stopFn,
  }) async {
    _ensureStarted();
    
    final id = _network?.host.id.toBase58();
    final logPrefix = '[${id?.substring((id.length - 6).clamp(0, id.length)) ?? 'unknown'}.runLookupWithFollowup]';
    _logger.info('$logPrefix Starting lookup for target: ${target.take(10).toList()}...');

    // Get bootstrap peers for the query from routing table
    var queryPeers = await _routing?.getBootstrapPeers() ?? [];
    
    // FALLBACK: Use configured bootstrap peers if routing table is empty
    // This is critical for DHT client mode where routing table may be sparse
    if (queryPeers.isEmpty && _config?.bootstrapPeers != null && _config!.bootstrapPeers!.isNotEmpty) {
      _logger.info('$logPrefix Routing table empty, falling back to ${_config!.bootstrapPeers!.length} configured bootstrap peers');
      
      final configuredPeers = <AddrInfo>[];
      for (final ma in _config!.bootstrapPeers!) {
        try {
          final peerIdStr = ma.peerId;
          if (peerIdStr != null) {
            final peerId = PeerId.fromString(peerIdStr);
            configuredPeers.add(AddrInfo(peerId, [ma]));
            _logger.fine('$logPrefix Using configured bootstrap peer: ${peerId.toBase58().substring(0, 8)}...');
          }
        } catch (e) {
          _logger.warning('$logPrefix Failed to parse bootstrap multiaddr $ma: $e');
        }
      }
      queryPeers = configuredPeers;
    }
    
    if (queryPeers.isEmpty) {
      _logger.warning('$logPrefix No bootstrap peers available for lookup (neither from routing table nor config)');
      return LookupWithFollowupResult(
        peers: [],
        terminationReason: LookupTerminationReason.noMorePeers,
        errors: [],
      );
    }
    
    _logger.info('$logPrefix Using ${queryPeers.length} peers for DHT query');

    // Create QueryRunner with our configuration
    final runner = QueryRunner(
      target: target,
      queryFn: queryFn,
      stopFn: stopFn,
      initialPeers: queryPeers.map((p) => p.id).toList(),
      alpha: _config?.concurrency ?? 10, // Use DHT's concurrency setting
      timeout: _config?.queryTimeout ?? Duration(seconds: 30),
    );

    try {
      // Run the query
      final result = await runner.run();
      
      _logger.info('$logPrefix Query completed with reason: ${result.reason}. Found ${result.peerset.getClosestInStates([PeerState.queried, PeerState.heard]).length} peers');

      // Handle peer eviction for failed queries
      final unreachablePeers = result.peerset.getClosestInStates([PeerState.unreachable]);
      if (unreachablePeers.isNotEmpty) {
        _logger.info('$logPrefix Evicting ${unreachablePeers.length} unreachable peers from routing table');
        for (final peer in unreachablePeers) {
          try {
            await _routing?.removePeer(peer);
            _logger.finer('$logPrefix Evicted peer ${peer.toBase58().substring(0,6)} from routing table after failed query');
          } catch (e) {
            _logger.warning('$logPrefix Failed to evict peer ${peer.toBase58().substring(0,6)} from routing table: $e');
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
        errors: result.errors.cast<dynamic>(),
      );
    } catch (e, s) {
      _logger.severe('$logPrefix Query failed with exception: $e', e, s);
      return LookupWithFollowupResult(
        peers: [],
        terminationReason: LookupTerminationReason.cancelled,
        errors: [e],
      );
    } finally {
      // Clean up resources
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

  /// Performs a network query for a specific peer
  Future<AddrInfo?> _performNetworkQuery(PeerId target, QueryType type, RoutingOptions? options) async {
    final targetShortId = target.toBase58().substring(0, 6);
    _logger.info('Performing network query for $targetShortId (type: $type)');
    
    // Implementation depends on the query type
    switch (type) {
      case QueryType.findPeer:
        return await _performFindPeerQuery(target, options);
      case QueryType.getValue:
        // For getValue, we need to implement value lookup
        return null; // Will be implemented when we complete value operations
      case QueryType.putValue:
        // For putValue, we need to implement value storage
        return null; // Will be implemented when we complete value operations
      case QueryType.findProviders:
        // For findProviders, we need to implement provider lookup
        return null; // Will be implemented when we complete provider operations
      case QueryType.addProvider:
        // For addProvider, we need to implement provider announcement
        return null; // Will be implemented when we complete provider operations
    }
  }

  /// Performs a FIND_PEER query using distributed lookup
  Future<AddrInfo?> _performFindPeerQuery(PeerId target, RoutingOptions? options) async {
    final targetBytes = target.toBytes();
    final targetShortId = target.toBase58().substring(0, 6);
    
    final result = await runLookupWithFollowup(
      target: targetBytes,
      queryFn: (peer) async {
        final queryFnLogPrefix = '[lookup.queryFn for ${peer.toBase58().substring(0,6)}]';
        _logger.fine('$queryFnLogPrefix Sending FIND_NODE for target $targetShortId');
        
        final message = Message(
          type: MessageType.findNode,
          key: targetBytes,
        );
        
        final response = await _network?.sendMessage(peer, message);
        if (response == null) {
          throw DHTNetworkException('No response from peer', peerId: peer);
        }
        
        _logger.fine('$queryFnLogPrefix Got FIND_NODE response with ${response.closerPeers.length} closer peers');
        
        // Try adding the queried peer to routing table
        try {
          await _routing?.addPeer(peer, queryPeer: false, isReplaceable: true);
          _logger.finer('$queryFnLogPrefix Added peer ${peer.toBase58().substring(0,6)} to routing table');
        } catch (e) {
          _logger.warning('$queryFnLogPrefix Failed to add peer to routing table: $e');
        }
        
        // Check if we found the target peer in the response
        for (final p in response.closerPeers) {
          if (_bytesEqual(p.id, targetBytes)) {
            _logger.info('$queryFnLogPrefix Target peer $targetShortId found in response');
            
            // CRITICAL FIX: Store discovered addresses in peerstore!
            // This ensures addresses are available when we look them up later
            final targetPeerId = PeerId.fromBytes(p.id);
            final addresses = p.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList();
            
            if (addresses.isNotEmpty) {
              try {
                await _network?.host.peerStore.addOrUpdatePeer(targetPeerId, addrs: addresses);
                _logger.info('$queryFnLogPrefix Stored ${addresses.length} addresses for target peer $targetShortId in peerstore');
              } catch (e) {
                _logger.warning('$queryFnLogPrefix Failed to store addresses for target peer $targetShortId: $e');
              }
            }
            
            return [
              AddrInfo(targetPeerId, addresses),
            ];
          }
        }
        
        // CRITICAL FIX: Store all discovered peer addresses in peerstore
        final result = <AddrInfo>[];
        for (final p in response.closerPeers) {
          final peerId = PeerId.fromBytes(p.id);
          final addresses = p.addrs.map((addr) => MultiAddr.fromBytes(addr)).toList();
          
          // Store addresses in peerstore for future use
          if (addresses.isNotEmpty) {
            try {
              await _network?.host.peerStore.addOrUpdatePeer(peerId, addrs: addresses);
              _logger.finest('$queryFnLogPrefix Stored ${addresses.length} addresses for peer ${peerId.toBase58().substring(0,6)}');
            } catch (e) {
              _logger.warning('$queryFnLogPrefix Failed to store addresses for peer ${peerId.toBase58().substring(0,6)}: $e');
            }
          }
          
          result.add(AddrInfo(peerId, addresses));
        }
        return result;
      },
      stopFn: (peerset) {
        // Stop if we found the target peer
        for (final p in peerset.getClosestInStates([PeerState.queried, PeerState.waiting, PeerState.heard])) {
          if (_bytesEqual(p.toBytes(), targetBytes)) {
            _logger.fine('[lookup.stopFn] Target peer $targetShortId found in peerset. Stopping lookup');
            return true;
          }
        }
        
        // Stop when we've queried enough peers
        final stop = peerset.getClosestInStates([PeerState.queried]).length >= (_config?.resiliency ?? 3);
        if (stop) {
          _logger.fine('[lookup.stopFn] Queried enough peers (${_config?.resiliency ?? 3}). Stopping lookup for $targetShortId');
        }
        return stop;
      },
    );

    _logger.info('Lookup for $targetShortId completed. TerminationReason: ${result.terminationReason}. Found ${result.peers.length} peers');
    
    // Look for the target peer in the result
    for (final peerId in result.peers) {
      if (_bytesEqual(peerId.toBytes(), targetBytes)) {
        // Get the peer's addresses from the peerstore
        final peerInfo = await _network?.host.peerStore.getPeer(peerId);
        if (peerInfo != null && peerInfo.addrs.isNotEmpty) {
          return AddrInfo(peerId, peerInfo.addrs.toList());
        }
      }
    }
    
    return null;
  }

  /// Helper method to compare byte arrays
  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
  
  /// Ensures the query manager is started
  void _ensureStarted() {
    if (_closed) throw DHTClosedException();
    if (!_started) throw DHTNotStartedException();
  }
  
  @override
  String toString() => 'QueryManager()';
}

/// Query types for internal use
enum QueryType {
  findPeer,
  getValue,
  putValue,
  findProviders,
  addProvider,
}
