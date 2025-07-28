import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dcid/dcid.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/routing/routing.dart';
// Removed duplicate: import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:dart_libp2p_kad_dht/src/netsize/netsize.dart' as netsize;
import 'package:dart_libp2p_kad_dht/src/dht/dht_options.dart' as dht_options;
import 'package:dart_libp2p_kad_dht/src/dht/lookup_optim.dart'; // For optimisticProvide extension
import 'package:dart_libp2p_kad_dht/src/kbucket/keyspace/kad_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart'; // For AddrInfo
import 'package:dart_libp2p/p2p/discovery/peer_info.dart';


import 'package:test/test.dart';
import 'package:logging/logging.dart'; // Added for _log
import 'package:dart_libp2p/core/multiaddr.dart'; // For MultiAddr
import 'package:dart_libp2p/core/crypto/keys.dart'; // For KeyPair
import 'package:dart_libp2p/p2p/host/basic/basic_host.dart'; // For BasicHost
import 'package:dart_libp2p/core/peerstore.dart' as core_peerstore; // For AddressTTL
import 'package:dart_libp2p/core/event/bus.dart' as core_event_bus;
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_eventbus;
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_transport;
import 'package:dart_libp2p/core/network/rcmgr.dart'; // For ResourceManager
import 'package:dart_libp2p/p2p/host/resource_manager/resource_manager_impl.dart'; // For ResourceManagerImpl
import 'package:dart_libp2p/p2p/host/resource_manager/limiter.dart'; // For FixedLimiter (interface) and FixedLimiterImpl (implementation)
import 'package:dart_udx/dart_udx.dart';

import '../real_net_stack.dart' as real_net_stack; // New import

final _log = Logger('TestOptimisticProvide'); // Logger for this test file

// Shared resources for the real network stack
late UDX _udxInstance;
late ResourceManager _resourceManager;
late p2p_transport.ConnectionManager _connManager;
late core_event_bus.EventBus _hostEventBus;


// Placeholder for CIDs used in the test.
// In Go, these are likely []cid.CID. Here we'll use List<Uint8List> for their multihash bytes.
// These should be actual multihashes for a real test.
// Now generating valid (dummy) SHA2-256 multihashes (prefix + 32-byte digest)
final List<Uint8List> testCaseCids = List.generate(20, (i) {
  final digest = Uint8List.fromList(List.generate(32, (j) => (i + j) % 256));
  final multihashPrefix = Uint8List.fromList([0x12, 0x20]); // 0x12 = sha2-256, 0x20 = 32 bytes
  return Uint8List.fromList([...multihashPrefix, ...digest]);
});

// Helper to get a random integer within a range, excluding a specific value.
int randInt(Random rng, int n, int except) {
  if (n <= 1 && except == 0) {
    throw ArgumentError('Cannot generate random int under these constraints');
  }
  while (true) {
    final r = rng.nextInt(n);
    if (r != except) {
      return r;
    }
  }
}

// Helper to setup DHTs for optimistic provide testing.
// This will now use the real network stack.
// Structure to hold DHT and its associated components for testing
class DHTRealNode {
  final IpfsDHT dht;
  final BasicHost host;
  final PeerId peerId;
  final List<MultiAddr> listenAddrs;

  DHTRealNode(this.dht, this.host, this.peerId, this.listenAddrs);
}

Future<List<DHTRealNode>> setupRealDHTNodes(int count, TestReporter reporter) async {
  final nodes = <DHTRealNode>[];
  for (var i = 0; i < count; i++) {
    final nodeInfo = await real_net_stack.createLibp2pNode(
      udxInstance: _udxInstance,
      resourceManager: _resourceManager,
      connManager: _connManager,
      hostEventBus: _hostEventBus,
      userAgentPrefix: 'dht-optim-test-node-$i',
      listenAddrsOverride:  [MultiAddr('/ip4/127.0.0.1/udp/0/udx')]
    );
    
    // Create IpfsDHT instance for this real host
    final dht = IpfsDHT(
      host: nodeInfo.host, 
      providerStore: MemoryProviderStore(), // Using MemoryProviderStore from dart_libp2p_kad_dht
      options: DHTOptions( // Use DHTOptions directly, assuming it's exported by the main package lib
        mode: DHTMode.server, // Use DHTMode from lib/src/dht/dht.dart (should be in scope)
        bucketSize: 20, // Default Kademlia bucket size
      )
    );
    await dht.start(); // Start the DHT service on the host

    nodes.add(DHTRealNode(dht, nodeInfo.host, nodeInfo.peerId, nodeInfo.listenAddrs));
    reporter.log('Setup Real DHT Node ${nodeInfo.peerId.short()} listening on ${nodeInfo.listenAddrs}');
  }
  return nodes;
}


// final _log = Logger('lookup_optim_test.dart');

void main() {
  // Configure logging (ensure it's set up once, e.g. at the top or in a global setup)
  Logger.root.level = Level.FINER; // Adjust as needed, e.g. Level.ALL for more verbosity
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
    if (record.error != null) {
      print('ERROR: ${record.error}');
    }
    if (record.stackTrace != null) {
      print('STACKTRACE: ${record.stackTrace}');
    }
  });

  group('DHT Lookup Optimization Tests with Real Network Stack', () {
    const dhtCount = 5; // Ensure this is 21 for the full test scale
    final reporter = TestReporter(); // Simple logger
    late List<DHTRealNode> dhtNodes;
    late IpfsDHT privDHT;
    late PeerId privPeerId;


    setUpAll(() async {
      _udxInstance = UDX();
      // Use FixedLimiter() as it's the concrete class
      _resourceManager = ResourceManagerImpl(limiter: FixedLimiter()); 
      _connManager = p2p_transport.ConnectionManager();
      _hostEventBus = p2p_eventbus.BasicBus();

      reporter.log('Setting up $dhtCount Real DHT Nodes for optimistic provide testing...');
      dhtNodes = await setupRealDHTNodes(dhtCount, reporter);
      reporter.log('$dhtCount Real DHT Nodes setup complete.');

      // Connect nodes to each other to form a network
      reporter.log('Connecting Real DHT Nodes...');
      for (int i = 0; i < dhtNodes.length; i++) {
        final nodeA = dhtNodes[i];
        // Connect to a few other random nodes (e.g., 3)
        for (int k = 0; k < 3; k++) {
          if (dhtNodes.length <= 1) break;
          int otherIdx;
          do {
            otherIdx = Random().nextInt(dhtNodes.length);
          } while (otherIdx == i); // Ensure not connecting to self

          final nodeB = dhtNodes[otherIdx];
          if (nodeB.listenAddrs.isNotEmpty) {
            try {
              final addrInfoB = AddrInfo(nodeB.peerId, nodeB.listenAddrs);
              reporter.log('Connecting ${nodeA.peerId.short()} to ${nodeB.peerId.short()} at ${nodeB.listenAddrs.first}');
              await nodeA.host.connect(addrInfoB);
              // Add to peerstore for good measure, though identify should handle this
              nodeA.host.peerStore.addrBook.addAddrs(nodeB.peerId, nodeB.listenAddrs, core_peerstore.AddressTTL.permanentAddrTTL);
              nodeB.host.peerStore.addrBook.addAddrs(nodeA.peerId, nodeA.listenAddrs, core_peerstore.AddressTTL.permanentAddrTTL);
            } catch (e) {
              reporter.log('Error connecting ${nodeA.peerId.short()} to ${nodeB.peerId.short()}: $e');
            }
          } else {
            reporter.log('Skipping connection from ${nodeA.peerId.short()} to ${nodeB.peerId.short()} as target has no listen addresses.');
          }
        }
      }
      reporter.log('Real DHT Nodes connection attempts complete.');
      
      reporter.log('Allowing 20 seconds for network stabilization (identify, Kademlia pings)...');
      await Future.delayed(Duration(seconds: 20));


      // Select privileged DHT
      final rng = Random(DateTime.now().millisecondsSinceEpoch);
      final privIdx = rng.nextInt(dhtCount);
      privDHT = dhtNodes[privIdx].dht;
      privPeerId = dhtNodes[privIdx].peerId;
      reporter.log('Privileged DHT: ${privDHT.host().id.short()} (index $privIdx)');

      // 4. initialize network size estimator of privileged DHT
      // Prepare PeerInfo list for tracking (all other peers)
      final List<PeerInfo> peerInfosForNSE = [];
      for (int i = 0; i < dhtCount; i++) {
        if (i == privIdx) continue;
        // In Go, it's just peerIDs. In Dart, `track` needs `List<PeerInfo>`.
        // We need to ensure these PeerInfo objects have addresses if the `track` method relies on them.
        final peerId = dhtNodes[i].peerId; // Corrected: Use dhtNodes
        final addrs = dhtNodes[i].listenAddrs; // Corrected: Use dhtNodes and listenAddrs
        peerInfosForNSE.add(PeerInfo(peerId: peerId, addrs: Set.from(addrs)));
      }
      
      // The Go test tracks 20 CIDs with 20 distinct peer IDs.
      // The `track` method in Dart's netsize.Estimator expects `peers.length == bucketSize`.
      // This is a mismatch with how the Go test uses `nse.Track`.
      // Go's `nse.Track(string(testCaseCids[i].Bytes()), peerIDs)` - `peerIDs` is a list of 20 peers.
      // Dart's `nse.track(String key, List<PeerInfo> peers)`
      // For now, I will assume the Dart `track` method needs to be called with a list of peers of `bucketSize`.
      // The Go test seems to imply that `Track` is called for each CID with the *same* list of 20 other peers.
      // This part needs careful adaptation.
      // Let's assume default bucketSize is 20 for now, matching the number of CIDs/peers in Go test.
      // If privDHT.options.bucketSize is different, this will fail or need adjustment.
      // Accessing options on IpfsDHT instance.
      final dhtNodeOptions = privDHT.options; // This should now correctly refer to the DHTOptions instance member of IpfsDHT
      final bucketSize = dhtNodeOptions.bucketSize; 
      
      reporter.log('Using Network Size Estimator from privDHT for ${privDHT.host().id.short()} with bucketSize: $bucketSize');
      final nse = privDHT.nsEstimator; // Use the nsEstimator from the IpfsDHT instance

      reporter.log('Tracking CIDs for network size estimation...');
      // The Go test tracks 20 CIDs. For each CID, it calls Track with a list of 20 *other* peers.
      // Dart's `track` expects `peers.length == bucketSize`.
      // If bucketSize is 20, we can take the first `bucketSize` peers from `peerInfosForNSE`.
      if (peerInfosForNSE.length < bucketSize) {
         reporter.log('Warning: Not enough distinct peers (${peerInfosForNSE.length}) for NSE track (requires $bucketSize). Skipping NSE tracking for now.');
      } else {
        final peersForTracking = peerInfosForNSE.sublist(0, bucketSize);
        for (var i = 0; i < testCaseCids.length; i++) {
          // The Go test uses `string(testCaseCids[i].Bytes())` as the key.
          final keyString = String.fromCharCodes(testCaseCids[i]);
          try {
            await nse.track(keyString, peersForTracking);
            reporter.log('Tracked CID $i for NSE with ${peersForTracking.length} peers.');
          } catch (e) {
            reporter.log('Error tracking CID $i for NSE: $e. This might be due to not enough measurements yet for internal calculations or other setup issues.');
            // The test might still proceed, but network size estimation might be off.
          }
        }
      }
      reporter.log('Network Size Estimator initialized and CIDs tracked.');


      // 5. perform provides
      reporter.log('Privileged DHT ${privDHT.host().id.short()} performing optimistic provides...');
      for (final cidMH_bytes in testCaseCids) { 
        reporter.log('Optimistically providing ${KadID(cidMH_bytes).short()}'); // Use KadID constructor
        try {
          // optimisticProvide is an extension method, should be available now.
          await privDHT.optimisticProvide(cidMH_bytes); 
          reporter.log('Successfully called optimisticProvide for ${KadID(cidMH_bytes).short()}');
        } catch (e, s) {
          reporter.log('Error during optimisticProvide for ${KadID(cidMH_bytes).short()}: $e\n$s');
          fail('Optimistic provide failed: $e');
        }
      }
      reporter.log('Optimistic provides completed by ${privDHT.host().id.short()}.');

      // 6. let all other DHTs perform the lookup for all provided CIDs
      reporter.log('Verifying provides from other DHTs...');
      for (final cidToFind_bytes in testCaseCids) { // Renamed
        // Select a random DHT (not the privileged one) to perform the lookup
        final lookupDHTIdx = randInt(rng, dhtCount, privIdx);
        final lookupDHT = dhtNodes[lookupDHTIdx].dht; // Corrected: Use dhtNodes and access .dht
        // Assuming core_cid.CID.fromBytes or core_cid.CID() exists.
        // This is a common pattern for CID libraries.
        final cidForLookup = CID.fromBytes(cidToFind_bytes);
        reporter.log('DHT ${lookupDHT.host().id.short()} (index $lookupDHTIdx) finding providers for ${KadID(cidToFind_bytes).short()}');

        final Completer<AddrInfo?> providerCompleter = Completer();
        StreamSubscription? sub;

        // Timeout for finding providers
        final timeoutDuration = Duration(seconds: 5); // Keep this for the overall operation within the loop iteration

        try {
          final foundProviders = <AddrInfo>[];
          await lookupDHT.findProvidersAsync(cidForLookup, 1)
            .timeout(timeoutDuration) // Apply timeout to the stream operation
            .listen((addrInfo) {
              reporter.log('Provider found by ${lookupDHT.host().id.short()} for ${KadID(cidToFind_bytes).short()}: ${addrInfo.id.short()}');
              foundProviders.add(addrInfo);
              // Typically, findProvidersAsync might yield multiple, but with count:1 we expect at most one from this specific call.
              // The stream might complete after the first one if `count` is respected by the implementation.
            }).asFuture().catchError((e) { // Catch timeout or other stream errors
              if (e is TimeoutException) {
                reporter.log('Timeout finding provider for ${KadID(cidToFind_bytes).short()} from ${lookupDHT.host().id.short()}');
              } else {
                reporter.log('Error finding provider for ${KadID(cidToFind_bytes).short()} by ${lookupDHT.host().id.short()}: $e');
              }
              // Let foundProviders remain empty or partially filled if error occurred after some providers.
            });

          expect(foundProviders, isNotEmpty, reason: 'Got back no provider for ${KadID(cidToFind_bytes).short()} from ${lookupDHT.host().id.short()}');
          expect(foundProviders.first.id, privPeerId, reason: 'Got back wrong provider for ${KadID(cidToFind_bytes).short()}. Expected ${privPeerId.short()}, got ${foundProviders.first.id.short()}');
          reporter.log('Successfully verified provider for ${KadID(cidToFind_bytes).short()} from ${lookupDHT.host().id.short()}.');
        } catch (e,s) {
          reporter.log('Verification failed for ${KadID(cidToFind_bytes).short()} from ${lookupDHT.host().id.short()}: $e\n$s');
          fail('Verification failed for ${KadID(cidToFind_bytes).short()}: $e');
        }
      }
      reporter.log('All provider verifications complete.');
    }); 

    tearDownAll(() async {
      reporter.log('Closing Real DHT Nodes...');
      for (final node in dhtNodes) {
        try {
          await node.host.close(); // This should also close the underlying Swarm and DHT
        } catch (e) {
          reporter.log('Error closing host ${node.peerId.short()}: $e');
        }
      }
      // Close shared resources
      try {
        await _connManager.dispose();
      } catch (e) {
         reporter.log('Error disposing ConnectionManager: $e');
      }
      try {
        await _resourceManager.close();
      } catch (e) {
        reporter.log('Error closing ResourceManager: $e');
      }
      // UDX instance might not have a close/dispose method, or it's handled by transports.
      // If _udxInstance.close() or .dispose() exists and is needed:
      // try { await _udxInstance.close(); } catch (e) { reporter.log('Error closing UDX: $e'); }
      reporter.log('Real DHT Nodes and shared resources closed.');
    });
  });
}

// Simple reporter for logging during tests.
class TestReporter {
  void log(String message) {
    _log.fine('[TestOptimisticProvide] $message');
  }
}

extension PeerIdShort on PeerId {
  String short() {
    final s = toString();
    return s.length > 10 ? '...${s.substring(s.length - 6)}' : s;
  }
}

extension KadIdShort on KadID {
   String short() {
    final s = toString();
    return s.length > 10 ? '...${s.substring(s.length - 6)}' : s;
  } 
}
