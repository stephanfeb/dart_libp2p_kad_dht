import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/interfaces.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:dart_libp2p_kad_dht/src/amino/defaults.dart'; // Added import
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  group('DHT External Tests', () {
    test('InvalidRemotePeers - Peers not responding to DHT requests are not added to routing table', () async {
      // Create a mock network with 5 hosts
      final mockNet = await createMockNetwork(5);
      final hosts = mockNet.hosts;
      
      // Create a DHT on the first host
      final dht = await createDHT(hosts[0], [
        'testPrefix',
        'disableAutoRefresh',
        'modeServer'
      ]);

      // Set up a handler on the second host that hangs on every request
      for (final proto in [AminoConstants.protocolID]) { // Replaced dht.serverProtocols
        hosts[1].setStreamHandler(proto, (P2PStream stream, PeerId peerId) async {
          // Just hang and never respond
          await Future.delayed(Duration(days: 1));
        });
      }
      
      // Connect all hosts except to themselves
      await mockNet.connectAllButSelf();
      
      // Wait a bit for potential routing table updates
      await Future.delayed(Duration(milliseconds: 100));
      
      // The second host shouldn't be added to the routing table because it's not responding
      expect(await dht.routingTable.size(), equals(0));
      
      // Cleanup
      await dht.close();
      await mockNet.close();
    });
  });
}
