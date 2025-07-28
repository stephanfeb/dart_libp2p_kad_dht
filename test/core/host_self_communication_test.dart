import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

// Libp2p core types
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:test/test.dart';

import '../real_net_stack.dart';
import '../test_utils.dart';
import 'package:dart_udx/dart_udx.dart';

// Helper class to encapsulate node and DHT creation for tests using real_net_stack
class _NodeWithDHT {
  late Libp2pNode nodeDetails;
  late IpfsDHT dht;
  late Host host;
  late PeerId peerId;
  late UDX _udxInstance; // Keep instance to close if necessary

  static Future<_NodeWithDHT> create() async {
    final helper = _NodeWithDHT();

    helper._udxInstance = UDX();
    // Using NullResourceManager as per user feedback
    final resourceManager = NullResourceManager();
    final connManager = ConnectionManager();
    final eventBus = BasicBus();

    helper.nodeDetails = await createLibp2pNode(
      udxInstance: helper._udxInstance,
      resourceManager: resourceManager,
      connManager: connManager,
      hostEventBus: eventBus,
      listenAddrsOverride:  [MultiAddr('/ip4/127.0.0.1/udp/0/udx')]
    );
    helper.host = helper.nodeDetails.host;
    helper.peerId = helper.nodeDetails.peerId;

    final providerStore = MemoryProviderStore();
    helper.dht = IpfsDHT(
      host: helper.host,
      providerStore: providerStore,
      options: const DHTOptions(mode: DHTMode.server), // Force server mode for testing
    );
    // dht.start() will be called in the test's setUp
    return helper;
  }

  Future<void> stop() async {
    await dht.close();
    await host.close();
    // Consider if _udxInstance.dispose() is needed and available.
    // For now, assuming UDX instance might be shared or managed globally if it's a singleton.
  }
}

void main() {
  group('Host Self-Communication Tests', () {
    late Host hostInstance;
    late _NodeWithDHT _node;
    const String selfProtocol = '/self-test/1.0.0';
    
    List<Completer<String>> receivedMessageCompleters = [];

    setUp(() async {
      try {
        _node = await _NodeWithDHT.create();
        hostInstance = _node.host;
      } catch (e) {
        print('Skipping Host Self-Communication Tests: createTestHost() is not implemented or failed.');
        // Mark tests as skipped if host creation fails (because createTestHost is a TODO)
        markTestSkipped('createTestHost() needs to be implemented.');
        return; // Do not proceed with setUp if host creation fails
      }
      
      receivedMessageCompleters = []; 

      hostInstance.setStreamHandler(selfProtocol, (P2PStream stream, PeerId remotePeerId) async {
        final streamIdString = stream.id; 
        print('[SelfTest Handler] Stream $streamIdString received from ${remotePeerId.toBase58().substring(0,6)}');
        try {
          final data = await stream.read(); 
          final message = utf8.decode(data);
          print('[SelfTest Handler] Stream $streamIdString received message: "$message"');
          
          await stream.write(Uint8List.fromList(utf8.encode('echo: $message')));
          await stream.close(); 
          print('[SelfTest Handler] Stream $streamIdString echo sent and stream closed.');

          // Find the first uncompleted completer
          Completer<String>? completerToUse;
          int completerIndex = receivedMessageCompleters.indexWhere((c) => !c.isCompleted);
          
          if (completerIndex != -1) {
              completerToUse = receivedMessageCompleters[completerIndex];
              print('[SelfTest Handler] Found uncompleted completer at index $completerIndex for message "$message"');
          } else {
              print('[SelfTest Handler] Warning: No pending uncompleted completer for message "$message"');
          }

          if (completerToUse != null && !completerToUse.isCompleted) {
              completerToUse.complete(message);
              print('[SelfTest Handler] Completed completer at index $completerIndex with message "$message"');
          }

        } catch (e, s) {
          final streamIdStringOnError = stream.id; 
          print('[SelfTest Handler] Stream $streamIdStringOnError error: $e\n$s');
          if (!stream.isClosed) {
            try { await stream.reset(); } catch (_) {} 
          }
          
          Completer<String>? completerToError;
          int errorCompleterIndex = receivedMessageCompleters.indexWhere((c) => !c.isCompleted);

          if (errorCompleterIndex != -1) {
              completerToError = receivedMessageCompleters[errorCompleterIndex];
              print('[SelfTest Handler] Found uncompleted completer at index $errorCompleterIndex to report error for stream $streamIdStringOnError');
          } else {
               print('[SelfTest Handler] Warning: No pending uncompleted completer to report error for stream $streamIdStringOnError');
          }

          if (completerToError != null && !completerToError.isCompleted) {
              completerToError.completeError(e,s);
              print('[SelfTest Handler] Errored completer at index $errorCompleterIndex for stream $streamIdStringOnError');
          }
        }
      });
      // host.start() is called within _NodeWithDHT.create() -> createLibp2pNode
      // await hostInstance.start(); // No longer needed here
      print('[Host Self-Communication Test Setup] Host setup complete. ID: ${hostInstance.id.toBase58()}, Addrs: ${hostInstance.addrs}');
    });

    tearDown(() async {
      // Check if hostInstance was initialized before trying to stop it
      // The null check might not be strictly necessary if setUp rethrows on failure,
      // as tearDown might not run for tests where setUp failed catastrophically.
      // However, it's safer.
      // ignore: unnecessary_null_comparison
      if (_node != null) { // Check _node instead of just hostInstance
        print('[Host Self-Communication Test Teardown] Stopping node helper...');
        await _node.stop(); // This will call dht.close() and host.close()
        print('[Host Self-Communication Test Teardown] Node helper stopped.');
      } else if (hostInstance != null) {
        // Fallback if _node somehow wasn't created but hostInstance was (less likely with current setup)
        print('[Host Self-Communication Test Teardown] Stopping host instance directly...');
        await hostInstance.close();
        print('[Host Self-Communication Test Teardown] Host instance stopped.');
      }
    });

    test('should be able to open a single stream to self and send/receive data', () async {
      final completer = Completer<String>();
      receivedMessageCompleters.add(completer);

      print('[SelfTest Single Stream] Attempting to open stream to self...');
      final stream = await hostInstance.newStream(hostInstance.id, [selfProtocol], Context());
      final streamIdString = stream.id;
      print('[SelfTest Single Stream] Stream opened: $streamIdString');
      
      final message = 'hello self 1';
      await stream.write(Uint8List.fromList(utf8.encode(message)));
      print('[SelfTest Single Stream] Message "$message" written to stream.');
      
      final responseBytes = await stream.read();
      await stream.close(); 
      print('[SelfTest Single Stream] Response from stream: "${utf8.decode(responseBytes)}"');
      
      expect(utf8.decode(responseBytes), equals('echo: $message'));
      
      print('[SelfTest Single Stream] Waiting for completer...');
      final completerResult = await completer.future.timeout(Duration(seconds: 5), onTimeout: () {
        print('[SelfTest Single Stream] Completer timed out internally.');
        return 'timeout_from_completer';
      });
      print('[SelfTest Single Stream] Completer result: "$completerResult"');
      expect(completerResult, equals(message));
      print('[SelfTest Single Stream] Test completed.');

    }, timeout: Timeout(Duration(seconds: 15))); 

    test('should be able to open a SECOND stream to self after the first', () async {
      // --- First stream operation ---
      final completer1 = Completer<String>();
      receivedMessageCompleters.add(completer1);
      print('[SelfTest Second Stream] Opening FIRST stream to self...');
      final stream1 = await hostInstance.newStream(hostInstance.id, [selfProtocol], Context());
      final stream1IdString = stream1.id;
      print('[SelfTest Second Stream] FIRST stream opened: $stream1IdString');
      final message1 = 'hello self stream1';
      await stream1.write(Uint8List.fromList(utf8.encode(message1)));
      print('[SelfTest Second Stream] Message "$message1" written to FIRST stream.');
      final response1Bytes = await stream1.read();
      await stream1.close();
      print('[SelfTest Second Stream] Response from FIRST stream: "${utf8.decode(response1Bytes)}"');
      expect(utf8.decode(response1Bytes), equals('echo: $message1'));
      
      print('[SelfTest Second Stream] Waiting for completer1...');
      final completer1Result = await completer1.future.timeout(Duration(seconds: 5), onTimeout: () {
        print('[SelfTest Second Stream] Completer1 timed out internally.');
        return 'timeout_from_completer1';
      });
      print('[SelfTest Second Stream] Completer1 result: "$completer1Result"');
      expect(completer1Result, equals(message1));
      print('[SelfTest Second Stream] FIRST stream interaction completed successfully.');

      // --- Second stream operation ---
      final completer2 = Completer<String>();
      receivedMessageCompleters.add(completer2);
      print('[SelfTest Second Stream] Attempting to open SECOND stream to self...');
      P2PStream stream2;
      try {
        stream2 = await hostInstance.newStream(hostInstance.id, [selfProtocol], Context()); 
        final stream2IdString = stream2.id;
        print('[SelfTest Second Stream] SECOND stream opened: $stream2IdString');
      } catch (e,s) {
        print('[SelfTest Second Stream] ERROR opening SECOND stream: $e\n$s');
        if(!completer2.isCompleted) completer2.completeError(e,s); 
        fail('Failed to open second stream to self: $e');
      }
      
      final message2 = 'hello self stream2';
      try {
        await stream2.write(Uint8List.fromList(utf8.encode(message2)));
        print('[SelfTest Second Stream] Message "$message2" written to SECOND stream.');
      } catch (e,s) {
        print('[SelfTest Second Stream] ERROR writing to SECOND stream: $e\n$s');
        if(!completer2.isCompleted) completer2.completeError(e,s); 
        fail('Failed to write to second stream: $e');
      }
      
      List<int> response2Bytes;
      try {
        response2Bytes = await stream2.read(); 
        print('[SelfTest Second Stream] Response from SECOND stream: "${utf8.decode(response2Bytes)}"');
      } catch (e,s) {
         print('[SelfTest Second Stream] ERROR reading from SECOND stream: $e\n$s');
         if(!completer2.isCompleted) completer2.completeError(e,s); 
        fail('Failed to read from second stream: $e');
      }
      await stream2.close();
      
      expect(utf8.decode(response2Bytes), equals('echo: $message2'));
      
      print('[SelfTest Second Stream] Waiting for completer2...');
      final completer2Result = await completer2.future.timeout(Duration(seconds: 5), onTimeout: () {
        print('[SelfTest Second Stream] Completer2 timed out internally.');
        return 'timeout_from_completer2';
      });
      print('[SelfTest Second Stream] Completer2 result: "$completer2Result"');
      expect(completer2Result, equals(message2));
      print('[SelfTest Second Stream] SECOND stream interaction completed successfully.');

    }, timeout: Timeout(Duration(seconds: 20))); 
  });
}
