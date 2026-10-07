import 'dart:convert';

import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_kad_dht/src/providers/provider_store.dart';
import 'package:dcid/dcid.dart';
import 'package:test/test.dart';

CID _cid(String s) => CID.fromData(1, 'raw', utf8.encode(s));

void main() {
  group('MemoryProviderStore', () {
    test('keeps one record per (key, provider); re-adding refreshes addresses', () async {
      final store = MemoryProviderStore();
      final p = await PeerId.random();
      final key = _cid('a');

      await store.addProvider(key, AddrInfo(p, [MultiAddr('/ip4/1.1.1.1/tcp/1')]));
      await store.addProvider(key, AddrInfo(p, [MultiAddr('/ip4/2.2.2.2/tcp/2')]));

      final providers = await store.getProviders(key);
      expect(providers, hasLength(1));
      expect(providers.single.addrs.map((a) => a.toString()), ['/ip4/2.2.2.2/tcp/2']);
      expect(store.recordCount, 1);
    });

    test('re-adding refreshes the expiry', () async {
      final store = MemoryProviderStore(
          const ProviderManagerOptions(provideValidity: Duration(milliseconds: 300)));
      final p = await PeerId.random();
      final key = _cid('a');

      await store.addProvider(key, AddrInfo(p, []));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await store.addProvider(key, AddrInfo(p, []));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // 400 ms after the first add, but only 200 ms after the refresh.
      expect(await store.getProviders(key), hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await store.getProviders(key), isEmpty);
      expect(store.recordCount, 0);
    });

    test('refuses new providers when a key is full, keeps the stored ones', () async {
      final store = MemoryProviderStore(const ProviderManagerOptions(maxProvidersPerKey: 3));
      final key = _cid('a');
      final peers = [for (var i = 0; i < 5; i++) await PeerId.random()];

      for (final p in peers) {
        await store.addProvider(key, AddrInfo(p, []));
      }
      final stored = (await store.getProviders(key)).map((a) => a.id).toList();
      expect(stored, equals(peers.take(3).toList()));

      // A stored provider can still refresh its record.
      await store.addProvider(key, AddrInfo(peers[0], [MultiAddr('/ip4/1.1.1.1/tcp/1')]));
      expect(await store.getProviders(key), hasLength(3));
    });

    test('a full key accepts new providers once records expire', () async {
      final store = MemoryProviderStore(const ProviderManagerOptions(
          maxProvidersPerKey: 2, provideValidity: Duration(milliseconds: 100)));
      final key = _cid('a');
      await store.addProvider(key, AddrInfo(await PeerId.random(), []));
      await store.addProvider(key, AddrInfo(await PeerId.random(), []));
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final late = await PeerId.random();
      await store.addProvider(key, AddrInfo(late, []));
      expect((await store.getProviders(key)).map((a) => a.id), [late]);
    });

    test('limits the number of keys per provider', () async {
      final store = MemoryProviderStore(const ProviderManagerOptions(maxKeysPerProvider: 2));
      final p = await PeerId.random();
      await store.addProvider(_cid('a'), AddrInfo(p, []));
      await store.addProvider(_cid('b'), AddrInfo(p, []));
      await store.addProvider(_cid('c'), AddrInfo(p, []));

      expect(await store.getProviders(_cid('a')), hasLength(1));
      expect(await store.getProviders(_cid('b')), hasLength(1));
      expect(await store.getProviders(_cid('c')), isEmpty);

      // Another provider is not affected.
      final q = await PeerId.random();
      await store.addProvider(_cid('c'), AddrInfo(q, []));
      expect(await store.getProviders(_cid('c')), hasLength(1));
    });

    test('limits the total number of records', () async {
      final store = MemoryProviderStore(const ProviderManagerOptions(maxProviderRecords: 3));
      for (var i = 0; i < 5; i++) {
        await store.addProvider(_cid('k$i'), AddrInfo(await PeerId.random(), []));
      }
      expect(store.recordCount, 3);
      expect(await store.getProviders(_cid('k3')), isEmpty);
    });

    test('the local peer is not limited', () async {
      final self = await PeerId.random();
      final store = MemoryProviderStore(
          const ProviderManagerOptions(maxKeysPerProvider: 1, maxProviderRecords: 1), self);
      for (var i = 0; i < 4; i++) {
        await store.addProvider(_cid('k$i'), AddrInfo(self, []));
      }
      expect(store.recordCount, 4);
    });

    test('default limits', () {
      const options = ProviderManagerOptions();
      expect(options.maxProvidersPerKey, 100);
      expect(options.maxKeysPerProvider, 1000);
      expect(options.maxProviderRecords, 100000);
    });
  });
}
