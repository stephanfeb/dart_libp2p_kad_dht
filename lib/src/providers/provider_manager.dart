import 'dart:async';
import 'dart:convert';

import 'package:dcid/dcid.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peerstore.dart';
import 'package:lru/lru.dart';

import 'provider_set.dart';
import 'provider_store.dart';

/// ProviderManager adds and retrieves providers from a datastore,
/// caching them in between for efficiency.
class ProviderManager implements ProviderStore {
  /// The ID of the local peer
  final PeerId _localPeerId;

  /// The peer store for storing peer addresses
  final Peerstore _peerStore;

  /// The underlying provider store for persistence
  final ProviderStore _store;

  /// Cache of provider sets for keys
  final LruCache<String, ProviderSet> _cache;

  /// Options for the provider manager
  final ProviderManagerOptions _options;

  /// Timer for periodic cleanup
  Timer? _cleanupTimer;

  /// Whether the manager has been closed
  bool _closed = false;

  /// Creates a new provider manager
  ProviderManager({
    required PeerId localPeerId,
    required Peerstore peerStore,
    required ProviderStore store,
    ProviderManagerOptions? options,
    int? cacheSize,
  })  : _localPeerId = localPeerId,
        _peerStore = peerStore,
        _store = store,
        _options = options ?? const ProviderManagerOptions(),
        _cache = LruCache<String, ProviderSet>(cacheSize ?? 256) {
    // Start periodic cleanup
    _cleanupTimer = Timer.periodic(
      _options.cleanupInterval,
      (_) => _cleanup(),
    );
  }

  @override
  Future<void> addProvider(CID key, AddrInfo provider) async {
    if (_closed) {
      throw StateError('Provider manager is closed');
    }

    // Store the provider's addresses in the peer store
    _peerStore.addOrUpdatePeer(provider.id, addrs: provider.addrs );

    // Update the cache if the key is cached
    final keyStr = _keyToString(key);
    final cachedSet = _cache[keyStr];
    if (cachedSet != null) {
      cachedSet.addProvider(provider.id);
    }

    // Store in the underlying provider store
    await _store.addProvider(key, provider);
  }

  @override
  Future<List<AddrInfo>> getProviders(CID key) async {
    if (_closed) {
      throw StateError('Provider manager is closed');
    }

    final keyStr = _keyToString(key);
    
    // Try to get from cache first
    ProviderSet? providerSet = _cache[keyStr];
    
    // If not in cache, load from store
    if (providerSet == null) {
      final providers = await _store.getProviders(key);
      
      // Create a new provider set and add all providers
      providerSet = ProviderSet();
      for (final provider in providers) {
        providerSet.addProvider(provider.id);
      }
      
      // Add to cache if not empty
      if (providerSet.size > 0) {
        _cache[keyStr] = providerSet;
      }
    }
    
    // Convert provider IDs to AddrInfo objects
    final result = <AddrInfo>[];
    for (final providerId in providerSet.providers) {
      if (providerId == _localPeerId) {
        // For the local peer, ensure it's included.
        // Try to get its up-to-date addresses from the peerstore.
        final localPeerInfo = await _peerStore.getPeer(_localPeerId);
        // If peerstore has addresses, use them; otherwise, use an empty list,
        // as the test expects a provider entry even if addresses are empty.
        result.add(AddrInfo(_localPeerId, localPeerInfo?.addrs.toList() ?? []));
      } else {
        // For remote peers
        final remotePeerInfo = await _peerStore.getPeer(providerId);
        // Add remote peer if found in peerstore and has a non-null address list (the list can be empty).
        if (remotePeerInfo?.addrs != null) { 
          // remotePeerInfo is guaranteed not null here if remotePeerInfo.addrs is not null.
          result.add(AddrInfo(providerId, remotePeerInfo!.addrs.toList()));
        }
        // If remotePeerInfo is null or remotePeerInfo.addrs is null, the remote provider is omitted.
      }
    }
    
    return result;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    
    _closed = true;
    _cleanupTimer?.cancel();
    _cache.clear();
    await _store.close();
  }

  /// Performs cleanup of expired provider records
  void _cleanup() {
    if (_closed) return;
    
    // Clear the cache - it's faster than checking each entry
    _cache.clear();
    
    // The underlying store should handle its own cleanup
  }

  /// Converts a key to a string for use as a cache key
  String _keyToString(CID key) {

    return base64Encode(key.toBytes());
  }
}
