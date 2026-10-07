import 'dart:typed_data';

import 'package:dcid/dcid.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/routing/routing.dart';
import 'package:logging/logging.dart';

import '../internal/util.dart' show truncateForLog;

final _log = Logger('ProviderStore');

/// ProviderStore represents a store that associates peers and their addresses to keys.
abstract class ProviderStore {
  /// Adds a provider for the given key
  /// 
  /// The provider will be associated with the key and can be retrieved later
  /// using [getProviders].
  Future<void> addProvider(CID key, AddrInfo provider);

  /// Gets providers for the given key
  /// 
  /// Returns a list of providers that have been associated with the key
  Future<List<AddrInfo>> getProviders(CID key);

  /// Closes the provider store and releases any resources
  Future<void> close();
}

/// Options for configuring a provider manager
class ProviderManagerOptions {
  /// The time between garbage collection runs
  final Duration cleanupInterval;

  /// The time that a provider record should last before expiring
  final Duration provideValidity;

  /// The TTL to keep the multi addresses of provider peers around
  final Duration providerAddrTTL;

  /// The size of the LRU cache for provider records
  final int cacheSize;

  /// The maximum number of providers that [MemoryProviderStore] keeps for
  /// one key.
  ///
  /// When a key is full, expired records are removed first. If the key is
  /// still full, a new provider is refused; the providers already stored
  /// stay, and they can refresh their records. Refusing (and not evicting the
  /// oldest record) prevents a peer that makes many peer IDs from pushing
  /// the honest providers out of a key.
  final int maxProvidersPerKey;

  /// The maximum number of keys that one provider (the peer that sent the
  /// `ADD_PROVIDER` message) can have in [MemoryProviderStore]. Records for
  /// more keys are refused until some of its records expire.
  final int maxKeysPerProvider;

  /// The maximum number of provider records in [MemoryProviderStore] for all
  /// keys together. When the store is full, expired records are removed
  /// first; if it is still full, new records are refused.
  final int maxProviderRecords;

  /// Creates new provider manager options
  const ProviderManagerOptions({
    this.cleanupInterval = const Duration(hours: 1),
    this.provideValidity = const Duration(hours: 48),
    this.providerAddrTTL = const Duration(hours: 24),
    this.cacheSize = 256,
    this.maxProvidersPerKey = defaultMaxProvidersPerKey,
    this.maxKeysPerProvider = defaultMaxKeysPerProvider,
    this.maxProviderRecords = defaultMaxProviderRecords,
  });

  /// Default for [maxProvidersPerKey].
  static const int defaultMaxProvidersPerKey = 100;

  /// Default for [maxKeysPerProvider].
  static const int defaultMaxKeysPerProvider = 1000;

  /// Default for [maxProviderRecords].
  static const int defaultMaxProviderRecords = 100000;
}

/// A provider record with an expiration time
class ProviderRecord {
  /// The provider's address information
  final AddrInfo provider;

  /// When this record expires
  final DateTime expiration;

  /// Creates a new provider record
  ProviderRecord({
    required this.provider,
    required this.expiration,
  });

  /// Checks if this record has expired
  bool isExpired() {
    return DateTime.now().isAfter(expiration);
  }
}

/// A basic in-memory implementation of ProviderStore
///
/// The store keeps one record for each (key, provider) pair. Adding a
/// provider that is already stored for a key refreshes its expiry and
/// replaces its addresses. The store is bounded: see
/// [ProviderManagerOptions.maxProvidersPerKey],
/// [ProviderManagerOptions.maxKeysPerProvider] and
/// [ProviderManagerOptions.maxProviderRecords]. Records for [localPeerId]
/// (the records this node provides itself) are not limited.
class MemoryProviderStore implements ProviderStore {
  /// key -> provider ID (base58) -> record, in insertion order.
  final Map<String, Map<String, ProviderRecord>> _providers = {};

  /// provider ID (base58) -> keys that have a record for it.
  final Map<String, Set<String>> _keysByProvider = {};

  int _recordCount = 0;

  final ProviderManagerOptions _options;
  bool _closed = false;

  /// The local peer. Its own provider records are not limited by the caps.
  ///
  /// The DHT sets this when it is created with this store, if it is not set.
  PeerId? localPeerId;

  /// Creates a new memory provider store with the given options
  MemoryProviderStore([this._options = const ProviderManagerOptions(), this.localPeerId]);

  /// The number of provider records in the store, including expired records
  /// that were not removed yet.
  int get recordCount => _recordCount;

  @override
  Future<void> addProvider(CID key, AddrInfo provider) async {
    if (_closed) {
      throw StateError('Provider store is closed');
    }

    final keyStr = _keyToString(key.toBytes());
    final providerStr = provider.id.toBase58();
    final isLocal = localPeerId != null && provider.id == localPeerId;
    final expiration = DateTime.now().add(_options.provideValidity);
    final record = ProviderRecord(provider: provider, expiration: expiration);

    _cleanupExpired(keyStr);

    final forKey = _providers[keyStr];
    if (forKey != null && forKey.containsKey(providerStr)) {
      // Same (key, provider): refresh expiry and addresses.
      forKey[providerStr] = record;
      _log.finest('Refreshed provider ${truncateForLog(providerStr, 12)} for key');
      return;
    }

    if (!isLocal) {
      if ((forKey?.length ?? 0) >= _options.maxProvidersPerKey) {
        _log.fine('Refused provider ${truncateForLog(providerStr, 12)}: key has '
            '${forKey!.length} providers (max ${_options.maxProvidersPerKey})');
        return;
      }
      final providerKeys = _keysByProvider[providerStr];
      if (providerKeys != null && providerKeys.length >= _options.maxKeysPerProvider) {
        _cleanupProvider(providerStr);
        if ((_keysByProvider[providerStr]?.length ?? 0) >= _options.maxKeysPerProvider) {
          _log.fine('Refused provider ${truncateForLog(providerStr, 12)}: it provides '
              '${_keysByProvider[providerStr]!.length} keys (max ${_options.maxKeysPerProvider})');
          return;
        }
      }
      if (_recordCount >= _options.maxProviderRecords) {
        _cleanupAll();
        if (_recordCount >= _options.maxProviderRecords) {
          _log.fine('Refused provider ${truncateForLog(providerStr, 12)}: store holds '
              '$_recordCount records (max ${_options.maxProviderRecords})');
          return;
        }
      }
    }

    _providers.putIfAbsent(keyStr, () => <String, ProviderRecord>{})[providerStr] = record;
    _keysByProvider.putIfAbsent(providerStr, () => <String>{}).add(keyStr);
    _recordCount++;
    _log.finest('Stored provider ${truncateForLog(providerStr, 12)}; '
        '${_providers[keyStr]!.length} provider(s) for this key');
  }

  @override
  Future<List<AddrInfo>> getProviders(CID key) async {
    if (_closed) {
      throw StateError('Provider store is closed');
    }

    final keyStr = _keyToString(key.toBytes());
    _cleanupExpired(keyStr);

    final records = _providers[keyStr];
    if (records == null) return [];
    return records.values.map((record) => record.provider).toList();
  }

  @override
  Future<void> close() async {
    _closed = true;
    _providers.clear();
    _keysByProvider.clear();
    _recordCount = 0;
  }

  void _removeRecord(String key, String provider) {
    final forKey = _providers[key];
    if (forKey == null || forKey.remove(provider) == null) return;
    _recordCount--;
    if (forKey.isEmpty) _providers.remove(key);
    final keys = _keysByProvider[provider];
    if (keys != null) {
      keys.remove(key);
      if (keys.isEmpty) _keysByProvider.remove(provider);
    }
  }

  /// Removes expired provider records for the given key
  void _cleanupExpired(String key) {
    final records = _providers[key];
    if (records == null) return;
    final expired = records.entries
        .where((e) => e.value.isExpired())
        .map((e) => e.key)
        .toList();
    for (final provider in expired) {
      _removeRecord(key, provider);
    }
  }

  /// Removes the expired records of one provider.
  void _cleanupProvider(String provider) {
    final keys = _keysByProvider[provider];
    if (keys == null) return;
    for (final key in keys.toList()) {
      final record = _providers[key]?[provider];
      if (record != null && record.isExpired()) {
        _removeRecord(key, provider);
      }
    }
  }

  /// Removes all expired records.
  void _cleanupAll() {
    for (final key in _providers.keys.toList()) {
      _cleanupExpired(key);
    }
  }

  /// Converts a key to a string for use as a map key
  String _keyToString(Uint8List key) {
    return String.fromCharCodes(key);
  }
}
