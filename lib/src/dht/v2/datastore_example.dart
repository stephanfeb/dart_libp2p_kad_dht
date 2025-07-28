import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:logging/logging.dart';

import '../dht_options.dart';
import '../../providers/provider_store.dart';
import '../../pb/record.dart';
import '../../record/record_signer.dart';
import 'dht_v2.dart';
import 'config/dht_config.dart';

/// Example demonstrating the complete datastore functionality in DHT v2
/// 
/// This example shows:
/// - Local record storage and retrieval
/// - Cryptographic record validation
/// - Network-integrated datastore operations
/// - Distributed value storage with validation
/// - Datastore health monitoring and statistics
void main() async {
  // Setup logging
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  print('=== DHT v2 Complete Datastore Examples ===\n');

  // Example 1: Local Datastore Operations
  await _localDatastoreExample();
  
  // Example 2: Cryptographic Record Validation
  await _recordValidationExample();
  
  // Example 3: Network-Integrated Datastore
  await _networkDatastoreExample();
  
  // Example 4: Datastore Health Monitoring
  await _datastoreMonitoringExample();
}

/// Example 1: Local Datastore Operations
Future<void> _localDatastoreExample() async {
  print('Example 1: Local Datastore Operations');
  print('------------------------------------');
  
  try {
    // Create a mock host (in real usage, this would be your libp2p host)
    final host = await _createMockHost();
    final providerStore = MemoryProviderStore();
    
    // Create DHT with datastore capabilities
    final dht = IpfsDHTv2(
      host: host,
      providerStore: providerStore,
      options: DHTOptions(
        mode: DHTMode.server,
        bucketSize: 20,
        filterLocalhostInResponses: false,
      ),
    );
    
    await dht.start();
    print('✓ DHT started successfully');
    
    // Create a signed record
    final privateKey = await _createMockPrivateKey();
    final testRecord = await RecordSigner.createSignedRecord(
      key: 'test-key',
      value: utf8.encode('Hello, DHT v2 Datastore!'),
      privateKey: privateKey,
      peerId: host.id,
    );
    
    // Store record in datastore
    await dht.putRecordToDatastore(testRecord);
    print('✓ Record stored in local datastore');
    
    // Check if record exists
    final hasRecord = await dht.hasRecordInDatastore('test-key');
    print('✓ Record exists in datastore: $hasRecord');
    
    // Retrieve record from datastore
    final retrievedRecord = await dht.getRecordFromDatastore('test-key');
    if (retrievedRecord != null) {
      final value = utf8.decode(retrievedRecord.value);
      print('✓ Retrieved record value: $value');
    }
    
    // List all keys
    final keys = <String>[];
    await for (final key in dht.getKeysFromDatastore()) {
      keys.add(key);
    }
    print('✓ Datastore contains ${keys.length} keys: ${keys.join(', ')}');
    
    // Remove record
    await dht.removeRecordFromDatastore('test-key');
    print('✓ Record removed from datastore');
    
    // Verify removal
    final hasRecordAfterRemoval = await dht.hasRecordInDatastore('test-key');
    print('✓ Record exists after removal: $hasRecordAfterRemoval');
    
    await dht.close();
    print('✓ DHT closed successfully\n');
    
  } catch (e) {
    print('✗ Error: $e\n');
  }
}

/// Example 2: Cryptographic Record Validation
Future<void> _recordValidationExample() async {
  print('Example 2: Cryptographic Record Validation');
  print('------------------------------------------');
  
  try {
    final host = await _createMockHost();
    final providerStore = MemoryProviderStore();
    
    final dht = IpfsDHTv2(
      host: host,
      providerStore: providerStore,
      options: DHTOptions(mode: DHTMode.server),
    );
    
    await dht.start();
    print('✓ DHT started for validation testing');
    
    // Create valid signed record
    final privateKey = await _createMockPrivateKey();
    final validRecord = await RecordSigner.createSignedRecord(
      key: 'valid-key',
      value: utf8.encode('Valid signed content'),
      privateKey: privateKey,
      peerId: host.id,
    );
    
    // Validate record signature
    final isValid = await RecordSigner.validateRecordSignature(validRecord);
    print('✓ Record signature validation: $isValid');
    
    // Store valid record
    await dht.putRecordToDatastore(validRecord);
    print('✓ Valid record stored successfully');
    
    // Try to store invalid record (should fail)
    final invalidRecord = Record(
      key: utf8.encode('invalid-key'),
      value: utf8.encode('Invalid content'),
      timeReceived: DateTime.now().millisecondsSinceEpoch,
      author: host.id.toBytes(),
      signature: Uint8List.fromList([1, 2, 3, 4]), // Invalid signature
    );
    
    try {
      await dht.putRecordToDatastore(invalidRecord);
      print('✗ Invalid record was stored (should have failed)');
    } catch (e) {
      print('✓ Invalid record rejected: ${e.toString().split(':').first}');
    }
    
    // Verify only valid record is in datastore
    final hasValid = await dht.hasRecordInDatastore('valid-key');
    final hasInvalid = await dht.hasRecordInDatastore('invalid-key');
    print('✓ Valid record exists: $hasValid, Invalid record exists: $hasInvalid');
    
    await dht.close();
    print('✓ DHT closed successfully\n');
    
  } catch (e) {
    print('✗ Error: $e\n');
  }
}

/// Example 3: Network-Integrated Datastore
Future<void> _networkDatastoreExample() async {
  print('Example 3: Network-Integrated Datastore');
  print('---------------------------------------');
  
  try {
    final host = await _createMockHost();
    final providerStore = MemoryProviderStore();
    
    final dht = IpfsDHTv2(
      host: host,
      providerStore: providerStore,
      options: DHTOptions(
        mode: DHTMode.server,
        bucketSize: 20,
        resiliency: 3,
      ),
    );
    
    await dht.start();
    print('✓ DHT started for network integration');
    
    // Test network-integrated getValue/putValue operations
    final testKey = 'network-test-key';
    final testValue = utf8.encode('Network-integrated value');
    
    // Put value (creates signed record and stores both locally and on network)
    await dht.putValue(testKey, testValue);
    print('✓ Value stored through network-integrated putValue');
    
    // Check local datastore
    final hasLocal = await dht.hasRecordInDatastore(testKey);
    print('✓ Record exists in local datastore: $hasLocal');
    
    // Get value (retrieves from local datastore first, then network)
    final retrievedValue = await dht.getValue(testKey);
    if (retrievedValue != null) {
      final valueStr = utf8.decode(retrievedValue);
      print('✓ Retrieved value: $valueStr');
    }
    
    // Check local datastore contains the record
    final localRecord = await dht.checkLocalDatastore(utf8.encode(testKey));
    if (localRecord != null) {
      print('✓ Local datastore contains validated record');
      print('  - Record size: ${localRecord.value.length} bytes');
      print('  - Record timestamp: ${localRecord.timeReceived}');
      print('  - Record has signature: ${localRecord.signature.isNotEmpty}');
    }
    
    await dht.close();
    print('✓ DHT closed successfully\n');
    
  } catch (e) {
    print('✗ Error: $e\n');
  }
}

/// Example 4: Datastore Health Monitoring
Future<void> _datastoreMonitoringExample() async {
  print('Example 4: Datastore Health Monitoring');
  print('-------------------------------------');
  
  try {
    final host = await _createMockHost();
    final providerStore = MemoryProviderStore();
    
    final dht = IpfsDHTv2(
      host: host,
      providerStore: providerStore,
      options: DHTOptions(mode: DHTMode.server),
    );
    
    await dht.start();
    print('✓ DHT started for monitoring');
    
    // Access protocol manager for detailed datastore statistics
    // Note: In a real implementation, you would need a public getter for the protocol manager
    // For this example, we'll use the public DHT interface methods instead
    // final protocolManager = dht._protocol;
    
    // Add multiple test records
    final privateKey = await _createMockPrivateKey();
    
    for (int i = 0; i < 5; i++) {
      final record = await RecordSigner.createSignedRecord(
        key: 'monitoring-key-$i',
        value: utf8.encode('Test data $i - ${DateTime.now()}'),
        privateKey: privateKey,
        peerId: host.id,
      );
      
      await dht.putRecordToDatastore(record);
      print('  ✓ Stored record $i');
    }
    
    // List all keys from datastore
    final keys = <String>[];
    await for (final key in dht.getKeysFromDatastore()) {
      keys.add(key);
    }
    print('✓ Datastore contains ${keys.length} keys: ${keys.join(', ')}');
    
         // Show datastore usage
     var totalSize = 0;
     for (final key in keys) {
       final record = await dht.getRecordFromDatastore(key);
       if (record != null) {
         totalSize += record.value.length as int;
       }
     }
    print('✓ Total datastore size: $totalSize bytes across ${keys.length} records');
    
    // Test individual record operations
    for (final key in keys) {
      final hasRecord = await dht.hasRecordInDatastore(key);
      print('  ✓ Record $key exists: $hasRecord');
    }
    
    // Clean up - remove all test records
    for (final key in keys) {
      await dht.removeRecordFromDatastore(key);
    }
    
    // Verify cleanup
    final keysAfterCleanup = <String>[];
    await for (final key in dht.getKeysFromDatastore()) {
      keysAfterCleanup.add(key);
    }
    print('✓ Records after cleanup: ${keysAfterCleanup.length}');
    
    await dht.close();
    print('✓ DHT closed successfully\n');
    
  } catch (e) {
    print('✗ Error: $e\n');
  }
}

/// Creates a mock host for testing
Future<Host> _createMockHost() async {
  // In a real implementation, this would create a proper libp2p host
  // For this example, we'll create a mock that demonstrates the interface
  throw UnimplementedError('Mock host creation not implemented in this example');
}

/// Creates a mock private key for testing
Future<dynamic> _createMockPrivateKey() async {
  // In a real implementation, this would create a proper private key
  // For this example, we'll create a mock that demonstrates the interface
  throw UnimplementedError('Mock private key creation not implemented in this example');
}

/// Memory-based provider store for testing
class MemoryProviderStore implements ProviderStore {
  final Map<String, List<AddrInfo>> _providers = {};
  
  @override
  Future<void> addProvider(dynamic cid, AddrInfo provider) async {
    final key = cid.toString();
    _providers.putIfAbsent(key, () => []).add(provider);
  }
  
  @override
  Future<List<AddrInfo>> getProviders(dynamic cid) async {
    return _providers[cid.toString()] ?? [];
  }
  
  @override
  Future<void> removeProvider(dynamic cid, AddrInfo provider) async {
    final key = cid.toString();
    _providers[key]?.remove(provider);
  }
  
  @override
  Future<void> clear() async {
    _providers.clear();
  }
  
  @override
  Future<void> close() async {
    // No-op for memory store
  }
  
  @override
  Future<void> start() async {
    // No-op for memory store
  }
}

 