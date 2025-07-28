import 'dart:typed_data';

import 'package:dart_libp2p/core/peer/peer_id.dart';


/// ProviderSet maintains a list of providers for a key and the time they were added.
/// 
/// It is used as an intermediary data structure between what is stored in the datastore
/// and the list of providers that get passed to the consumer of a getProviders call.
class ProviderSet {
  /// The list of providers
  final List<PeerId> providers = [];

  /// A map of providers to the time they were added
  final Map<PeerId, DateTime> _providerTimes = {};

  /// Creates a new empty provider set
  ProviderSet();

  /// Adds a provider to the set with the current time
  void addProvider(PeerId provider) {
    setProviderTime(provider, DateTime.now());
  }

  /// Sets the time for a provider
  /// 
  /// If the provider is not already in the set, it will be added
  void setProviderTime(PeerId provider, DateTime time) {
    if (!_providerTimes.containsKey(provider)) {
      providers.add(provider);
    }
    
    _providerTimes[provider] = time;
  }

  /// Gets the time a provider was added
  /// 
  /// Returns null if the provider is not in the set
  DateTime? getProviderTime(PeerId provider) {
    return _providerTimes[provider];
  }

  /// Checks if the set contains a provider
  bool containsProvider(PeerId provider) {
    return _providerTimes.containsKey(provider);
  }

  /// Removes a provider from the set
  /// 
  /// Returns true if the provider was removed, false if it wasn't in the set
  bool removeProvider(PeerId provider) {
    if (_providerTimes.remove(provider) != null) {
      providers.remove(provider);
      return true;
    }
    return false;
  }

  /// Gets the number of providers in the set
  int get size => providers.length;

  /// Checks if the set is empty
  bool get isEmpty => providers.isEmpty;

  /// Gets all providers in the set
  List<PeerId> getAllProviders() {
    return List.unmodifiable(providers);
  }

  /// Removes providers that were added before the given time
  /// 
  /// Returns the number of providers removed
  int removeProvidersAddedBefore(DateTime time) {
    final toRemove = <PeerId>[];
    
    for (final entry in _providerTimes.entries) {
      if (entry.value.isBefore(time)) {
        toRemove.add(entry.key);
      }
    }
    
    for (final provider in toRemove) {
      _providerTimes.remove(provider);
      providers.remove(provider);
    }
    
    return toRemove.length;
  }
}