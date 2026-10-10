import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:dart_libp2p_kad_dht/src/pb/dht_codec.dart';
import 'package:dart_libp2p_kad_dht/src/pb/dht_message_reader.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// A lookup stores the addresses of the peers each answer names, as
/// go-libp2p-kad-dht's maybeAddAddrs: the next hop dials them, and
/// findPeer reads them. Seen against Teranode: a peer learnt only through
/// Teranode had no address ("No addresses found").
void main() {
  test('findPeer returns the addresses a middle peer gave for the target', () async {
    final querierHost = await createMockHost();
    final middle = await createMockHost() as MockHost;
    final targetId = await PeerId.random();
    final targetAddr = MultiAddr('/ip4/8.8.4.4/tcp/4001');

    final querier = IpfsDHT(
      host: querierHost,
      options: DHTOptions(
        mode: DHTMode.server,
        bootstrapPeers: [for (final a in middle.addrs) a.encapsulate('p2p', middle.id.toBase58())],
      ),
      providerStore: MemoryProviderStore(),
    );
    addTearDown(() async {
      await querier.close();
      await querierHost.close();
      await middle.close();
    });
    await querier.start();
    await querierHost.peerStore.addrBook.addAddrs(middle.id, middle.addrs, const Duration(hours: 1));

    // The middle peer answers FIND_NODE with the target and its address.
    middle.setStreamHandler(AminoConstants.protocolID, (P2PStream stream, PeerId from) async {
      final request = await DhtMessageReader(stream).next();
      expect(request?.type, MessageType.findNode);
      await stream.write(encodeMessage(Message(
        type: MessageType.findNode,
        closerPeers: [Peer(id: targetId.toBytes(), addrs: [targetAddr.toBytes()])],
      )));
      await stream.close();
    });
    expect(await querierHost.peerStore.addrBook.addrs(targetId), isEmpty);

    final found = await querier.findPeer(targetId);

    expect(found, isNotNull);
    expect(found!.addrs.map((a) => a.toString()), contains(targetAddr.toString()));
  });
}
