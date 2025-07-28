import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:test/test.dart';

void main() {
  group('Protocol Constants', () {
    test('Protocol IDs are correctly defined', () {
      expect(AminoConstants.protocolPrefix, equals('/ipfs'));
      expect(AminoConstants.protocolID, equals('/ipfs/kad/1.0.0'));
      expect(protocols, contains(AminoConstants.protocolID));
    });

    test('Default values are correctly defined', () {
      expect(AminoConstants.defaultBucketSize, equals(20));
      expect(AminoConstants.defaultConcurrency, equals(10));
      expect(AminoConstants.defaultResiliency, equals(3));
      expect(AminoConstants.defaultProvideValidity, equals(Duration(hours: 48)));
      expect(AminoConstants.defaultProviderAddrTTL, equals(Duration(hours: 24)));
    });
  });
}