/// A Dart implementation of the libp2p Kademlia DHT.
///
/// This library provides a Dart implementation of the Kademlia Distributed Hash Table (DHT)
/// for the libp2p network stack, based on the go-libp2p-kad-dht implementation.
library dart_libp2p_kad_dht;

// Core interfaces

// Protocol buffer definitions
export 'src/pb/record.dart';
export 'src/pb/dht_message.dart';

// Protocol constants
export 'src/amino/defaults.dart';

// Provider management
export 'src/providers/provider_store.dart';
export 'src/providers/provider_set.dart';
export 'src/providers/provider_manager.dart';

// Query implementation
export 'src/query/qpeerset.dart';
export 'src/query/query_runner.dart';
export 'src/query/legacy_types.dart';

// DHT implementation
export 'src/dht/dht.dart';
export 'src/dht/dht_options.dart';
export 'src/dht/handlers.dart';
export 'src/dht/dht_bootstrap.dart';
export 'src/dht/dht_filters.dart';

export 'src/dht/v2/dht_v2.dart';
