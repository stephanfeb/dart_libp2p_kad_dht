import 'dart:typed_data';

import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:dart_libp2p_kad_dht/src/pb/dht_codec.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// A response larger than one read: a go-libp2p peer's yamux frames are
/// small, so a GET_PROVIDERS or FIND_NODE answer arrives over several reads
/// (dart-libp2p-cce.2).
void main() {
  group('IpfsDHT with messages that span several reads', () {
    late IpfsDHT a;
    late IpfsDHT b;

    setUp(() async {
      MockStream.maxChunk = 512;
      a = await setupDHT(false);
      b = await setupDHT(false);
      await connect(a, b);
    });

    tearDown(() async {
      MockStream.maxChunk = null;
      await a.close();
      await b.close();
    });

    test('GET_PROVIDERS: a response of many chunks is read whole', () async {
      final cid = namespaceToCid('big-response');
      final providers = <PeerId>[];
      for (var i = 0; i < 30; i++) {
        final id = await PeerId.random();
        providers.add(id);
        await b.providerManager.addProvider(
          cid,
          AddrInfo(id, [
            for (var j = 0; j < 4; j++) MultiAddr('/ip4/10.0.${i % 250}.$j/tcp/${4000 + j}'),
          ]),
        );
      }
      // The response is several times the chunk size.
      final providerInfos = await b.providerManager.getProviders(cid);
      final responseSize =
          encodeMessage(Message(type: MessageType.getProviders, providerPeers: [
        for (final p in providerInfos) Peer(id: p.id.toBytes(), addrs: [for (final a in p.addrs) a.toBytes()]),
      ])).length;
      expect(responseSize, greaterThan(4 * 512));

      final found = <PeerId>{};
      await for (final info in a.findProvidersAsync(cid, 0)) {
        found.add(info.id);
      }
      expect(found, containsAll(providers));
    });
  });
}
