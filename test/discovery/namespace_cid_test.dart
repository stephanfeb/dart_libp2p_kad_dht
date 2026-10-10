import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:test/test.dart';

void main() {
  group('namespaceToCid', () {
    // From go-libp2p's nsToCid: cid.NewCidV1(cid.Raw, mh.Sum(ns, SHA2_256)).
    const goKeys = {
      'teranode/bitcoin/1.0.0/testnet-block':
          'bafkreihko5grryepfzapyh5wu47q2bzytva6t2lqvzpnh5kglcckpavk7m',
      'my-app': 'bafkreicmtj24zjyx563izblpe25ieudtp5congangmmtzfh2bohjzv3brq',
      'test': 'bafkreie7q3iidccmpvszul7kudcvvuavuo7u6gzlbobczuk5nqk3b4akba',
    };

    goKeys.forEach((ns, key) {
      test('"$ns" gives the key go-libp2p gives', () {
        expect(namespaceToCid(ns).toString(), key);
      });
    });

    test('the provider key is the sha2-256 multihash', () {
      final multihash = namespaceToCid('my-app').multihash;
      expect(multihash.sublist(0, 2), [0x12, 0x20]);
      expect(multihash.length, 34);
    });
  });
}
