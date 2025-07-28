import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto; // For sha256 hashing
import 'package:dcid/dcid.dart';
import 'package:dcid/src/codecs.dart'; // Import for codecNameToCode
import 'package:dart_multihash/dart_multihash.dart' as mh; // Alias for clarity
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peerstore.dart';
import 'package:dart_libp2p/core/multiaddr.dart'; // Import official MultiAddr
import 'package:dart_libp2p/p2p/discovery/peer_info.dart'; // Import official PeerInfo
import 'package:dart_libp2p/core/routing/routing.dart';
import 'package:dart_libp2p_kad_dht/src/providers/provider_manager.dart';
import 'package:dart_libp2p_kad_dht/src/providers/provider_store.dart';
import 'package:test/test.dart';

// Using MockPeerstoreImpl from test_utils.dart requires this import.
// However, test_utils.dart has its own main and other test-specific setups
// that might conflict if imported directly into another test file.
// For now, let's define a minimal mock peerstore here or use a real MemoryPeerStore if available and simple.
// Re-checking test_utils.dart, MockPeerstoreImpl is a class, so it can be imported.
// Let's assume test_utils.dart can be imported for MockPeerstoreImpl.
// If not, a simple MemoryPeerstore from dart_libp2p itself would be better.
// The core library dart_libp2p should have a MemoryPeerstore.
// Let's try to use `MemoryPeerstore` from `package:dart_libp2p/p2p/peerstore/memory.dart` if it exists.
// For now, to simplify, I'll define a very basic one if not easily importable.

// Helper to create PeerId from string.
// Using PeerId.random() as direct string to valid PeerId conversion is non-trivial
// and not the focus of these tests. Random IDs are sufficient.
Future<PeerId> createRandomPeerId() async {
  return PeerId.random();
}

// Helper to create CID from string (placeholder for actual hashing)
CID cidFromString(String s) {
  // This is a placeholder. Real CIDs involve hashing and multihash encoding.
  // For provider manager tests, the exact content of CID bytes might not matter
  // as much as their uniqueness and consistent handling.
  // Updated to generate valid CIDv1 for testing, based on provided examples.
  final inputData = Uint8List.fromList(utf8.encode(s));

  // 1. Hash the input data (e.g., using SHA2-256)
  final digest = crypto.sha256.convert(inputData).bytes;

  // 2. Encode the digest into a multihash using dart_multihash
  // The 'sha2-256' string is the multihash name for SHA2-256.
  final mh.MultihashInfo multihashInfo = mh.Multihash.encode('sha2-256', Uint8List.fromList(digest));
  final Uint8List multihashBytes = multihashInfo.toBytes();

  // 3. Create a CIDv1 using the dag-pb codec and the multihash bytes
  // CID.V1 is the version.
  // codecNameToCode['dag-pb']! gets the integer code for 'dag-pb'.
  return CID(CID.V1, codecNameToCode['dag-pb']!, multihashBytes);
}

// Using the official MultiAddr and PeerInfo, so SimpleMemoryPeerstore needs to align.
class SimpleMemoryPeerstore implements Peerstore {
  final Map<PeerId, AddrInfo> _store = {};
  final Map<PeerId, Map<String, dynamic>> _metadata = {};
  // For storing protocols, as PeerInfo requires it.
  final Map<PeerId, Set<String>> _protocols = {};


  @override
  Future<void> addOrUpdatePeer(PeerId peerId, { List<MultiAddr>? addrs, List<String>? protocols, Map<String, dynamic>? metadata }){
    final existingInfo = _store[peerId];
    final existingProtocols = _protocols[peerId] ?? <String>{};
    
    Set<MultiAddr> newAddrs;
    if (existingInfo != null) {
      newAddrs = {...existingInfo.addrs, ...(addrs?.toList() ?? [])};
    } else {
      newAddrs = {...(addrs?.toList() ?? [])};
    }
    _store[peerId] = AddrInfo(peerId, newAddrs.toList());

    if (protocols != null) {
      existingProtocols.addAll(protocols);
    }
    _protocols[peerId] = existingProtocols;

    if (metadata != null) {
      _metadata.putIfAbsent(peerId, () => {}).addAll(metadata);
    }

    return Future.delayed(Duration(milliseconds: 1));
  }

  @override
  Future<PeerInfo?> getPeer(PeerId peerId) async {
    final addrInfo = _store[peerId];
    if (addrInfo == null) return null;
    
    return PeerInfo(
      peerId: addrInfo.id, 
      addrs: addrInfo.addrs.toSet(), 
      protocols: _protocols[peerId] ?? <String>{}, 
      metadata: _metadata[peerId] ?? {}
    );
  }

  @override
  Future<AddrInfo> peerInfo(PeerId id) async {
     final info = _store[id];
     if (info == null) {
       throw Exception('Peer not found in SimpleMemoryPeerstore: $id');
     }
     return info;
  }
  
  // Implement other Peerstore methods as needed or leave as unimplemented
  @override
  AddrBook get addrBook => throw UnimplementedError();
  @override
  Future<void> close() async {}
  @override
  KeyBook get keyBook => throw UnimplementedError();
  @override
  Metrics get metrics => throw UnimplementedError();
  @override
  PeerMetadata get peerMetadata => throw UnimplementedError();
  @override
  Future<List<PeerId>> peers() async => _store.keys.toList();
  @override
  ProtoBook get protoBook => throw UnimplementedError();
  @override
  Future<void> removePeer(PeerId id) async {
    _store.remove(id);
    _metadata.remove(id);
    _protocols.remove(id);
  }
}


void main() {
  group('ProviderManager Tests (Ported from Go)', () {
    late ProviderManager providerManager;
    late PeerId localPeer;
    late Peerstore peerstore;
    late ProviderStore store; // This will be a MemoryProviderStore

    setUp(() async {
      localPeer = await createRandomPeerId(); // Use the new async helper
      // Using the self-defined SimpleMemoryPeerstore for now.
      // Ideally, use dart_libp2p's own MemoryPeerstore or test_utils.MockPeerstoreImpl
      peerstore = SimpleMemoryPeerstore(); 
      store = MemoryProviderStore(); // From lib/src/providers/provider_store.dart

      providerManager = ProviderManager(
        localPeerId: localPeer,
        peerStore: peerstore,
        store: store,
        cacheSize: 10, // Keep cache size small for easier testing of cache logic
      );
    });

    tearDown(() async {
      await providerManager.close();
    });

    test('TestProviderManager basic add and get', () async {
      final keyA = cidFromString('testkeyA');
      final providerPeer1 = await createRandomPeerId();
      // Use official MultiAddr constructor
      final providerAddrInfo1 = AddrInfo(providerPeer1, [MultiAddr('/ip4/127.0.0.1/tcp/1001')]);

      // Add provider
      await providerManager.addProvider(keyA, providerAddrInfo1);

      // Get providers - should not be from an empty cache initially, but manager handles this.
      var retrievedProviders = await providerManager.getProviders(keyA);
      expect(retrievedProviders, isNotEmpty, reason: 'Could not retrieve provider.');
      expect(retrievedProviders.length, 1, reason: 'Expected 1 provider.');
      expect(retrievedProviders[0].id, providerPeer1);
      expect(retrievedProviders[0].addrs, providerAddrInfo1.addrs);

      // Get providers again - should be from cache if cache is working
      retrievedProviders = await providerManager.getProviders(keyA);
      expect(retrievedProviders, isNotEmpty, reason: 'Could not retrieve provider from cache.');
      expect(retrievedProviders.length, 1, reason: 'Expected 1 provider from cache.');
      expect(retrievedProviders[0].id, providerPeer1);

      // Add more providers for the same key
      final providerPeer2 = await createRandomPeerId();
      final providerAddrInfo2 = AddrInfo(providerPeer2, [MultiAddr('/ip4/127.0.0.1/tcp/1002')]);
      await providerManager.addProvider(keyA, providerAddrInfo2);

      final providerPeer3 = await createRandomPeerId();
      final providerAddrInfo3 = AddrInfo(providerPeer3, [MultiAddr('/ip4/127.0.0.1/tcp/1003')]);
      await providerManager.addProvider(keyA, providerAddrInfo3);
      
      // Get providers again
      retrievedProviders = await providerManager.getProviders(keyA);
      expect(retrievedProviders.length, 3, reason: 'Should have got 3 providers, got ${retrievedProviders.length}');
      
      final retrievedPeerIds = retrievedProviders.map((p) => p.id).toList();
      expect(retrievedPeerIds, contains(providerPeer1));
      expect(retrievedPeerIds, contains(providerPeer2));
      expect(retrievedPeerIds, contains(providerPeer3));

      // Verify cache state (ProviderManager's cache is internal, but we can infer)
      // The Dart ProviderManager has an LruCache. We can't directly inspect it here without modifying the class
      // or using a test-specific subclass. We infer its state from behavior.
      // The Go test had TODOs for cache verification.
      // If ProviderManager exposed its cache, we could do:
      // expect(providerManager.cache.containsKey(_keyToString(keyA)), isTrue);
    });

    // TestProvidersDatastore in Go tests LRU cache behavior more explicitly.
    // The Dart ProviderManager constructor takes a cacheSize.
    test('TestProvidersDatastore (LRU Cache Behavior)', () async {
      // ProviderManager already initialized with cacheSize: 10 in setUp.
      final providerPeer = await createRandomPeerId();
      final providerAddrInfo = AddrInfo(providerPeer, [MultiAddr('/ip4/1.2.3.4/tcp/1000')]);

      List<CID> cids = [];
      for (int i = 0; i < 15; i++) { // More than cache size 10
        final key = cidFromString('lrukey-$i');
        cids.add(key);
        await providerManager.addProvider(key, providerAddrInfo);
      }

      // Access them all. Some should come from store, some from cache.
      for (final cidKey in cids) {
        final providers = await providerManager.getProviders(cidKey);
        expect(providers, isNotEmpty, reason: 'Could not retrieve provider for $cidKey');
        expect(providers.length, 1);
        expect(providers[0].id, providerPeer);
      }

      // To more directly test LRU, we'd need to access in a specific order
      // and know which ones were evicted.
      // For example, access the first 5 (cids[0] to cids[4]).
      // Then add 10 new ones (cids[5] to cids[14]).
      // The first 5 should now be evicted if accessed last among the initial fill.
      // The current ProviderManager cache is internal, so direct verification is hard.
      // The test above ensures functionality even with cache misses.
    });

    // TestUponCacheMissProvidersAreReadFromDatastore
     test('TestUponCacheMissProvidersAreReadFromDatastore', () async {
      // Set up a new ProviderManager with a very small cache for this test
      final local = await createRandomPeerId();
      final ps = SimpleMemoryPeerstore();
      final memStore = MemoryProviderStore();
      final pm = ProviderManager(
        localPeerId: local,
        peerStore: ps,
        store: memStore,
        cacheSize: 1, // Cache size of 1
      );

      final p1 = await createRandomPeerId();
      final p2 = await createRandomPeerId();
      final addrInfo1 = AddrInfo(p1, [MultiAddr('/ip4/127.0.0.1/tcp/2001')]);
      final addrInfo2 = AddrInfo(p2, [MultiAddr('/ip4/127.0.0.1/tcp/2002')]);

      final h1 = cidFromString('hash1-cache-miss');
      final h2 = cidFromString('hash2-cache-miss');

      // Add provider for h1 (p1) - this will be in cache
      await pm.addProvider(h1, addrInfo1);
      var h1Provs = await pm.getProviders(h1); // Ensure it's cached
      expect(h1Provs.length, 1);
      expect(h1Provs[0].id, p1);

      // Add provider for h2 (p1) - this will evict h1 from cache (cache size is 1)
      await pm.addProvider(h2, addrInfo1); 
      var h2Provs = await pm.getProviders(h2); // Ensure h2 is cached
      expect(h2Provs.length, 1);
      expect(h2Provs[0].id, p1);

      // Now, h1's provider info should be in the datastore (MemoryProviderStore) but not in pm's LruCache.
      // Add another provider (p2) for h1. This should trigger a read from datastore for h1's existing providers.
      await pm.addProvider(h1, addrInfo2);

      h1Provs = await pm.getProviders(h1);
      expect(h1Provs.length, 2, reason: 'Expected h1 to be provided by 2 peers, got ${h1Provs.length}');
      final h1PeerIds = h1Provs.map((p) => p.id).toList();
      expect(h1PeerIds, contains(p1));
      expect(h1PeerIds, contains(p2));

      await pm.close();
    });

    // TestWriteUpdatesCache
    test('TestWriteUpdatesCache', () async {
      final p1 = await createRandomPeerId();
      final p2 = await createRandomPeerId();
      final addrInfo1 = AddrInfo(p1, [MultiAddr('/ip4/127.0.0.1/tcp/3001')]);
      final addrInfo2 = AddrInfo(p2, [MultiAddr('/ip4/127.0.0.1/tcp/3002')]);
      
      final h1 = cidFromString('hash1-write-cache');

      // Add provider for h1 (p1)
      await providerManager.addProvider(h1, addrInfo1);
      
      // Force h1 into the cache by getting it
      var h1Provs = await providerManager.getProviders(h1);
      expect(h1Provs.length, 1);
      expect(h1Provs[0].id, p1);
      // At this point, h1 and its provider p1 are in the cache.

      // Add a second provider (p2) for h1.
      // The ProviderManager's addProvider logic should update the cached entry if it exists.
      await providerManager.addProvider(h1, addrInfo2);

      // Get providers for h1 again. Should reflect both p1 and p2.
      h1Provs = await providerManager.getProviders(h1);
      expect(h1Provs.length, 2, reason: 'Expected h1 to be provided by 2 peers after cache update, got ${h1Provs.length}');
      final h1PeerIds = h1Provs.map((p) => p.id).toList();
      expect(h1PeerIds, contains(p1));
      expect(h1PeerIds, contains(p2));
    });

    // Note: TestProvidersSerialization and TestProvidesExpire from Go
    // TestProvidersSerialization tests writeProviderEntry and loadProviderSet which are internal to Go's provider persistence.
    // The Dart MemoryProviderStore has its own serialization/persistence logic (in-memory).
    // A direct port of TestProvidersSerialization might not be meaningful unless we test MemoryProviderStore internals,
    // or if there was a datastore-backed ProviderStore whose serialization we wanted to verify.
    // For now, we assume MemoryProviderStore works as intended.

    // TestProvidesExpire tests expiration logic. MemoryProviderStore has expiration logic.
    // ProviderManager itself doesn't seem to directly manage expirations, it delegates to the underlying store
    // and its own cache cleanup is mostly about LRU and periodic full cache clear.
    // We can test MemoryProviderStore's expiration if needed in a separate test file for MemoryProviderStore.
    // The ProviderManager's _cleanup method just clears the cache.
  });
}

// Removed local MultiAddr and PeerInfo definitions as we are importing official ones.
