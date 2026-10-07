import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_mgr;
import 'package:dart_libp2p_kad_dht/src/dht/dht_options.dart';
import 'package:dart_libp2p_kad_dht/src/dht/v2/dht_v2.dart';
import 'package:dart_libp2p_kad_dht/src/internal/util.dart' show truncateForLog;
import 'package:dart_libp2p_kad_dht/src/providers/provider_store.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:test/test.dart';

import 'real_net_stack.dart';

/// Keys shorter than the 10-character log prefix used to throw a RangeError
/// from the log calls in putValue and getValue.
void main() {
  group('truncateForLog', () {
    test('returns short strings unchanged and truncates long ones', () {
      expect(truncateForLog(''), '');
      expect(truncateForLog('my-key'), 'my-key');
      expect(truncateForLog('0123456789'), '0123456789');
      expect(truncateForLog('0123456789abc'), '0123456789');
      expect(truncateForLog('::1', 8), '::1');
      expect(truncateForLog('abc', 0), '');
    });
  });

  group('DHT v2 with short keys', () {
    Host? host;
    IpfsDHTv2? dht;

    tearDown(() async {
      await dht?.close();
      await host?.close();
      dht = null;
      host = null;
    });

    test('putValue and getValue work with a 6-character key', () async {
      final details = await createLibp2pNode(
        udxInstance: UDX(),
        resourceManager: NullResourceManager(),
        connManager: p2p_conn_mgr.ConnectionManager(),
        hostEventBus: p2p_event_bus.BasicBus(),
        userAgentPrefix: 'dht-short-key-test',
      );
      host = details.host;
      dht = IpfsDHTv2(
        host: host!,
        providerStore: MemoryProviderStore(),
        options: const DHTOptions(
          mode: DHTMode.server,
          autoRefresh: false,
          bootstrapPeers: [],
        ),
      );
      await dht!.start();

      final value = Uint8List.fromList(utf8.encode('my-value'));
      await dht!.putValue('my-key', value);
      expect(await dht!.getValue('my-key'), equals(value));

      // The datastore helpers log the key too.
      expect(await dht!.hasRecordInDatastore('my-key'), isTrue);
      expect(await dht!.getRecordFromDatastore('k'), isNull);
      await dht!.removeRecordFromDatastore('k');
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
