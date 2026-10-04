import 'dart:typed_data';

import 'package:dcid/dcid.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/routing/routing.dart';
import 'package:logging/logging.dart';

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

  /// Creates new provider manager options
  const ProviderManagerOptions({
    this.cleanupInterval = const Duration(hours: 1),
    this.provideValidity = const Duration(hours: 48),
    this.providerAddrTTL = const Duration(hours: 24),
    this.cacheSize = 256,
  });
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
class MemoryProviderStore implements ProviderStore {
  final Map<String, List<ProviderRecord>> _providers = {};
  final ProviderManagerOptions _options;
  bool _closed = false;

  /// Creates a new memory provider store with the given options
  MemoryProviderStore([this._options = const ProviderManagerOptions()]);

  @override
  Future<void> addProvider(CID key, AddrInfo provider) async {
    if (_closed) {
      throw StateError('Provider store is closed');
    }

    final keyStr = _keyToString(key.toBytes());
    
    // 🔍 DIAGNOSTIC LOGGING
    _log.finest('🔍 [ProviderStore.addProvider] ═══════════════════════════════');
    _log.finest('🔍 CID (toString): ${key.toString()}');
    _log.finest('🔍 CID (bytes hex): ${key.toBytes().map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
    _log.finest('🔍 Key string length: ${keyStr.length}');
    _log.finest('🔍 Provider Peer ID: ${provider.id.toBase58()}');
    _log.finest('🔍 Provider Addresses: ${provider.addrs.map((a) => a.toString()).join(", ")}');
    
    final expiration = DateTime.now().add(_options.provideValidity);
    final record = ProviderRecord(
      provider: provider,
      expiration: expiration,
    );

    _providers.putIfAbsent(keyStr, () => []).add(record);
    _cleanupExpired(keyStr);
    
    _log.finest('🔍 Total providers for this CID: ${_providers[keyStr]!.length}');
    _log.finest('🔍 All providers for this CID:');
    for (final r in _providers[keyStr]!) {
      _log.finest('🔍   - ${r.provider.id.toBase58()}');
    }
    _log.finest('🔍 ═══════════════════════════════════════════════════════════');
  }

  @override
  Future<List<AddrInfo>> getProviders(CID key) async {
    if (_closed) {
      throw StateError('Provider store is closed');
    }

    final keyStr = _keyToString(key.toBytes());
    
    // 🔍 DIAGNOSTIC LOGGING
    _log.finest('🔍 [ProviderStore.getProviders] ═══════════════════════════════');
    _log.finest('🔍 CID (toString): ${key.toString()}');
    _log.finest('🔍 CID (bytes hex): ${key.toBytes().map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
    _log.finest('🔍 Key string length: ${keyStr.length}');
    _log.finest('🔍 Looking up key in store...');
    
    _cleanupExpired(keyStr);

    final records = _providers[keyStr] ?? [];
    
    _log.finest('🔍 Found ${records.length} provider(s) for this CID:');
    for (final record in records) {
      _log.finest('🔍   - ${record.provider.id.toBase58()} (expires: ${record.expiration})');
    }
    _log.finest('🔍 ═══════════════════════════════════════════════════════════');
    
    final result = records.map((record) => record.provider).toList();
    return result;
  }

  @override
  Future<void> close() async {
    _closed = true;
    _providers.clear();
  }

  /// Removes expired provider records for the given key
  void _cleanupExpired(String key) {
    final records = _providers[key];
    if (records == null) return;

    final validRecords = records.where((record) => !record.isExpired()).toList();
    if (validRecords.isEmpty) {
      _providers.remove(key);
    } else {
      _providers[key] = validRecords;
    }
  }

  /// Converts a key to a string for use as a map key
  String _keyToString(Uint8List key) {
    return String.fromCharCodes(key);
  }
}
