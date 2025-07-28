import 'dart:async';
import 'dart:io' as io; // Renamed to avoid conflict with top-level `exit`
import 'dart:io'; // For ProcessSignal and exit (though aliased io.exit is preferred)
import 'dart:typed_data';
import 'dart:math';
import 'package:yaml/yaml.dart'; // Added for YAML parsing

import 'package:args/args.dart';
import 'package:dart_udx/dart_udx.dart';

import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/network/stream.dart' as core_network_stream;
import 'package:dart_libp2p/core/network/context.dart' as core_context;
import 'package:dart_libp2p/core/peer/addr_info.dart'; // Added for DHT
import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_manager;
import 'package:dart_libp2p/p2p/multiaddr/protocol.dart';

// DHT Imports
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';


const String PING_PROTOCOL_ID = '/dart-libp2p/example-ping/udx/1.0.0';

String shortPeerId(PeerId id) {
  final s = id.toString();
  if (s.length > 16) {
    return '${s.substring(0, 6)}...${s.substring(s.length - 6)}';
  }
  return s;
}

Future<void> main(List<String> arguments) async {
  final shutdownCompleter = Completer<void>();

  // Setup logging (optional)
  // Logger.root.level = Level.INFO;
  // Logger.root.onRecord.listen((record) {
  //   print('${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
  //   if (record.error != null) print('  ERROR: ${record.error}');
  //   if (record.stackTrace != null) print('  STACKTRACE: ${record.stackTrace}');
  // });

  final parser = ArgParser()
    ..addOption('config', abbr: 'c', help: 'Path to YAML configuration file.')
    ..addOption('listen', abbr: 'l', help: 'Listen multiaddress (e.g., /ip4/0.0.0.0/udp/0/udx)')
    ..addOption('target', abbr: 't', help: 'Target peer multiaddress (e.g., /ip4/127.0.0.1/udp/12345/udx/p2p/QmPeerId)')
    ..addOption('target-peer-id', help: 'Target peer ID (will use DHT to find address)')
    ..addOption('bootstrap-peers', help: 'Comma-separated list of bootstrap peer multiaddresses (e.g., /ip4/1.2.3.4/udp/1234/udx/p2p/QmId1,/ip4/...)')
    ..addOption('interval', abbr: 'i', help: 'Interval between pings in seconds', defaultsTo: '1') // Default will be handled carefully with precedence
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Display this help message.');

  ArgResults results;
  try {
    results = parser.parse(arguments);
  } catch (e) {
    print('Error parsing arguments: $e');
    print(parser.usage);
    io.exit(1);
  }

  if (results['help'] as bool) {
    print('Dart libp2p UDX Ping Application with DHT');
    print(parser.usage);
    io.exit(0); // Using aliased exit
  }

  String earlyLogPrefix = "PingApp"; // For logs before hostIdForLog is available

  // Load config from YAML file if specified
  Map<String, dynamic> configFromFile = {};
  final configFile = results['config'] as String?;
  if (configFile != null) {
    try {
      final fileContents = await io.File(configFile).readAsString();
      final yamlMap = loadYaml(fileContents) as YamlMap?;
      if (yamlMap != null) {
        // Convert YamlMap to Map<String, dynamic> for easier access
        configFromFile = yamlMap.map((key, value) => MapEntry(key.toString(), value));
        print('[$earlyLogPrefix] Loaded configuration from $configFile');
      }
    } catch (e) {
      print('[$earlyLogPrefix] Warning: Could not read or parse config file $configFile: $e');
      // Continue without file config, or exit if critical
    }
  }

  // Determine configuration values with precedence: CLI > YAML > Default
  // Helper function to get config value
  T getConfigValue<T>(String cliKey, String yamlKey, T defaultValue, {T Function(dynamic)? parser}) {
    if (results.wasParsed(cliKey)) {
      dynamic cliValue = results[cliKey];
      if (parser != null) return parser(cliValue);
      return cliValue as T;
    }
    if (configFromFile.containsKey(yamlKey)) {
      dynamic yamlValue = configFromFile[yamlKey];
      if (parser != null) return parser(yamlValue);
      // Be careful with type casting from YAML, especially for lists or complex types
      if (yamlValue is T) return yamlValue;
      if (T == String && yamlValue != null) return yamlValue.toString() as T;
      if (T == int && yamlValue is num) return yamlValue.toInt() as T;
      if (T == bool && yamlValue is bool) return yamlValue as T;
      // Add more specific type handling if needed
      print('[$earlyLogPrefix] Warning: Config value for $yamlKey has unexpected type. Using default.'); // Use earlyLogPrefix
      return defaultValue;
    }
    return defaultValue;
  }

  final listenAddrStr = getConfigValue<String?>('listen', 'listen', null);
  final targetAddrStr = getConfigValue<String?>('target', 'target', null);
  final targetPeerIdStrFromArg = getConfigValue<String?>('target-peer-id', 'target_peer_id', null);
  
  // Bootstrap peers need special handling for list and comma-separated string
  List<String> bootstrapPeerStrings = [];
  if (results.wasParsed('bootstrap-peers')) {
    final cliBootstrap = results['bootstrap-peers'] as String?;
    if (cliBootstrap != null && cliBootstrap.isNotEmpty) {
      bootstrapPeerStrings.addAll(cliBootstrap.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty));
    }
  } else if (configFromFile.containsKey('bootstrap_peers')) {
    final yamlBootstrap = configFromFile['bootstrap_peers'];
    if (yamlBootstrap is YamlList) {
      bootstrapPeerStrings.addAll(yamlBootstrap.map((dynamic item) => item.toString().trim()).where((s) => s.isNotEmpty));
    } else if (yamlBootstrap is String && yamlBootstrap.isNotEmpty) {
      bootstrapPeerStrings.addAll(yamlBootstrap.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty));
    }
  }

  final pingIntervalSec = getConfigValue<int>('interval', 'interval', 1, parser: (val) {
    if (val is String) return int.tryParse(val) ?? 1;
    if (val is num) return val.toInt();
    return 1;
  });


  if (listenAddrStr == null && targetAddrStr == null && targetPeerIdStrFromArg == null) {
    print('Error: You must specify a listen address, a target peer multiaddress, or a target peer ID (via CLI or config file).');
    print(parser.usage);
    io.exit(1);
  }

  final udxInstance = UDX();
  final localKeyPair = await crypto_ed25519.generateEd25519KeyPair();
  final connManager = p2p_conn_manager.ConnectionManager();

  Host? host;
  IpfsDHT? dht;
  ProviderStore? providerStore;

  try {
    final options = <p2p_config.Option>[
      p2p_config.Libp2p.identity(localKeyPair),
      p2p_config.Libp2p.connManager(connManager),
      p2p_config.Libp2p.transport(UDXTransport(connManager: connManager, udxInstance: udxInstance)),
      p2p_config.Libp2p.security(await NoiseSecurity.create(localKeyPair)),
    ];

    if (listenAddrStr != null) {
      try {
        options.add(p2p_config.Libp2p.listenAddrs([MultiAddr(listenAddrStr)]));
      } catch (e) {
        print('Error parsing listen address "$listenAddrStr": $e');
        io.exit(1); // Using aliased exit
      }
    }

    host = await p2p_config.Libp2p.new_(options);
    await host.start();

    final hostIdForLog = shortPeerId(host.id);
    final fullHostId = host.id.toString();

    print('[$hostIdForLog] Host ID: $fullHostId');
    if (host.addrs.isNotEmpty) {
      print('[$hostIdForLog] Listening on:');
      for (var addr in host.addrs) {
        print('  $addr/p2p/$fullHostId');
      }
      print('[$hostIdForLog] Use one of the above full addresses (including /p2p/...) as the target for another instance.');
    } else {
      print('[$hostIdForLog] Not actively listening on a predefined address. (This is okay if only targeting another peer).');
    }

    // Initialize DHT
    print('[$hostIdForLog] Initializing DHT...');
    providerStore = MemoryProviderStore();

    List<MultiAddr> bootstrapMultiAddrs = [];
    if (bootstrapPeerStrings.isNotEmpty) {
      for (final addrStr in bootstrapPeerStrings) {
        try {
          bootstrapMultiAddrs.add(MultiAddr(addrStr));
        } catch (e) {
          print('[$hostIdForLog] Warning: Could not parse bootstrap peer multiaddress: $addrStr. Error: $e');
        }
      }
      if (bootstrapMultiAddrs.isNotEmpty) {
        print('[$hostIdForLog] Using effective bootstrap peers: $bootstrapMultiAddrs');
      }
    }

    dht = IpfsDHT(
      host: host,
      providerStore: providerStore,
      options: DHTOptions(
        mode: DHTMode.server, // This could also be made configurable
        bootstrapPeers: bootstrapMultiAddrs.isNotEmpty ? bootstrapMultiAddrs : null,
      ),
    );
    await dht.start();
    print('[$hostIdForLog] DHT started. Bootstrapping...');
    await dht.bootstrap();
    print('[$hostIdForLog] DHT bootstrapped.');

    host.setStreamHandler(PING_PROTOCOL_ID, (stream, remotePeer) async {
      final currentHostLogId = shortPeerId(host!.id);
      final remotePeerLogId = shortPeerId(remotePeer);
      print('[$currentHostLogId] Received ping from $remotePeerLogId on stream ${stream.id()} for protocol ${stream.protocol()}');
      try {
        final data = await stream.read().timeout(Duration(seconds: 10));
        print('[$currentHostLogId] Ping data received (${data.length} bytes) from $remotePeerLogId.');
        await stream.write(data);
        print('[$currentHostLogId] Pong sent to $remotePeerLogId.');
      } catch (e, s) {
        print('[$currentHostLogId] Error in ping handler for $remotePeerLogId: $e\n$s');
        await stream.reset();
      } finally {
        if (!stream.isClosed) {
          await stream.close();
        }
        print('[$currentHostLogId] Closed stream with $remotePeerLogId.');
      }
    });

    PeerId? targetPeerIdForPing; // This will hold the PeerId we intend to ping
    final currentHostLogId = shortPeerId(host.id);

    if (targetPeerIdStrFromArg != null) {
      print('[$currentHostLogId] Target Peer ID provided: $targetPeerIdStrFromArg. Attempting to find via DHT...');
      try {
        targetPeerIdForPing = PeerId.fromString(targetPeerIdStrFromArg);
        AddrInfo? dhtFoundAddrInfo = await dht.findPeer(targetPeerIdForPing);

        if (dhtFoundAddrInfo != null && dhtFoundAddrInfo.addrs.isNotEmpty) {
          print('[$currentHostLogId] Found peer $targetPeerIdForPing via DHT at ${dhtFoundAddrInfo.addrs}. Adding to peerstore.');
          host.peerStore.addrBook.addAddrs(targetPeerIdForPing, dhtFoundAddrInfo.addrs, Duration(hours: 1));
        } else {
          print('[$currentHostLogId] Could not find peer $targetPeerIdForPing via DHT or it has no addresses. Exiting.');
          io.exit(1);
        }
      } catch (e) {
        print('[$currentHostLogId] Error processing target Peer ID "$targetPeerIdStrFromArg": $e');
        io.exit(1);
      }
    } else if (targetAddrStr != null) {
      print('[$currentHostLogId] Target Multiaddress provided: $targetAddrStr.');
      MultiAddr targetMa;
      try {
        targetMa = MultiAddr(targetAddrStr);
      } catch (e) {
        print('[$currentHostLogId] Error parsing target address "$targetAddrStr": $e');
        io.exit(1);
      }

      final p2pComponent = targetMa.valueForProtocol(Protocols.p2p.name);
      if (p2pComponent == null) {
        print('[$currentHostLogId] Error: Target multiaddress "$targetAddrStr" must include a /p2p/<peer-id> component.');
        io.exit(1);
      }
      try {
        targetPeerIdForPing = PeerId.fromString(p2pComponent);
      } catch (e) {
         print('[$currentHostLogId] Error parsing PeerId from "$p2pComponent" in target multiaddress: $e');
         io.exit(1);
      }
      
      final connectAddr = targetMa.decapsulate(Protocols.p2p.name);
      if (connectAddr != null && connectAddr.toString().isNotEmpty) { // Ensure connectAddr is not empty
        host.peerStore.addrBook.addAddrs(targetPeerIdForPing, [connectAddr], Duration(hours: 1));
        print('[$currentHostLogId] Added ${shortPeerId(targetPeerIdForPing)} ($connectAddr) to peerstore from multiaddress.');
      } else {
        print('[$currentHostLogId] Could not decapsulate /p2p component from $targetMa to get a valid connection address, or no address part remains. Will rely on DHT or existing peerstore info for $targetPeerIdForPing.');
        // If we only have a PeerID from the multiaddr but no actual transport address part,
        // we might try a DHT lookup as a fallback if not already done.
        // For now, we assume newStream can handle it if the peer is already known or discoverable.
      }
    }

    if (targetPeerIdForPing != null) {
      // Attempt hole punch once before starting the ping loop
      final hps = host.holePunchService;
      if (hps != null) {
        print('[$currentHostLogId] Attempting initial hole punch to ${shortPeerId(targetPeerIdForPing)}...');
        try {
          await hps.directConnect(targetPeerIdForPing).timeout(Duration(seconds: 20));
          print('[$currentHostLogId] Initial hole punch attempt to ${shortPeerId(targetPeerIdForPing)} completed.');
        } catch (e, s) {
          print('[$currentHostLogId] Initial hole punch attempt to ${shortPeerId(targetPeerIdForPing)} failed: $e');
          if (s != null) print(s);
        }
      }

      int pingAttempt = 0;
      while (true) {
        pingAttempt++;
        final remotePeerLogId = shortPeerId(targetPeerIdForPing);
        print('[$currentHostLogId] Pinging $remotePeerLogId (attempt $pingAttempt)...');
        
        final startTime = DateTime.now();
        core_network_stream.P2PStream? clientStream;

        try {
          clientStream = await host.newStream(
            targetPeerIdForPing,
            [PING_PROTOCOL_ID],
            core_context.Context(),
          ).timeout(Duration(seconds: 15));
          print('[$currentHostLogId] Opened stream ${clientStream.id()} to $remotePeerLogId for protocol ${clientStream.protocol()}');

          final payload = Uint8List.fromList(List.generate(32, (_) => Random().nextInt(256)));
          await clientStream.write(payload);
          print('[$currentHostLogId] Sent ${payload.length} byte ping to $remotePeerLogId.');

          final pongData = await clientStream.read().timeout(Duration(seconds: 10));
          final rtt = DateTime.now().difference(startTime);
          print('[$currentHostLogId] Received ${pongData.length} byte pong from $remotePeerLogId in ${rtt.inMilliseconds}ms.');

          bool success = pongData.lengthInBytes == payload.lengthInBytes;
          if (success) {
            for(int k=0; k < payload.length; k++) {
              if (payload[k] != pongData[k]) {
                success = false;
                break;
              }
            }
          }
          if (!success) {
            print('[$currentHostLogId] Pong payload mismatch!');
          }

        } catch (e,s) {
          print('[$currentHostLogId] Ping to $remotePeerLogId failed: $e');
          if (s != null) print(s);
        } finally {
          if (clientStream != null && !clientStream.isClosed) {
            await clientStream.close();
          }
        }
        await Future.delayed(Duration(seconds: pingIntervalSec));
      }
    } else if (listenAddrStr != null) {
      print('[$currentHostLogId] Listening for pings. Press Ctrl+C to exit.');
    } else {
      // This case should ideally not be reached due to earlier checks,
      // but as a safeguard if only --listen was provided and it failed to parse,
      // or if neither listen nor any target was specified.
      print('[$currentHostLogId] No target to ping and not listening. Exiting.');
      io.exit(0);
    }

    // If we are listening OR pinging, we need to wait for SIGINT.
    if (listenAddrStr != null || targetPeerIdForPing != null) {
        ProcessSignal.sigint.watch().listen((signal) async {
            final currentHostLogIdForSig = host != null ? shortPeerId(host!.id) : "Host";
            print('\n[$currentHostLogIdForSig] SIGINT received, shutting down...');
            if (!shutdownCompleter.isCompleted) {
              shutdownCompleter.complete();
            }
        });

        if (targetPeerIdForPing != null && listenAddrStr == null) {
             print('[$currentHostLogId] Continuously pinging target. Press Ctrl+C to exit.');
        } else if (listenAddrStr != null && targetPeerIdForPing != null) {
            print('[$currentHostLogId] Listening and continuously pinging target. Press Ctrl+C to exit.');
        }
        // If only listenAddrStr is set, message is already printed.
        
        await shutdownCompleter.future;
    }

  } catch (e, s) {
    print('An unexpected error occurred: $e');
    print(s);
    io.exit(1);
  } finally {
    final String finalHostId = host != null ? shortPeerId(host.id) : "Host";
    print('\n[$finalHostId] Initiating final shutdown sequence...');

    if (dht != null) {
      await dht.close();
      print('[$finalHostId] DHT closed.');
    }
    if (providerStore != null) {
      await providerStore.close();
      print('[$finalHostId] ProviderStore closed.');
    }
    if (host != null) {
      await host.close();
      print('[$finalHostId] Host closed.');
    }
    
    await connManager.dispose();
    print('[$finalHostId] Connection manager disposed.');

    print('[$finalHostId] Application shutdown complete.');
  }
}
