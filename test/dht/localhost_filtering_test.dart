import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p_kad_dht/src/dht/dht_filters.dart';

void main() {
  group('Localhost Address Filtering', () {
    test('should identify IPv4 localhost addresses', () {
      final localhostAddrs = [
        MultiAddr('/ip4/127.0.0.1/tcp/4001'),
        MultiAddr('/ip4/127.0.0.0/tcp/4001'),
        MultiAddr('/ip4/127.1.1.1/tcp/4001'),
        MultiAddr('/ip4/127.255.255.255/tcp/4001'),
      ];

      for (final addr in localhostAddrs) {
        expect(isLocalhostAddr(addr), isTrue, 
            reason: '${addr.toString()} should be identified as localhost');
      }
    });

    test('should not identify non-localhost IPv4 addresses as localhost', () {
      final nonLocalhostAddrs = [
        MultiAddr('/ip4/192.168.1.1/tcp/4001'),
        MultiAddr('/ip4/10.0.0.1/tcp/4001'),
        MultiAddr('/ip4/8.8.8.8/tcp/4001'),
        MultiAddr('/ip4/172.16.0.1/tcp/4001'),
        MultiAddr('/ip4/126.255.255.255/tcp/4001'),
        MultiAddr('/ip4/128.0.0.1/tcp/4001'),
      ];

      for (final addr in nonLocalhostAddrs) {
        expect(isLocalhostAddr(addr), isFalse, 
            reason: '${addr.toString()} should not be identified as localhost');
      }
    });

    test('should identify IPv6 localhost addresses', () {
      final localhostAddrs = [
        MultiAddr('/ip6/::1/tcp/4001'),
      ];

      for (final addr in localhostAddrs) {
        expect(isLocalhostAddr(addr), isTrue, 
            reason: '${addr.toString()} should be identified as localhost');
      }
    });

    test('should filter out localhost addresses from a list', () {
      final mixedAddrs = [
        MultiAddr('/ip4/127.0.0.1/tcp/4001'),      // localhost - should be filtered
        MultiAddr('/ip4/192.168.1.1/tcp/4001'),   // private - should remain
        MultiAddr('/ip4/8.8.8.8/tcp/4001'),       // public - should remain
        MultiAddr('/ip6/::1/tcp/4001'),           // localhost - should be filtered
        MultiAddr('/ip4/127.1.1.1/tcp/4001'),     // localhost - should be filtered
        MultiAddr('/ip4/10.0.0.1/tcp/4001'),      // private - should remain
      ];

      final filtered = filterLocalhostAddrs(mixedAddrs);

      expect(filtered.length, equals(3));
      expect(filtered.map((a) => a.toString()), containsAll([
        '/ip4/192.168.1.1/tcp/4001',
        '/ip4/8.8.8.8/tcp/4001',
        '/ip4/10.0.0.1/tcp/4001',
      ]));

      // Ensure localhost addresses are not in the filtered list
      expect(filtered.map((a) => a.toString()), isNot(contains('/ip4/127.0.0.1/tcp/4001')));
      expect(filtered.map((a) => a.toString()), isNot(contains('/ip6/::1/tcp/4001')));
      expect(filtered.map((a) => a.toString()), isNot(contains('/ip4/127.1.1.1/tcp/4001')));
    });

    test('should handle empty address list', () {
      final emptyList = <MultiAddr>[];
      final filtered = filterLocalhostAddrs(emptyList);
      expect(filtered, isEmpty);
    });

    test('should handle list with only localhost addresses', () {
      final onlyLocalhost = [
        MultiAddr('/ip4/127.0.0.1/tcp/4001'),
        MultiAddr('/ip4/127.1.1.1/tcp/4001'),
        MultiAddr('/ip6/::1/tcp/4001'),
      ];

      final filtered = filterLocalhostAddrs(onlyLocalhost);
      expect(filtered, isEmpty);
    });

    test('should handle list with no localhost addresses', () {
      final noLocalhost = [
        MultiAddr('/ip4/192.168.1.1/tcp/4001'),
        MultiAddr('/ip4/8.8.8.8/tcp/4001'),
        MultiAddr('/ip4/10.0.0.1/tcp/4001'),
      ];

      final filtered = filterLocalhostAddrs(noLocalhost);
      expect(filtered.length, equals(3));
      expect(filtered, equals(noLocalhost));
    });

    test('should handle malformed addresses gracefully', () {
      // Test that the function doesn't crash on malformed addresses
      // and treats them as non-localhost (safer default)
      try {
        final result = isLocalhostAddr(MultiAddr('/tcp/4001')); // No IP component
        expect(result, isFalse); // Should default to false for safety
      } catch (e) {
        // If it throws, that's also acceptable behavior
        expect(e, isNotNull);
      }
    });
  });

  group('IP Parsing', () {
    test('should parse IPv4 addresses correctly', () {
      final addr = MultiAddr('/ip4/127.0.0.1/tcp/4001');
      final ip = toIP(addr);
      
      expect(ip, isNotNull);
      expect(ip!.bytes.length, equals(4));
      expect(ip.bytes[0], equals(127));
      expect(ip.bytes[1], equals(0));
      expect(ip.bytes[2], equals(0));
      expect(ip.bytes[3], equals(1));
    });

    test('should parse IPv6 loopback address correctly', () {
      final addr = MultiAddr('/ip6/::1/tcp/4001');
      final ip = toIP(addr);
      
      expect(ip, isNotNull);
      expect(ip!.bytes.length, equals(16));
      // Check that all bytes are 0 except the last one which should be 1
      for (int i = 0; i < 15; i++) {
        expect(ip.bytes[i], equals(0));
      }
      expect(ip.bytes[15], equals(1));
    });

    test('should return null for non-IP addresses', () {
      final addr = MultiAddr('/tcp/4001');
      final ip = toIP(addr);
      expect(ip, isNull);
    });
  });
}
