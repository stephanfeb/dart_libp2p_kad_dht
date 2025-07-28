import 'dart:async';
import 'dart:typed_data';

// Core libp2p types - assuming these are the correct paths as used in project's own lib/src
import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/event/bus.dart';
import 'package:dart_libp2p/core/interfaces.dart';
import 'package:dart_libp2p/core/network/transport_conn.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/peerstore.dart';
import 'package:dart_libp2p/p2p/protocol/holepunch/holepunch_service.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
// If Multiaddr, Connection etc. are not found via host.dart, they might need their own specific imports
// For now, assuming Host and PeerId are the primary direct dependencies for the mocks.
// Other types like Multiaddr, Connection, Network, Peerstore, PrivKey, PubKey, HandlerFunction, StreamHandler, RawConnection, EventBus
// will be problematic if not correctly exported or if their packages are missing.

// For SimpleContext, if used (currently not directly by RtRefreshManager)
// import 'package:async/async.dart'; 

// Local project files
import 'package:dart_libp2p_kad_dht/src/kbucket/keyspace/kad_id.dart';
import 'package:dart_libp2p_kad_dht/src/kbucket/table/table.dart';
import 'package:dart_libp2p_kad_dht/src/kbucket/bucket/bucket.dart'; // For commonPrefixLen
import 'package:dart_libp2p_kad_dht/src/rtrefresh/rt_refresh_manager.dart';
import 'package:test/test.dart';
import 'dart:math' as math;
import 'package:logging/logging.dart';

// --- Mocks ---
// Mock for PeerLatencyMetrics (defined in local table.dart)
class MockPeerLatencyMetrics implements PeerLatencyMetrics {
  @override
  Duration latencyEWMA(PeerId peerId) => Duration(milliseconds: 10);
}

// Minimal MockHost focusing on what RtRefreshManager from lib/src/... actually uses:
// - host.peerId
// - host.dialPeer(PeerId)
// Other Host members are stubbed.
class MockHost implements Host {
  final PeerId peerId;
  MockHost(this.peerId);

  @override
  Future<void> close() async {}
  @override
  Future<void> start() async {}

  @override
  Future<Conn> dialPeer(PeerId id, {List<MultiAddr>? addrs, Context? context}) async {
    print('MockHost: dialPeer called for ${id.toBase58()} - succeeding (mock)');
    // Return a very basic MockConnection if the Host interface demands it.
    // The actual Connection object isn't used by RtRefreshManager's ping logic directly.
    return MockConnection(peerId, id);
  }

  // Stub out other Host members to satisfy the interface
  @override
  List<MultiAddr> get addrs => [];
  @override
  Future<void> connect(AddrInfo pi, {Context? context}) async {}
  @override
  EventBus get eventBus => throw UnimplementedError('MockHost.eventBus not implemented');
  @override
  Network get network => throw UnimplementedError('MockHost.network not implemented');
  @override
  Future<P2PStream> newStream(PeerId p, List<ProtocolID> pids, Context context){
    throw UnimplementedError('MockHost.newStream not implemented');
  }
  @override
  void removeStreamHandler(String protocol) {}
  @override
  void setStreamHandler(String protocol, StreamHandler handler) {}
  @override
  void setStreamHandlerMatch(String protocol, bool Function(String protocol) matcher, StreamHandler handler) {}
  @override
  ConnectionManager get connManager => throw UnimplementedError('MockHost.connManager not implemented');
  @override
  PeerId get id => peerId; // Assuming Host.id is same as Host.peerId
  @override
  ProtocolSwitch get mux => throw UnimplementedError('MockHost.mux not implemented');
  @override
  Peerstore get peerStore => throw UnimplementedError('MockHost.peerStore not implemented');

  @override
  // TODO: implement holePunchService
  HolePunchService? get holePunchService => throw UnimplementedError();

}

// Minimal MockConnection
class MockConnection implements Conn {
  @override
  final PeerId localPeer;
  @override
  final PeerId remotePeer;

  MockConnection(this.localPeer, this.remotePeer);

  @override
  // TODO: implement localMultiaddr
  MultiAddr get localMultiaddr => throw UnimplementedError();

  @override
  // TODO: implement remoteMultiaddr
  MultiAddr get remoteMultiaddr => throw UnimplementedError();

  @override
  // TODO: implement remotePublicKey
  Future<PublicKey?> get remotePublicKey => throw UnimplementedError();

  @override
  // TODO: implement scope
  ConnScope get scope => throw UnimplementedError();

  @override
  // TODO: implement stat
  ConnStats get stat => throw UnimplementedError();

  @override
  // TODO: implement state
  ConnState get state => throw UnimplementedError();

  @override
  // TODO: implement streams
  Future<List<P2PStream>> get streams => throw UnimplementedError();

  @override
  Future<void> close() {
    // TODO: implement close
    throw UnimplementedError();
  }

  @override
  // TODO: implement id
  String get id => throw UnimplementedError();

  @override
  // TODO: implement isClosed
  bool get isClosed => throw UnimplementedError();

  @override
  Future<P2PStream> newStream(Context context) {
    // TODO: implement newStream
    throw UnimplementedError();
  } // Added missing member
}


// --- Test Code ---
Future<PeerId> newPeerId() async {
  // Ensure PeerId.random() and PeerId.fromBytes() are available from the import
  return await PeerId.random();
}

void main() {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    print('[${record.loggerName}] ${record.level.name}: ${record.message}');
  });

  late PeerId localId;
  late RoutingTable rt;
  late RtRefreshManager refreshManager;
  late MockHost mockHost;
  late MockPeerLatencyMetrics mockMetrics;

  Future<void> testRefreshQueryFnc(String key, RoutingTable currentRt, int currentIgnoreCpl) async {
    print('testRefreshQueryFnc: Called with key "$key", ignoreCpl: $currentIgnoreCpl. Current RT size: ${currentRt.size}');
    final cplToQuery = int.tryParse(key);
    if (cplToQuery == null) {
      print('testRefreshQueryFnc: key "$key" is not a CPL, skipping.');
      return;
    }
    if (cplToQuery == currentIgnoreCpl) {
      print('testRefreshQueryFnc: CPL $cplToQuery is ignored (matches currentIgnoreCpl $currentIgnoreCpl), skipping peer add.');
      return;
    }

    print('testRefreshQueryFnc: Attempting to generate and add peer for CPL $cplToQuery.');
    try {
      final newPeer = await currentRt.genRandomPeerIdWithCpl(cplToQuery);
      print('testRefreshQueryFnc: For CPL $cplToQuery (key "$key"), generated peer ${newPeer.toBase58()} to add.');
      final addResult = await currentRt.tryAddPeer(newPeer, queryPeer: true, isReplaceable: false);
      print('testRefreshQueryFnc: Added peer ${newPeer.toBase58()} for CPL $cplToQuery. Result: $addResult. RT size now: ${currentRt.size}');
    } catch (e, s) {
      print('testRefreshQueryFnc: Error generating/adding peer for CPL $cplToQuery: $e\n$s');
    }
    print('testRefreshQueryFnc: Finished processing key "$key".');
  }

  Future<String> testRefreshKeyGenFnc(int cpl) async {
    return cpl.toString();
  }

  Future<void> testRefreshPingFnc(PeerId peerId) async {
    print('MockPing: Pinged ${peerId.toBase58()} - success (no-op)');
  }

  const int bucketSize = 20;
  const Duration defaultMaxLatency = Duration(seconds: 10);
  const Duration defaultUsefulnessGracePeriod = Duration(minutes: 10);
  const int maxCplQueryForTest = 10;

  setUp(() async {
    localId = await newPeerId();
    mockHost = MockHost(localId);
    mockMetrics = MockPeerLatencyMetrics();

    rt = RoutingTable(
      local: localId, // This is PeerId
      bucketSize: bucketSize,
      maxLatency: defaultMaxLatency,
      metrics: mockMetrics,
      usefulnessGracePeriod: defaultUsefulnessGracePeriod,
    );

    // Initialize RtRefreshManager here if it's constant across tests, or in runRefreshTestScenario
  });


  Future<void> runRefreshTestScenario({
    required int ignoreCpl,
    required Map<int, int> expectedPeersPerCplAfterRefresh,
    required int manuallyAddedPeerCpl,
  }) async {
    // Re-initialize rt for each scenario to ensure a clean state, or clean it.
    // For simplicity, re-initializing based on current setUp.
    // If setUp creates a shared rt, then rt.reset() or similar would be needed.
    // Current setUp creates localId, mockHost, mockMetrics, rt for each test implicitly via test group.

    // Manually add a peer
    // Assuming PeerId has toBytes() and KadID has maxCpl(int idLength)
    if (manuallyAddedPeerCpl < (KadID.getKademliaIdBytes(localId).length * 8)) { // Use getKademliaIdBytes for length consistency
        final manualPeer = await rt.genRandomPeerIdWithCpl(manuallyAddedPeerCpl);
        
        final localKadIdBytes = KadID.getKademliaIdBytes(localId);
        final manualPeerKadIdBytes = KadID.getKademliaIdBytes(manualPeer);
        final calculatedManualCpl = commonPrefixLen(localKadIdBytes, manualPeerKadIdBytes);

        print('DEBUG: localId=${localId.toBase58()}, localKadIdHex=${localKadIdBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('')}');
        print('DEBUG: manualPeer=${manualPeer.toBase58()}, manualPeerKadIdHex=${manualPeerKadIdBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('')}');
        print('DEBUG: CPL between localKadId and manualPeerKadId (expected $manuallyAddedPeerCpl): $calculatedManualCpl');

        final addResult = await rt.tryAddPeer(manualPeer, queryPeer: true, isReplaceable: false);
        print('DEBUG: tryAddPeer result for manualPeer: $addResult');
        
        // Force a read of the peer list to ensure state if async operations are tricky
        final peersInRt = await rt.listPeers();
        print('DEBUG: Peers in RT after manual add: ${peersInRt.map((pi) => pi.id.toBase58()).toList()}');
        for (var pi in peersInRt) {
          if (pi.id == manualPeer) {
            print('DEBUG: Manual peer found in listPeers. Its stored dhtId CPL with localKadId: ${commonPrefixLen(localKadIdBytes, Uint8List.fromList(pi.dhtId))}');
          }
        }


        expect(await rt.nPeersForCpl(manuallyAddedPeerCpl), 1,
            reason: 'Manual peer should be present at CPL $manuallyAddedPeerCpl before refresh. Calculated CPL for manual peer was $calculatedManualCpl.');
    } else {
        print("Skipping manual peer add for CPL $manuallyAddedPeerCpl as it's too large.");
    }

    refreshManager = RtRefreshManager(
      host: mockHost,
      dhtPeerId: localId,
      rt: rt,
      enableAutoRefresh: false,
      refreshKeyGenFnc: testRefreshKeyGenFnc,
      refreshQueryFnc: (String key) => testRefreshQueryFnc(key, rt, ignoreCpl),
      refreshPingFnc: testRefreshPingFnc,
      refreshQueryTimeout: Duration(seconds: 5),
      refreshInterval: Duration(minutes: 1),
      successfulOutboundQueryGracePeriod: Duration(seconds: 30),
    );
    refreshManager.start(); // Start the manager so it listens to refresh requests
    
    print('--- Running Refresh Scenario: ignoreCpl=$ignoreCpl ---');
    await refreshManager.refresh(true);

    for (var cpl = 0; cpl < maxCplQueryForTest; cpl++) {
      final expectedCount = expectedPeersPerCplAfterRefresh[cpl] ?? 0;
      final actualCount = await rt.nPeersForCpl(cpl);

      // Adjust assertion if this CPL had a manually added peer
      int effectiveExpectedCount = expectedCount;
      if (cpl == manuallyAddedPeerCpl && manuallyAddedPeerCpl < (KadID.fromPeerId(localId).bytes.length * 8)) {
        // If refresh was also supposed to add a peer here (expectedCount > 0),
        // then total is expectedCount + 1 (manual).
        // If refresh was not (expectedCount == 0, e.g. it was ignoreCpl or beyond gap limit),
        // then total is 1 (manual).
        effectiveExpectedCount = (expectedCount > 0) ? expectedCount + 1 : 1;
      }
      
      expect(actualCount, effectiveExpectedCount,
          reason: 'CPL $cpl: Expected $effectiveExpectedCount, got $actualCount. (ignoreCpl=$ignoreCpl)');
    }

     if (manuallyAddedPeerCpl >= maxCplQueryForTest && manuallyAddedPeerCpl < (KadID.getKademliaIdBytes(localId).length * 8)) {
         int expectedCountForManualCpl;
         String reasonSuffix;

         if (ignoreCpl == 2) { // Case 1 specific logic for manuallyAddedPeerCpl = 10
            // CPL 10 is NOT refreshed by manager because gap at CPL 2 stops refresh after CPL 6.
            expectedCountForManualCpl = 1;
            reasonSuffix = "CPL 10 not refreshed by manager due to ignoreCpl=2 stopping early.";
         } else if (ignoreCpl == 6) { // Case 2 specific logic for manuallyAddedPeerCpl = 10
            // CPL 10 IS refreshed by manager because gap at CPL 6 leads to gap-fill up to CPL 10.
            expectedCountForManualCpl = 2;
            reasonSuffix = "CPL 10 was refreshed by manager during gap-fill for ignoreCpl=6.";
         } else {
            // Fallback for any other test cases, though current tests only use ignoreCpl 2 or 6.
            // Default to assuming it might be refreshed if not ignored.
            expectedCountForManualCpl = (manuallyAddedPeerCpl == ignoreCpl) ? 1 : 2;
            reasonSuffix = (manuallyAddedPeerCpl == ignoreCpl) ? "CPL 10 was ignoreCpl." : "CPL 10 was not ignoreCpl (fallback logic).";
         }
        
         expect(await rt.nPeersForCpl(manuallyAddedPeerCpl), expectedCountForManualCpl,
          reason: 'Peers at manuallyAddedPeerCpl $manuallyAddedPeerCpl (outside assert loop) should be $expectedCountForManualCpl. ignoreCpl was $ignoreCpl. $reasonSuffix');
      }
    print('--- Finished Refresh Scenario: ignoreCpl=$ignoreCpl ---');
  }

  group('RtRefreshManager Tests for local implementation', () { // Group was already defined, remove nesting
    test('skip refresh on gap CPLs - Case 1 (ignoreCpl=2)', () async {
      await runRefreshTestScenario(
        ignoreCpl: 2,
        expectedPeersPerCplAfterRefresh: {
          0: 1, 1: 1,
          2: 0, 
          3: 1, 4: 1, 5: 1, 6: 1, 
          7: 0, 8: 0, 9: 0, 
        },
        manuallyAddedPeerCpl: maxCplQueryForTest, 
      );
    });

    test('skip refresh on gap CPLs - Case 2 (ignoreCpl=6)', () async {
      await runRefreshTestScenario(
        ignoreCpl: 6,
        expectedPeersPerCplAfterRefresh: {
          0: 1, 1: 1, 2: 1, 3: 1, 4: 1, 5: 1,
          6: 0, 
          7: 1, 8: 1, 9: 1, 
        },
        manuallyAddedPeerCpl: maxCplQueryForTest,
      );
    });
  });
}
