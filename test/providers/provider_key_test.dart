import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_kad_dht/src/providers/provider_key.dart';
import 'package:dart_libp2p_kad_dht/src/providers/provider_store.dart';
import 'package:dcid/dcid.dart';
import 'package:test/test.dart';

void main() {
  final data = utf8.encode('overmedia-token-service');
  final v1 = CID.fromData(1, 'raw', data);
  // Same content hash, different CID: version 0 (implicit dag-pb).
  final v0 = CID(CID.V0, 0x70, v1.multihash);

  group('provider keys', () {
    test('are the multihash, not the CID bytes', () {
      expect(providerKeyOf(v1), v1.multihash);
      expect(providerKeyOf(v1), isNot(v1.toBytes()));
      expect(providerKeyOf(v0), v1.multihash);
    });

    test('read from the wire as a multihash or as CIDv1 bytes', () {
      expect(providerKeyFromWire(v1.multihash), v1.multihash);
      // Dart peers before 1.5.1 sent the full CIDv1 bytes.
      expect(providerKeyFromWire(v1.toBytes()), v1.multihash);
      expect(() => providerKeyFromWire(Uint8List(0)), throwsFormatException);
      expect(() => providerKeyFromWire(Uint8List.fromList([0x12, 0x20, 1, 2])), throwsFormatException);
    });

    test('map back to a CID with the same multihash', () {
      expect(cidForProviderKey(v1.multihash).multihash, v1.multihash);
    });
  });

  test('MemoryProviderStore shares providers between CIDs of the same content', () async {
    final store = MemoryProviderStore();
    final p = await PeerId.random();

    await store.addProvider(v1, AddrInfo(p, []));
    expect((await store.getProviders(v0)).map((a) => a.id), [p]);
    expect((await store.getProviders(cidForProviderKey(v1.multihash))).map((a) => a.id), [p]);
  });
}
