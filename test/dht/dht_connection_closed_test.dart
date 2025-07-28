import 'dart:async';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/network.dart'; // For Network interface
import 'package:dart_libp2p/p2p/network/swarm/swarm.dart'; // For Swarm concrete type
import 'package:dart_libp2p/p2p/protocol/identify/identify.dart'; // For Identify.ID and Identify class
import 'package:dart_libp2p/p2p/protocol/identify/identify.dart' as identify;
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:dart_libp2p_kad_dht/src/dht/dht.dart';
import 'package:dart_libp2p_kad_dht/src/dht/dht_options.dart' as dht_options_lib; // Aliased for clarity
import 'package:dart_libp2p_kad_dht/src/providers/provider_store.dart'; // For MemoryProviderStore
import 'package:logging/logging.dart';
import 'package:test/test.dart';

// Dependencies for _NodeWithDHT and createLibp2pNode
import '../real_net_stack.dart'; // For Libp2pNode and createLibp2pNode
import 'package:dart_udx/dart_udx.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart'; // For ResourceManager and NoopResourceManager
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_mgr;
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;
// Peerstore needed for AddressTTL if _NodeWithDHT uses it, but it's not directly used in this version
// import 'package:dart_libp2p/core/peerstore.dart';

final Logger _log = Logger('DHT ConnectionClosedTest');

// Helper class to encapsulate node and DHT creation for tests using real_net_stack
// Adapted from test/dht/dht_discovery_test.dart
class _NodeWithDHT {
  late Libp2pNode nodeDetails;
  late IpfsDHT dht;
  late Host host;
  late PeerId peerId;
  late UDX _udxInstance; // Keep instance to close if necessary

  _NodeWithDHT._privateConstructor(); // Private constructor

  static Future<_NodeWithDHT> create({String? userAgentPrefix}) async {
    final helper = _NodeWithDHT._privateConstructor();

    helper._udxInstance = UDX();
    final resourceManager = NullResourceManager();
    final connManager = p2p_conn_mgr.ConnectionManager();
    final eventBus = p2p_event_bus.BasicBus();

    helper.nodeDetails = await createLibp2pNode(
      udxInstance: helper._udxInstance,
      resourceManager: resourceManager,
      connManager: connManager,
      hostEventBus: eventBus,
      userAgentPrefix: userAgentPrefix, // Pass through userAgentPrefix
    );
    helper.host = helper.nodeDetails.host;
    helper.peerId = helper.nodeDetails.peerId;

    final providerStore = MemoryProviderStore();
    helper.dht = IpfsDHT(
      host: helper.host,
      providerStore: providerStore,
      options: DHTOptions(mode: DHTMode.server),
    );
    return helper;
  }

  Future<void> stop() async {
    await dht.close();
    await host.close();
    // UDX instance disposal might be handled globally or per test suite
    // If UDX.dispose() is available and appropriate for individual test cleanup:
    // await _udxInstance.dispose();
  }
}

// Helper to get abbreviated PeerId for logging
extension PeerIdAbbr on PeerId {
  String toBase58Abbr({int len = 6}) => toBase58().substring(0, len);
}

void main() {
  Logger.root.level = Level.INFO; // Default to INFO, can be changed to ALL for debugging
  Logger.root.onRecord.listen((record) {
    print(
        '${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
    if (record.error != null) {
      print('ERROR: ${record.error}, StackTrace: ${record.stackTrace}');
    }
  });

  group('DHT Connection Closed Scenarios', () {
    _NodeWithDHT? nodeAHelper; // Nullable for tearDown
    _NodeWithDHT? nodeBHelper; // Nullable for tearDown

    setUp(() async {
      nodeAHelper = await _NodeWithDHT.create(userAgentPrefix: 'nodeA');
      nodeBHelper = await _NodeWithDHT.create(userAgentPrefix: 'nodeB');

      await nodeAHelper!.dht.start();
      await nodeBHelper!.dht.start();

      expect(nodeBHelper!.nodeDetails.listenAddrs, isNotEmpty,
          reason: "Node B must be listening to accept connections.");

      _log.info(
          'Connecting Host A (${nodeAHelper!.peerId.toBase58Abbr()}) to Host B (${nodeBHelper!.peerId.toBase58Abbr()}) using addrs: ${nodeBHelper!.nodeDetails.listenAddrs}');
      
      try {
        await nodeAHelper!.host.connect(
            AddrInfo(nodeBHelper!.peerId, nodeBHelper!.nodeDetails.listenAddrs));
        _log.info('Connection attempt from A to B finished.');
      } catch (e,s) {
        _log.severe('Error connecting Host A to Host B: $e', e, s);
        fail('Setup failed: Could not connect Host A to Host B. $e');
      }
      

      // Verify connection from A's perspective
      final connsFromAToB =
          nodeAHelper!.host.network.connsToPeer(nodeBHelper!.peerId);
      expect(connsFromAToB, isNotEmpty,
          reason: "Host A should have a connection to Host B after connect call.");
      _log.info(
          'Host A (${nodeAHelper!.peerId.toBase58Abbr()}) sees ${connsFromAToB.length} connection(s) to Host B (${nodeBHelper!.peerId.toBase58Abbr()}). IDs: ${connsFromAToB.map((c) => c.id).join(', ')}');

      // Verify connection from B's perspective
      // Need a slight delay for the connection to be fully registered on B side after A connects
      await Future.delayed(Duration(milliseconds: 100)); 
      final connsFromBToA =
          nodeBHelper!.host.network.connsToPeer(nodeAHelper!.peerId);
      expect(connsFromBToA, isNotEmpty,
          reason: "Host B should have a connection from Host A after A connects.");
      _log.info(
          'Host B (${nodeBHelper!.peerId.toBase58Abbr()}) sees ${connsFromBToA.length} connection(s) from Host A (${nodeAHelper!.peerId.toBase58Abbr()}). IDs: ${connsFromBToA.map((c) => c.id).join(', ')}');
    });

    tearDown(() async {
      await nodeAHelper?.stop();
      await nodeBHelper?.stop();
      nodeAHelper = null;
      nodeBHelper = null;
    });

    test(
        'Scenario 1: Opening new stream directly on Conn object on Host A fails if Host B closes the connection',
        () async {
      _log.info(
          'Test: Server (Host B: ${nodeBHelper!.peerId.toBase58Abbr()}) closes connection, Client (Host A: ${nodeAHelper!.peerId.toBase58Abbr()}) attempts new stream on existing Conn object.');

      // 1. Get the initial connection object on Host B that is to Host A
      // Note: Using connsToPeer as per the user-corrected file.
      final connsOnBToA_beforeClose =
          nodeBHelper!.host.network.connsToPeer(nodeAHelper!.peerId);
      expect(connsOnBToA_beforeClose, isNotEmpty,
          reason: "Host B should have an active connection from Host A before closing.");
      final connToCloseOnB = connsOnBToA_beforeClose.first;
      _log.info(
          // Using .remotePeer and .localPeer directly as properties, as per user-corrected file.
          'Host B found connection to Host A: ${connToCloseOnB.id} (Remote: ${connToCloseOnB.remotePeer.toBase58Abbr()}, Local: ${connToCloseOnB.localPeer.toBase58Abbr()})');

      // Get Host A's connection object to Host B *before* Host B closes it.
      final connsOnAToB_beforeClose = nodeAHelper!.host.network.connsToPeer(nodeBHelper!.peerId);
      expect(connsOnAToB_beforeClose, isNotEmpty, reason: "Host A should have a connection to Host B before B closes it.");
      final Conn connOnAtoUse = connsOnAToB_beforeClose.first; // Get direct reference
      _log.info('Host A obtained its connection object to Host B: ${connOnAtoUse.id} (Stat: ${connOnAtoUse.stat}) *before* B closes.');

      // 2. Host B closes its specific connection to Host A.
      _log.info('Host B closing its specific connection (${connToCloseOnB.id}) to Host A.');
      await connToCloseOnB.close(); 
      _log.info('Host B finished closing its specific connection to Host A.');
      
      // Add a small delay to allow the closure to propagate and be processed by Host A's transport,
      // and for the state of connOnAtoUse to potentially update.
      await Future.delayed(Duration(milliseconds: 300)); 

      // 3. Host A attempts to open a new stream directly on its (now stale) *pre-obtained* connection object to Host B
      _log.info(
          'Host A attempting to open a new stream on its *pre-obtained* connection object (${connOnAtoUse.id}, Stat after delay: ${connOnAtoUse.stat}) to Host B.');
      
      // Optional: Log if the connection is still in the main list for diagnostics
      final connsStillInList = nodeAHelper!.host.network.connsToPeer(nodeBHelper!.peerId);
      if (connsStillInList.isEmpty) {
        _log.info('Diagnostic: Host A no longer lists any connections to Host B in its network.connsToPeer list.');
      } else {
        _log.info('Diagnostic: Host A still lists ${connsStillInList.length} connection(s) to Host B. IDs: ${connsStillInList.map((c)=>c.id).join(', ')}');
      }
      // We no longer fail if the list is empty from connsToPeer, because we are using the direct reference `connOnAtoUse`.

      try {
        // Attempt to open a stream directly on the *original* connection object reference
        // Using the correct signature: newStream(Context context, int streamId)
        // Using 1 as a placeholder for a client-initiated stream ID.
        final stream = await connOnAtoUse.newStream(Context());
        
        _log.warning(
            'Host A successfully opened a new stream (id: ${stream.id}, stat: ${stream.stat()}) directly on the Conn object. This is NOT the expected outcome. The Conn object might be a new one or the old one is not erroring out as expected.');
        await stream.close();
        fail('Host A opened a new stream directly on Conn, but an exception was expected.');

      } catch (e, s) {
        _log.info('Host A failed to open new stream directly on Conn as expected. Error: $e');
        // Check if the error is "Connection is closed" or a similar multiplexer error like "stream closed" or "session is closed"
        final errorString = e.toString().toLowerCase();
        if (!errorString.contains('connection is closed') && !errorString.contains('stream closed') && !errorString.contains('session is closed')) {
             _log.warning('Stack trace for unexpected error: $s');
        }
        expect(e, isA<Exception>(), reason: 'Should throw an Exception.');
        expect(errorString, anyOf(contains('connection is closed'), contains('stream closed'), contains('session is closed')), 
            reason:
                'Exception message should indicate connection/stream/session issue. Actual: ${e.toString()}');
      }
    }, timeout: Timeout(Duration(seconds: 15))); 
  });
}
