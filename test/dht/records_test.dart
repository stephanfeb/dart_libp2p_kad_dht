import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/routing/options.dart';
import 'package:dart_libp2p/core/routing/routing.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  group('DHT Records Tests', () {
    /*test('PubkeyPeerstore - GetPublicKey retrieves key from peerstore', () async {
      final dht = await setupDHT(false);
      
      // Generate a random identity
      final keyPair = await generateEd25519KeyPair();
      final id = await PeerId.fromPublicKey(keyPair.publicKey);
      
      // Add the public key to the peerstore
      dht.host().peerStore.keyBook.addPubKey(id, keyPair.publicKey);
      
      // Retrieve the public key
      final retrievedKey = await dht.getPublicKey(id);
      
      // The keys should match
      expect(retrievedKey.raw, equals(keyPair.publicKey.raw));
      
      // Cleanup
      await dht.close();
    });
    
    test('PubkeyDirectFromNode - GetPublicKey retrieves key directly from node', () async {
      final dhtA = await setupDHT(false);
      final dhtB = await setupDHT(false);
      
      // Connect the DHTs
      await connect(dhtA, dhtB);
      
      // Retrieve B's public key from A
      final pubk = await dhtA.getPublicKey(dhtB.host().id);
      
      // The ID derived from the key should match B's ID
      final id = await PeerId.fromPublicKey(pubk);
      expect(id, equals(dhtB.host().id));
      
      // Cleanup
      await dhtA.close();
      await dhtB.close();
    });
    
    test('PubkeyFromDHT - GetPublicKey retrieves key from DHT', () async {
      final dhtA = await setupDHT(false);
      final dhtB = await setupDHT(false);
      
      // Connect the DHTs
      await connect(dhtA, dhtB);
      
      // Generate a random identity
      final keyPair = await Ed25519KeyPair.random(); // Ed25519KeyPair might be undefined
      final id = await PeerId.fromPublicKey(keyPair.publicKey);


      // Store the public key on node B
      // final pkkey = RoutingKey.forPublicKey(id); // RoutingKey might be undefined
      // final pkbytes = keyPair.publicKey.raw;
      // await dhtB.putValue(pkkey.toString(), pkbytes); // toString() if pkkey is an object
      
      // Retrieve the public key on node A
      final retrievedKey = await dhtA.getPublicKey(id);
      
      // The keys should match
      expect(retrievedKey.raw, equals(keyPair.publicKey.raw));
      
      // Cleanup
      await dhtA.close();
      await dhtB.close();
    });
    
    test('PubkeyNotFound - GetPublicKey returns error when key not available', () async {
      final dhtA = await setupDHT(false);
      final dhtB = await setupDHT(false);
      
      // Connect the DHTs
      await connect(dhtA, dhtB);
      
      // Generate a random identity that's not in the DHT
      final keyPair = await Ed25519KeyPair.random(); // Ed25519KeyPair might be undefined
      final id = await PeerId.fromPublicKey(keyPair.publicKey);
      
      // Attempt to retrieve the key should fail
      expect(
        () => dhtA.getPublicKey(id),
        throwsA(isA<Exception>())
      );
      
      // Cleanup
      await dhtA.close();
      await dhtB.close();
    });*/
    
    test('ValuesDisabled - DHT with values disabled rejects value operations', () async {
      // DHTOptions no longer has enableValues. It's a direct property of IpfsDHT.
      final dht = await setupDHT(false); 
      dht.enableValues = false;
      
      // Attempt to put a value should fail
      expect(
        () async => await dht.putValue('/test/key', Uint8List.fromList([1, 2, 3])),
        throwsA(isA<Exception>())
      );
      
      // Attempt to get a value should fail
      expect(
        () async => await dht.getValue('/test/key', RoutingOptions()),
        throwsA(isA<Exception>())
      );
      
      // Cleanup
      await dht.close();
    });
  });
}
