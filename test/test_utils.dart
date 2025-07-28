import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_libp2p/core/connmgr/conn_manager.dart';
import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/event/bus.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/interfaces.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peerstore.dart';
import 'package:dart_libp2p/p2p/discovery/peer_info.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart';
import 'package:dart_libp2p/p2p/host/host.dart';
import 'package:dart_libp2p/p2p/protocol/holepunch/holepunch_service.dart';
import 'package:dart_libp2p/p2p/protocol/multistream/multistream.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:dart_libp2p_kad_dht/src/kbucket/keyspace/kad_id.dart';
import 'package:dart_libp2p_kad_dht/src/pb/dht_message.dart' as pb;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

final Logger logger = Logger('TestUtils'); // General logger for the file

/// UTF-8 encoder for convenience
final utf8 = Utf8Codec();

/// Creates a host for testing, ensuring a unique PeerId among MockHosts
Future<Host> createMockHost() async {
  PeerId peerId;
  KeyPair keyPair;
  int attempts = 0;
  do {
    // Generate a key pair and derive PeerId from the public key
    keyPair = await crypto_ed25519.generateEd25519KeyPair();
    peerId = await PeerId.fromPublicKey(keyPair.publicKey);
    attempts++;
    if (attempts > 10 && MockHost._allHosts.containsKey(peerId)) {
      // After 10 attempts, if still colliding (highly unlikely with real random PeerIDs),
      // just continue with the collision - it's very unlikely in practice
      break;
    }
  } while (MockHost._allHosts.containsKey(peerId));

  final network = MockNetworkImpl();
  final peerstore = MockPeerstoreImpl();
  
  // Add the keys to the keybook so DHT operations can sign records
  peerstore.keyBook.addPrivKey(peerId, keyPair.privateKey);
  peerstore.keyBook.addPubKey(peerId, keyPair.publicKey);
  
  return MockHost(peerId, network, peerstore);
}

/// A mock implementation of the Host interface for testing
class MockHost implements Host {
  // Static map of all hosts - public for createHost to check for uniqueness
  static final Map<PeerId, MockHost> _allHosts = {}; 

  final PeerId _id;
  final MockNetworkImpl _network;
  // Changed to use the local MockPeerstoreImpl
  final MockPeerstoreImpl _peerstore; 
  final List<MultiAddr> _addrs = [];
  final Map<String, StreamHandler> _handlers = {}; // Changed type to StreamHandler
  final Map<String, dynamic> _handlersMatch = {};
  bool _closed = false;
  late final Logger _hostLogger; // Instance-specific logger

  MockHost(this._id, this._network, this._peerstore) {
    _hostLogger = Logger('MockHost.${_id.toBase58().substring(0,6)}');
    // Add a dummy multiaddr for testing
    _addrs.add(MultiAddr('/ip4/127.0.0.1/tcp/0'));
    _allHosts[_id] = this; // Register this host
    _hostLogger.fine('Registered MockHost. ID: ${_id.toBase58()}, IdentityHashCode: ${identityHashCode(_id)}, Instance: $this');
    _hostLogger.finer('Current _allHosts after adding ${_id.toBase58()}: Keys: ${_allHosts.keys.map((k) => "${k.toBase58()} (ihc: ${identityHashCode(k)})").join(', ')}');
  }

  @override
  PeerId get id => _id;

  @override
  List<MultiAddr> get addrs => _addrs;

  @override
  Network get network => _network;

  @override
  Peerstore get peerStore => _peerstore;

  @override
  ConnManager get connManager => ConnectionManager();

  final EventBus _eventBus = BasicBus();
  @override
  EventBus get eventBus => _eventBus;

  @override
  ProtocolSwitch get mux => MultistreamMuxer();

  @override
  Future<void> close() async {
    _closed = true;
    _allHosts.remove(_id); // Unregister this host
    _hostLogger.fine('Closed and unregistered');
  }

  void unregister() {
    _allHosts.remove(_id);
    _hostLogger.fine('Unregistered without closing');
  }

  @override
  Future<void> connect(AddrInfo peer, {Context? context}) async {
    if (_closed) throw Exception('Host is closed');
    // In a real implementation, this would establish a connection to the peer
    // For testing, we'll just simulate a successful connection
  }

  @override
  Future<void> dialPeer(PeerId peer) async {
    if (_closed) throw Exception('Host is closed');
    // In a real implementation, this would establish a connection to the peer
    // For testing, we'll just simulate a successful connection
  }

  @override
  Future<P2PStream<Uint8List>> newStream(PeerId remotePeerId, List<String> protocols, [dynamic context]) async {
    if (_closed) {
      _hostLogger.warning('newStream called on closed host');
      throw Exception('Host is closed');
    }
    _hostLogger.fine('newStream from ${this.id.toBase58()} (ihc: ${identityHashCode(this.id)}) to ${remotePeerId.toBase58()} (ihc: ${identityHashCode(remotePeerId)}) for protocols $protocols');
    _hostLogger.finer('Attempting to find remotePeerId ${remotePeerId.toBase58()} (ihc: ${identityHashCode(remotePeerId)}) in _allHosts.');
    _hostLogger.finer('Current _allHosts keys: ${_allHosts.keys.map((k) => "PeerId: ${k.toBase58()}, IdentityHashCode: ${identityHashCode(k)}, Instance: ${_allHosts[k]}").join('\n  - ')}');


    final clientStream = MockStream(this.id, remotePeerId, debugID: 'client_${this.id.toBase58().substring(0,4)}->${remotePeerId.toBase58().substring(0,4)}');

    final remoteHost = _allHosts[remotePeerId];
    if (remoteHost == null) {
      _hostLogger.severe('Remote host ${remotePeerId.toBase58()} (ihc: ${identityHashCode(remotePeerId)}) NOT FOUND in _allHosts. Client stream ${clientStream._debugID} will likely hang.');
      // Allow returning clientStream; the caller (e.g., ProtocolMessenger) will time out if no response.
      throw Exception('Remote host not found: ${remotePeerId.toBase58()}');
    }
    _hostLogger.fine('Remote host ${remotePeerId.toBase58()} (ihc: ${identityHashCode(remotePeerId)}) FOUND in _allHosts. Instance: $remoteHost');


    if (protocols.isEmpty) {
       _hostLogger.severe('No protocols specified for newStream to ${remotePeerId.toBase58()}. Client stream ${clientStream._debugID} will likely hang.');
       return clientStream;
    }
    final protocol = protocols.first; // Assuming first protocol is the one to use.
    _hostLogger.finer('Looking for handler for protocol "$protocol" on remote host ${remoteHost.id.toBase58()}. Available handlers: ${remoteHost._handlers.keys.join(', ')}');

    final serverHandler = remoteHost._handlers[protocol];
    if (serverHandler == null) {
      _hostLogger.severe('Remote host ${remotePeerId.toBase58()} has no handler for protocol "$protocol". Client stream ${clientStream._debugID} will likely hang. Available handlers on remote: ${remoteHost._handlers.keys.join(", ")}');
      return clientStream;
    }
    _hostLogger.fine('Found handler for protocol "$protocol" on remote host ${remoteHost.id.toBase58()}.');

    // Create the server's end of the stream
    final serverStream = MockStream(remotePeerId, this.id, debugID: 'server_${remotePeerId.toBase58().substring(0,4)}<-${this.id.toBase58().substring(0,4)}');

    // Link the two streams
    clientStream.link(serverStream);
    _hostLogger.fine('Linked clientStream ${clientStream._debugID} with serverStream ${serverStream._debugID}');

    // Asynchronously invoke the server's handler with the server's end of the stream.
    // This simulates the network delivering the new stream to the remote peer.
    Future.microtask(() {
      _hostLogger.fine('Invoking handler on remote host ${remoteHost.id.toBase58().substring(0,6)} for protocol $protocol with stream ${serverStream._debugID}');
      try {
        // Assuming StreamHandler, despite analyzer confusion, might be locally resolved to F(P2PStream, PeerId)
        // based on previous error messages when two arguments were passed.
        // this.id is the PeerId of the host initiating the stream (clientStream.localPeer)
        final result = serverHandler(serverStream, this.id); 
        result.catchError((e, s) {
          _hostLogger.severe('Async error in remote stream handler for $protocol on ${remoteHost.id.toBase58()}: $e', e, s);
          // Attempt to close streams if handler fails
          if (!serverStream.isClosed) serverStream.close();
          if (!clientStream.isClosed) clientStream.close();
        });
      } catch (e, s) {
        _hostLogger.severe('Sync error in remote stream handler for $protocol on ${remoteHost.id.toBase58()}: $e', e, s);
        if (!serverStream.isClosed) serverStream.close();
        if (!clientStream.isClosed) clientStream.close();
      }
    });

    return clientStream;
  }

  @override
  void removeStreamHandler(String protocol) {
    _handlers.remove(protocol);
    _hostLogger.fine('Removed stream handler for $protocol');
  }

  @override
  void setStreamHandler(String protocol, StreamHandler handler) {
    _handlers[protocol] = handler;
    _hostLogger.fine('Set stream handler for $protocol');
  }

  @override
  void setStreamHandlerMatch(String protocol, dynamic match, StreamHandler handler) {
    _handlersMatch[protocol] = match;
    _handlers[protocol] = handler;
  }

  @override
  Future<void> start() async {
    // Mock implementation - no actual startup needed for testing
    return;
  }

  @override
  // TODO: implement holePunchService
  HolePunchService? get holePunchService => throw UnimplementedError();
}

/// A mock implementation of the Network interface for testing
class MockNetworkImpl implements Network {
  final Map<String, StreamHandler> _handlers = {};
  final Map<PeerId, List<Conn>> _connections = {};

  @override
  void setStreamHandler(String protocol, StreamHandler handler) {
    _handlers[protocol] = handler;
  }

  @override
  List<Conn> connsToPeer(PeerId peer) {
    return _connections[peer] ?? <Conn>[];
  }

  @override
  Connectedness connectedness(PeerId peer) {
    return _connections.containsKey(peer) ? Connectedness.connected : Connectedness.notConnected;
  }

  @override
  bool canDial(PeerId peerId, MultiAddr addr) {
    // TODO: implement canDial
    throw UnimplementedError();
  }

  @override
  Future<void> close() {
    return Future.delayed(Duration(milliseconds: 10));
  }

  @override
  Future<void> closePeer(PeerId peerId) {
    return Future.delayed(Duration(milliseconds: 10));
  }

  @override
  // TODO: implement conns
  List<Conn> get conns => throw UnimplementedError();

  @override
  Future<Conn> dialPeer(Context context, PeerId peerId) {
    // TODO: implement dialPeer
    throw UnimplementedError();
  }

  @override
  // TODO: implement interfaceListenAddresses
  Future<List<MultiAddr>> get interfaceListenAddresses => throw UnimplementedError();

  @override
  Future<void> listen(List<MultiAddr> addrs) {
    // TODO: implement listen
    throw UnimplementedError();
  }

  @override
  // TODO: implement listenAddresses
  List<MultiAddr> get listenAddresses => throw UnimplementedError();

  @override
  // TODO: implement localPeer
  PeerId get localPeer => throw UnimplementedError();

  @override
  Future<P2PStream> newStream(Context context, PeerId peerId) {
    // TODO: implement newStream
    throw UnimplementedError();
  }

  @override
  void notify(Notifiee notifiee) {
    // TODO: implement notify
  }

  @override
  // TODO: implement peers
  List<PeerId> get peers => throw UnimplementedError();

  @override
  // TODO: implement peerstore
  Peerstore get peerstore => throw UnimplementedError();

  @override
  // TODO: implement resourceManager
  ResourceManager get resourceManager => throw UnimplementedError();

  @override
  void stopNotify(Notifiee notifiee) {
    // TODO: implement stopNotify
  }

  @override
  void removeListenAddress(MultiAddr addr) {
    // TODO: implement removeListenAddress
  }
}

/// A mock implementation of the Peerstore interface for testing
class MockPeerstoreImpl implements Peerstore {
  final _MockKeyBook _keyBook = _MockKeyBook();
  
  @override
  Future<AddrInfo> peerInfo(PeerId id) async {
    // In a real implementation, this would return the peer's address info
    // For testing, we'll return a mock address info
    return AddrInfo(id, [MultiAddr('/ip4/127.0.0.1/tcp/0')]);
  }

  @override
  // TODO: implement addrBook
  AddrBook get addrBook => MemoryAddrBook();

  @override
  Future<void> close() {
    // TODO: implement close
    throw UnimplementedError();
  }

  @override
  KeyBook get keyBook => _keyBook;

  @override
  // TODO: implement metrics
  Metrics get metrics => MemoryMetrics();

  @override
  // TODO: implement peerMetadata
  PeerMetadata get peerMetadata => MemoryPeerMetadata();

  @override
  Future<List<PeerId>> peers() {
    // TODO: implement peers
    throw UnimplementedError();
  }

  @override
  // TODO: implement protoBook
  ProtoBook get protoBook => MemoryProtoBook();

  @override
  Future<void> removePeer(PeerId id) {
    // TODO: implement removePeer
    throw UnimplementedError();
  }

  final Map<PeerId, PeerInfo> _peerStore = {};

  @override
  Future<void> addOrUpdatePeer(PeerId peerId,
      {Iterable<MultiAddr>? addrs,
      Iterable<String>? protocols,
      Map<String, dynamic>? metadata}) {
    final existing = _peerStore[peerId];
    if (existing != null) {
      final updatedAddrs =
          addrs != null ? [...existing.addrs, ...addrs] : existing.addrs;
      final updatedProtocols = protocols != null
          ? [...existing.protocols, ...protocols]
          : existing.protocols;
      final updatedMetadata = metadata != null
          ? {...existing.metadata, ...metadata}
          : existing.metadata;
      _peerStore[peerId] = PeerInfo(peerId: peerId, addrs: updatedAddrs.toSet(),
          protocols: updatedProtocols.toSet(), metadata: updatedMetadata);
    } else {
      _peerStore[peerId] = PeerInfo(peerId: peerId, addrs: addrs?.toSet() ?? <MultiAddr>[].toSet(),
          protocols: protocols?.toSet() ?? <String>[].toSet(), metadata: metadata ?? {});
    }

    return Future.delayed(Duration(milliseconds: 10));
  }

  @override
  Future<PeerInfo?> getPeer(PeerId peerId) async {
    return _peerStore[peerId];
  }
}

/// A mock implementation of KeyBook for testing
class _MockKeyBook implements KeyBook {
  final Map<PeerId, PrivateKey> _privateKeys = {};
  final Map<PeerId, PublicKey> _publicKeys = {};
  
  @override
  Future<void> addPrivKey(PeerId peerId, PrivateKey privateKey) async {
    _privateKeys[peerId] = privateKey;
  }

  @override
  Future<void> addPubKey(PeerId peerId, PublicKey publicKey) async {
    _publicKeys[peerId] = publicKey;
  }

  @override
  Future<PrivateKey?> privKey(PeerId peerId) async {
    return _privateKeys[peerId];
  }

  @override
  Future<PublicKey?> pubKey(PeerId peerId) async {
    return _publicKeys[peerId];
  }

  @override
  Future<void> removePrivKey(PeerId peerId) async {
    _privateKeys.remove(peerId);
  }

  @override
  Future<void> removePubKey(PeerId peerId) async {
    _publicKeys.remove(peerId);
  }

  @override
  Future<List<PeerId>> peersWithKeys() async {
    final Set<PeerId> allPeers = {};
    allPeers.addAll(_privateKeys.keys);
    allPeers.addAll(_publicKeys.keys);
    return allPeers.toList();
  }

  @override
  void removePeer(PeerId id) {
    // TODO: implement removePeer
    throw UnimplementedError();
  }
}

// MockStream implements a duplex P2PStream for testing.
// It allows two MockStream instances to be linked, simulating a connection.
class MockStream implements StreamSink<Uint8List>, P2PStream<Uint8List> {
  final PeerId localPeer;
  final PeerId remotePeer;
  final String _debugID; // For logging, e.g., 'client' or 'server'
  final Logger _streamLogger; // Instance-specific logger

  final StreamController<Uint8List> _outgoingController = StreamController<Uint8List>.broadcast();
  final StreamController<Uint8List> _incomingController = StreamController<Uint8List>.broadcast();
  final Completer<void> _closeCompleter = Completer<void>();

  MockStream? _remoteStream; // The other end of the "connection"
  StreamSubscription? _remoteOutgoingSubscription;

  bool _isClosed = false;
  bool _isReadClosed = false;
  bool _isWriteClosed = false;

  // Buffer for messages received before read() is called
  final List<Uint8List> _incomingMessageBuffer = [];
  Completer<Uint8List>? _currentReadCompleter;

  MockStream(this.localPeer, this.remotePeer, {String debugID = 'stream'}) : 
    _debugID = '${debugID}_${localPeer.toBase58().substring(0,6)}<->${remotePeer.toBase58().substring(0,6)}',
    _streamLogger = Logger('MockStream.${debugID}_${localPeer.toBase58().substring(0,6)}<->${remotePeer.toBase58().substring(0,6)}') {
    _streamLogger.finest('[$_debugID] MockStream created');
  }

  // Links this stream to a remote stream, establishing bidirectional data flow.
  void link(MockStream remote) {
    if (_remoteStream != null || remote._remoteStream != null) {
      throw StateError('[$_debugID] MockStreams are already linked.');
    }
    if (this == remote) {
      throw StateError('[$_debugID] Cannot link a stream to itself.');
    }

    _remoteStream = remote;
    remote._remoteStream = this;

    // Path 1: Data from 'this' stream's _outgoingController goes to 'remote' stream's _handleIncomingMessage.
    // 'this._remoteOutgoingSubscription' is 'this' stream's mechanism for sending.
    this._remoteOutgoingSubscription = this._outgoingController.stream.listen(
      (Uint8List data) {
        if (remote._isClosed || remote._isReadClosed) {
          this._streamLogger.warning('[${this._debugID}] Attempted to write to remote stream ${remote._debugID} that is closed for reads. Data length: ${data.length}');
          return;
        }
        this._streamLogger.finest('[${this._debugID}] Forwarding data to ${remote._debugID}, length: ${data.length}');
        remote._handleIncomingMessage(data);
      },
      onDone: () {
        this._streamLogger.finest('[${this._debugID}] Outgoing stream from ${this._debugID} done, notifying remote ${remote._debugID} to close its read side.');
        remote._closeReadByRemote();
      },
      onError: (e, st) {
        this._streamLogger.severe('[${this._debugID}] Error on outgoing stream from ${this._debugID}: $e. Notifying remote ${remote._debugID} to close its read side with error.');
        remote._closeReadByRemoteWithError(e, st);
      },
      cancelOnError: true,
    );

    // Path 2: Data from 'remote' stream's _outgoingController goes to 'this' stream's _handleIncomingMessage.
    // 'remote._remoteOutgoingSubscription' is 'remote' stream's mechanism for sending.
    remote._remoteOutgoingSubscription = remote._outgoingController.stream.listen(
      (Uint8List data) {
        if (this._isClosed || this._isReadClosed) {
          remote._streamLogger.warning('[${remote._debugID}] Attempted to write to remote stream ${this._debugID} that is closed for reads. Data length: ${data.length}');
          return;
        }
        remote._streamLogger.finest('[${remote._debugID}] Forwarding data to ${this._debugID}, length: ${data.length}');
        this._handleIncomingMessage(data);
      },
      onDone: () {
        remote._streamLogger.finest('[${remote._debugID}] Outgoing stream from ${remote._debugID} done, notifying remote ${this._debugID} to close its read side.');
        this._closeReadByRemote();
      },
      onError: (e, st) {
        remote._streamLogger.severe('[${remote._debugID}] Error on outgoing stream from ${remote._debugID}: $e. Notifying remote ${this._debugID} to close its read side with error.');
        this._closeReadByRemoteWithError(e, st);
      },
      cancelOnError: true,
    );
    _streamLogger.finest('[$_debugID] Linked bidirectionally with ${remote._debugID}');
  }

  void _handleIncomingMessage(Uint8List data) {
    if (_isReadClosed || _isClosed) {
      _streamLogger.warning('[$_debugID] Data received but stream is closed for reads. Discarding data length: ${data.length}');
      return;
    }
    if (_currentReadCompleter != null && !_currentReadCompleter!.isCompleted) {
      _streamLogger.finest('[$_debugID] Completing pending read with data length: ${data.length}');
      _currentReadCompleter!.complete(data);
      _currentReadCompleter = null; 
    } else {
      _streamLogger.finest('[$_debugID] Buffering incoming data length: ${data.length}');
      _incomingMessageBuffer.add(data);
    }
    _incomingController.sink.add(data);
  }

  @override
  Future<Uint8List> read([int? maxLength]) async {
    if (_isReadClosed && _isClosed) { // If fully closed, error.
      throw StateError('[$_debugID] Stream is fully closed.');
    }
    if (_isReadClosed) { // If only read side is closed (e.g. by remote write close)
        throw StateError('[$_debugID] Stream is closed for reading (remote closed write or local closed read).');
    }

    if (_incomingMessageBuffer.isNotEmpty) {
      final data = _incomingMessageBuffer.removeAt(0);
      _streamLogger.finest('[$_debugID] Consumed data from buffer, length: ${data.length}');
      return data;
    }
    if (_currentReadCompleter != null && !_currentReadCompleter!.isCompleted) {
      _streamLogger.warning('[$_debugID] read() called while another read is already pending.');
      return _currentReadCompleter!.future;
    }

    _streamLogger.finest('[$_debugID] No buffered data, awaiting new data.');
    _currentReadCompleter = Completer<Uint8List>();
    return _currentReadCompleter!.future;
  }

  @override
  Future<void> write(Uint8List data) async { 
    if (_isWriteClosed || _isClosed) {
      throw StateError('[$_debugID] Stream is closed for writing. Attempted to write data length: ${data.length}');
    }
    _streamLogger.finest('[$_debugID] Writing data, length: ${data.length}');
    _outgoingController.sink.add(data);
  }

  @override
  void add(Uint8List event) { // This is part of StreamSink
    write(event); 
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) { // Part of StreamSink
    if (_isWriteClosed || _isClosed) {
      throw StateError('[$_debugID] Stream is closed for writing errors.');
    }
    _streamLogger.severe('[$_debugID] Adding error to outgoing stream: $error');
    _outgoingController.sink.addError(error, stackTrace);
  }

  @override
  Future<void> addStream(Stream<Uint8List> stream) async { // Part of StreamSink
    if (_isWriteClosed || _isClosed) {
      throw StateError('[$_debugID] Stream is closed for adding streams.');
    }
    _streamLogger.finest('[$_debugID] Adding stream of data to outgoing controller.');
    await _outgoingController.sink.addStream(stream);
  }

  @override
  Future<void> close() async { // Part of StreamSink and P2PStream
    if (_isClosed) {
      _streamLogger.finest('[$_debugID] close() called on already closed stream.');
      return;
    }
    _isClosed = true;
    _isReadClosed = true; 
    _isWriteClosed = true;
    _streamLogger.finest('[$_debugID] Closing stream (full).');

    await _remoteOutgoingSubscription?.cancel();
    _remoteOutgoingSubscription = null;

    if (!_outgoingController.isClosed) {
      await _outgoingController.sink.close();
    }
    if (!_incomingController.isClosed) {
      await _incomingController.sink.close();
    }

    if (_currentReadCompleter != null && !_currentReadCompleter!.isCompleted) {
      _currentReadCompleter!.completeError(StateError('[$_debugID] Stream closed (full) while read pending.'));
      _currentReadCompleter = null;
    }
    _incomingMessageBuffer.clear();

    if (!_closeCompleter.isCompleted) {
      _closeCompleter.complete();
    }

    // _remoteStream?._handleRemoteClose(); // Removed: This direct call caused premature closure of client reads.
                                        // The closure of _outgoingController, leading to onDone -> _closeReadByRemote 
                                        // on the client stream, is the correct way to signal end-of-write.
    _streamLogger.finest('[$_debugID] Stream closed (full).');
  }

  void _handleRemoteClose() {
    // This method is called if the remote stream explicitly calls _handleRemoteClose on this stream.
    // This was previously called by the remote's close() method.
    // If it's still needed for other scenarios (e.g. a more explicit "both sides must die now" signal outside of normal close flow),
    // its logic to call close() on this stream might be retained, but it should not be part of the standard close().
    _streamLogger.finest('[$_debugID] _handleRemoteClose was called by remote stream ${_remoteStream?._debugID}.');
    if (!_isClosed) {
      _streamLogger.warning('[$_debugID] Remote stream initiated a direct full close via _handleRemoteClose. This stream will also close.');
      close(); 
    }
  }

  void _closeReadByRemote() {
    _streamLogger.finest('[$_debugID] Read side is being closed due to remote write closure or error.');
    _isReadClosed = true;
    if (_currentReadCompleter != null && !_currentReadCompleter!.isCompleted) {
      _currentReadCompleter!.completeError(StateError('[$_debugID] Read aborted; remote stream closed its write side.'));
      _currentReadCompleter = null;
    }
    if (!_incomingController.isClosed) {
       _incomingController.sink.close(); // No more data will come.
    }
    if (_isWriteClosed && !_isClosed) { // If write side was already closed by local action
        close(); // Then fully close.
    }
  }

  void _closeReadByRemoteWithError(dynamic error, StackTrace? stackTrace) {
    _streamLogger.severe('[$_debugID] Read side is being closed due to remote write error: $error');
    _isReadClosed = true;
    if (_currentReadCompleter != null && !_currentReadCompleter!.isCompleted) {
      _currentReadCompleter!.completeError(error, stackTrace);
      _currentReadCompleter = null;
    }
    if (!_incomingController.isClosed) {
       _incomingController.sink.addError(error, stackTrace);
       _incomingController.sink.close();
    }
    if (_isWriteClosed && !_isClosed) {
        close();
    }
  }


  @override
  Future<void> closeRead() async {
    if (_isReadClosed) {
      _streamLogger.finest('[$_debugID] closeRead() called on already closed read side.');
      return;
    }
    _isReadClosed = true;
    _streamLogger.finest('[$_debugID] Closing read side locally.');
    if (_currentReadCompleter != null && !_currentReadCompleter!.isCompleted) {
      _currentReadCompleter!.completeError(StateError('[$_debugID] Read side closed locally while read pending.'));
      _currentReadCompleter = null;
    }
    _incomingMessageBuffer.clear();
    if (!_incomingController.isClosed) {
      await _incomingController.sink.close();
    }

    // Notify remote that we are no longer reading (so it can stop writing if it wants)
    // This is typically implicit; if the remote writes and this stream doesn't read, data might buffer or be dropped.
    // A specific signal for "stop sending" isn't standard in basic stream models but can be app-level.
    // For now, local closeRead primarily affects local reading.

    if (_isWriteClosed && !_isClosed) {
      await close(); // If write is also closed, then it's a full close.
    }
  }

  @override
  Future<void> closeWrite() async {
    if (_isWriteClosed) {
      _streamLogger.finest('[$_debugID] closeWrite() called on already closed write side.');
      return;
    }
    _isWriteClosed = true;
    _streamLogger.finest('[$_debugID] Closing write side locally.');
    if (!_outgoingController.isClosed) {
      await _outgoingController.sink.close(); // This triggers onDone for the remote's listener (_remoteOutgoingSubscription on the other side)
                                            // which in turn calls _closeReadByRemote() on the other side.
    }
    if (_isReadClosed && !_isClosed) {
      await close(); // If read is also closed, then it's a full close.
    }
  }

  @override
  Future<void> get done => _closeCompleter.future; // Changed to Future<void> for StreamSink

  @override
  Conn get conn {
    throw UnimplementedError('[$_debugID] MockStream.conn not implemented meaningfully for this mock.');
  }

  @override
  String id() => _debugID; 

  @override
  P2PStream<Uint8List> get incoming => this;

  @override
  bool get isClosed => _isClosed; // This should reflect the overall stream state.

  @override
  String protocol() => '/ipfs/kad/1.0.0'; 

  @override
  Future<void> reset() async {
    _streamLogger.warning('[$_debugID] Reset called.');
    if (_isClosed) {
      // throw StateError('[$_debugID] Cannot reset a closed stream.');
      _streamLogger.warning('[$_debugID] Reset called on already closed stream. No action.');
      return;
    }

    // Signal error to any pending local read
    if (_currentReadCompleter != null && !_currentReadCompleter!.isCompleted) {
      _currentReadCompleter!.completeError(StateError('[$_debugID] Stream reset during read.'));
      _currentReadCompleter = null;
    }
    _incomingMessageBuffer.clear();

    // Signal error to the remote stream via the outgoing controller if it's still open
    if (!_outgoingController.isClosed) {
       _outgoingController.sink.addError(StateError('[$_debugID] Stream reset by local peer. This may cause remote to close or error.'));
       // Closing the outgoing controller makes sense after a reset signal.
       // await _outgoingController.sink.close(); // This would trigger _closeReadByRemote on the other side.
    }

    // Notify the remote stream about the reset more directly if possible.
    // This allows the remote to react specifically to a reset.
    _remoteStream?._handleRemoteReset();

    // A reset typically means the stream is no longer usable and should be fully closed.
    await close(); 
  }

  void _handleRemoteReset() {
    _streamLogger.warning('[$_debugID] Remote stream ${_remoteStream?._debugID} initiated reset.');
    if (!_isClosed) {
      if (_currentReadCompleter != null && !_currentReadCompleter!.isCompleted) {
        _currentReadCompleter!.completeError(StateError('[$_debugID] Remote stream reset during read.'));
         _currentReadCompleter = null;
      }
      _incomingMessageBuffer.clear();
      if (!_outgoingController.isClosed && !_isWriteClosed) { // only add error if not already closing write
         _outgoingController.sink.addError(StateError('[$_debugID] Stream reset by remote peer.'));
      }
      // After a remote reset, this stream should also close.
      close(); 
    }
  }

  @override
  StreamManagementScope scope() {
    throw UnimplementedError('[$_debugID] MockStream.scope not implemented');
  }

  @override
  Future<void> setDeadline(DateTime? time) async { _streamLogger.finest('[$_debugID] setDeadline called (stub)'); }

  @override
  Future<void> setProtocol(String id) async { _streamLogger.finest('[$_debugID] setProtocol called (stub)'); }

  @override
  Future<void> setReadDeadline(DateTime time) async { _streamLogger.finest('[$_debugID] setReadDeadline called (stub)'); }

  @override
  Future<void> setWriteDeadline(DateTime time) async { _streamLogger.finest('[$_debugID] setWriteDeadline called (stub)'); }

  @override
  StreamStats stat() {
    throw UnimplementedError('[$_debugID] MockStream.stat not implemented');
  }

  // Stream interface methods (from Stream<Uint8List>)
  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List event)? onData, {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    return _incomingController.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  Future<bool> any(bool Function(Uint8List element) test) => _incomingController.stream.any(test);
  @override
  Stream<Uint8List> asBroadcastStream({void Function(StreamSubscription<Uint8List> subscription)? onListen, void Function(StreamSubscription<Uint8List> subscription)? onCancel}) => _incomingController.stream.asBroadcastStream(onListen: onListen, onCancel: onCancel);
  @override
  Stream<E> asyncExpand<E>(Stream<E>? Function(Uint8List event) convert) => _incomingController.stream.asyncExpand(convert);
  @override
  Stream<E> asyncMap<E>(FutureOr<E> Function(Uint8List event) convert) => _incomingController.stream.asyncMap(convert);
  @override
  Stream<R> cast<R>() => _incomingController.stream.cast<R>();
  @override
  Future<bool> contains(Object? needle) => _incomingController.stream.contains(needle);
  @override
  Stream<Uint8List> distinct([bool Function(Uint8List previous, Uint8List next)? equals]) => _incomingController.stream.distinct(equals);
  @override
  Future<E> drain<E>([E? futureValue]) => _incomingController.stream.drain(futureValue);
  @override
  Future<Uint8List> elementAt(int index) => _incomingController.stream.elementAt(index);
  @override
  Future<bool> every(bool Function(Uint8List element) test) => _incomingController.stream.every(test);
  @override
  Stream<S> expand<S>(Iterable<S> Function(Uint8List element) convert) => _incomingController.stream.expand(convert);
  @override
  Future<Uint8List> get first => _incomingController.stream.first;
  @override
  Future<Uint8List> firstWhere(bool Function(Uint8List element) test, {Uint8List Function()? orElse}) => _incomingController.stream.firstWhere(test, orElse: orElse);
  @override
  Future<S> fold<S>(S initialValue, S Function(S previous, Uint8List element) combine) => _incomingController.stream.fold(initialValue, combine);
  @override
  Future<void> forEach(void Function(Uint8List element) action) => _incomingController.stream.forEach(action);
  @override
  Stream<Uint8List> handleError(Function onError, {bool Function(dynamic error)? test}) => _incomingController.stream.handleError(onError, test: test);
  @override
  bool get isBroadcast => _incomingController.stream.isBroadcast;
  @override
  Future<bool> get isEmpty => _incomingController.stream.isEmpty;
  @override
  Future<String> join([String separator = '']) => _incomingController.stream.map((e) => e.toString()).join(separator); 
  @override
  Future<Uint8List> get last => _incomingController.stream.last;
  @override
  Future<Uint8List> lastWhere(bool Function(Uint8List element) test, {Uint8List Function()? orElse}) => _incomingController.stream.lastWhere(test, orElse: orElse);
  @override
  Future<int> get length => _incomingController.stream.length;
  @override
  Stream<S> map<S>(S Function(Uint8List event) convert) => _incomingController.stream.map(convert);
  @override
  Future<Uint8List> reduce(Uint8List Function(Uint8List previous, Uint8List element) combine) => _incomingController.stream.reduce(combine);
  @override
  Future<Uint8List> get single => _incomingController.stream.single;
  @override
  Future<Uint8List> singleWhere(bool Function(Uint8List element) test, {Uint8List Function()? orElse}) => _incomingController.stream.singleWhere(test, orElse: orElse);
  @override
  Stream<Uint8List> skip(int count) => _incomingController.stream.skip(count);
  @override
  Stream<Uint8List> skipWhile(bool Function(Uint8List element) test) => _incomingController.stream.skipWhile(test);
  @override
  Stream<Uint8List> take(int count) => _incomingController.stream.take(count);
  @override
  Stream<Uint8List> takeWhile(bool Function(Uint8List element) test) => _incomingController.stream.takeWhile(test);
  @override
  Stream<Uint8List> timeout(Duration timeLimit, {void Function(EventSink<Uint8List> sink)? onTimeout}) => _incomingController.stream.timeout(timeLimit, onTimeout: onTimeout);
  @override
  Future<List<Uint8List>> toList() => _incomingController.stream.toList();
  @override
  Future<Set<Uint8List>> toSet() => _incomingController.stream.toSet();
  @override
  Stream<S> transform<S>(StreamTransformer<Uint8List, S> streamTransformer) => _incomingController.stream.transform(streamTransformer);
  @override
  Stream<Uint8List> where(bool Function(Uint8List event) test) => _incomingController.stream.where(test);
}

/// Creates a mock network with the specified number of hosts
Future<MockNetwork> createMockNetwork(int numHosts) async {
  final hosts = <Host>[];
  for (var i = 0; i < numHosts; i++) {
    hosts.add(await createMockHost());
  }
  return MockNetwork(hosts);
}

/// Creates a DHT instance for testing
Future<IpfsDHT> createDHT(Host host, List<dynamic> options) async {
  // Create a provider store for the DHT
  final providerStore = MemoryProviderStore();

  // Extract options if provided
  DHTOptions? dhtOptions;
  if (options.isNotEmpty && options.first is DHTOptions) {
    dhtOptions = options.first as DHTOptions;
  }

  // Create the DHT
  return IpfsDHT(
    host: host,
    providerStore: providerStore,
    options: dhtOptions,
  );
}


/// Sets up a DHT instance for testing
Future<IpfsDHT> setupDHT(bool clientMode, {DHTOptions? options}) async {
  final host = await createMockHost();
  final providerStore = MemoryProviderStore();

  final dht = IpfsDHT(
    host: host,
    providerStore: providerStore,
    options: options ?? DHTOptions(
      mode: clientMode ? DHTMode.client : DHTMode.server,
    ),
  );

  await dht.start();
  await dht.bootstrap(); // Ensure bootstrap completes before returning

  return dht;
}

/// Sets up multiple DHT instances for testing
Future<List<IpfsDHT>> setupDHTs(int count) async {
  final dhts = <IpfsDHT>[];
  for (var i = 0; i < count; i++) {
    dhts.add(await setupDHT(false));
  }
  return dhts;
}

/// Sets up a DHT with a specific CPL (common prefix length) to another DHT
Future<IpfsDHT> setupDHTWithCPL(IpfsDHT target, int cpl, {DHTOptions? options}) async {
  // 1. Generate a PeerId that has the desired CPL with the target's Kademlia ID.
  final PeerId newPeerId = await target.routingTable.genRandomPeerIdWithCpl(cpl);

  // 2. Create a MockHost for this new PeerId.
  final network = MockNetworkImpl();
  final peerstore = MockPeerstoreImpl();
  final host = MockHost(newPeerId, network, peerstore);

  // 3. Create a ProviderStore for the new DHT.
  final providerStore = MemoryProviderStore();

  // 4. Create the IpfsDHT instance.
  //    Use provided options or default to server mode and match target's bucket size if not specified.
  final dhtOptions = options ?? DHTOptions(
    mode: DHTMode.server, 
    bucketSize: target.options.bucketSize, // Inherit bucket size from target if not overridden
  );

  final dht = IpfsDHT(
    host: host,
    providerStore: providerStore,
    options: dhtOptions,
  );

  // 5. Start and bootstrap the new DHT.
  await dht.start();
  await dht.bootstrap();

  return dht;
}

/// Connects two DHT instances
Future<void> connect(IpfsDHT a, IpfsDHT b, {bool isReplaceable = false}) async {
  final hostA = a.host();
  final hostB = b.host();

  final peerIdA = hostA.id;
  final peerIdB = hostB.id;
  // Use the main test logger for connect logs
  final testConnectLogger = Logger('TestConnect');
  testConnectLogger.info('[connect] Attempting to connect ${peerIdA.toBase58().substring(0,6)} and ${peerIdB.toBase58().substring(0,6)}');

  // MockHost provides default addresses, retrieve them.
  final addrsA = hostA.addrs;
  final addrsB = hostB.addrs;
  testConnectLogger.info('[connect] Got addresses for both hosts. A: ${addrsA.length}, B: ${addrsB.length}');
  final dummyProtocol = ['/dummy-protocol/1.0.0'];

  // Add each other to their peerstores
  hostA.peerStore.addOrUpdatePeer(peerIdB, addrs: addrsB, protocols: dummyProtocol);
  final checkAddrsBInA = await hostA.peerStore.getPeer(peerIdB);
  testConnectLogger.info('[connect] Peerstore check on ${hostA.id.toBase58().substring(0,6)} for ${peerIdB.toBase58().substring(0,6)}: AddrInfo is ${checkAddrsBInA == null ? "NULL" : "PRESENT"}, AddrCount=${checkAddrsBInA?.addrs.length ?? "N/A"}, ProtocolCount=${checkAddrsBInA?.protocols.length ?? "N/A"}');
  if (checkAddrsBInA?.addrs.isNotEmpty == true) {
    testConnectLogger.info('[connect] Addresses for ${peerIdB.toBase58().substring(0,6)} in ${hostA.id.toBase58().substring(0,6)}\'s peerstore: ${checkAddrsBInA!.addrs.map((a) => a.toString()).join(', ')}');
  }
   if (checkAddrsBInA?.protocols.isNotEmpty == true) {
    testConnectLogger.info('[connect] Protocols for ${peerIdB.toBase58().substring(0,6)} in ${hostA.id.toBase58().substring(0,6)}\'s peerstore: ${checkAddrsBInA!.protocols.join(', ')}');
  }

  hostB.peerStore.addOrUpdatePeer(peerIdA, addrs: addrsA, protocols: dummyProtocol);
  final checkAddrsAInB = await hostB.peerStore.getPeer(peerIdA);
  testConnectLogger.info('[connect] Peerstore check on ${hostB.id.toBase58().substring(0,6)} for ${peerIdA.toBase58().substring(0,6)}: AddrInfo is ${checkAddrsAInB == null ? "NULL" : "PRESENT"}, AddrCount=${checkAddrsAInB?.addrs.length ?? "N/A"}, ProtocolCount=${checkAddrsAInB?.protocols.length ?? "N/A"}');
   if (checkAddrsAInB?.addrs.isNotEmpty == true) {
    testConnectLogger.info('[connect] Addresses for ${peerIdA.toBase58().substring(0,6)} in ${hostB.id.toBase58().substring(0,6)}\'s peerstore: ${checkAddrsAInB!.addrs.map((a) => a.toString()).join(', ')}');
  }
  if (checkAddrsAInB?.protocols.isNotEmpty == true) {
    testConnectLogger.info('[connect] Protocols for ${peerIdA.toBase58().substring(0,6)} in ${hostB..id.toBase58().substring(0,6)}\'s peerstore: ${checkAddrsAInB!.protocols.join(', ')}');
  }
  testConnectLogger.info('[connect] Finished attempting to add peers to respective peerstores.');

  // Add each other to their routing tables with explicit waiting
  testConnectLogger.info('[connect] Adding ${peerIdB.toBase58().substring(0,6)} to ${peerIdA.toBase58().substring(0,6)}\'s routing table (isReplaceable: $isReplaceable)...');
  bool addedToA = await a.routingTable.tryAddPeer(peerIdB, isReplaceable: isReplaceable);
  testConnectLogger.info('[connect] Added ${peerIdB.toBase58().substring(0,6)} to ${peerIdA.toBase58().substring(0,6)}\'s routing table. Success: $addedToA. RT size: ${await a.routingTable.size()}');

  testConnectLogger.info('[connect] Adding ${peerIdA.toBase58().substring(0,6)} to ${peerIdB.toBase58().substring(0,6)}\'s routing table (isReplaceable: $isReplaceable)...');
  bool addedToB = await b.routingTable.tryAddPeer(peerIdA, isReplaceable: isReplaceable);
  testConnectLogger.info('[connect] Added ${peerIdA.toBase58().substring(0,6)} to ${peerIdB.toBase58().substring(0,6)}\'s routing table. Success: $addedToB. RT size: ${await b.routingTable.size()}');

  // Wait a bit to ensure routing table updates are fully processed
  await Future.delayed(Duration(milliseconds: 50));
  
  // Verify the connection was successful
  final finalCheckA = await a.routingTable.find(peerIdB);
  final finalCheckB = await b.routingTable.find(peerIdA);
  testConnectLogger.info('[connect] Final verification: ${peerIdA.toBase58().substring(0,6)} has ${peerIdB.toBase58().substring(0,6)}: ${finalCheckA != null}, ${peerIdB.toBase58().substring(0,6)} has ${peerIdA.toBase58().substring(0,6)}: ${finalCheckB != null}');

  testConnectLogger.info('[connect] Connection logic complete between ${peerIdA.toBase58().substring(0,6)} and ${peerIdB.toBase58().substring(0,6)}.');

  // Note: A more complete mock might also update MockNetworkImpl._connections
  // if tests rely on network.connsToPeer or network.connectedness.
  // For now, updating peerstore and routing table is the primary concern for DHT tests.
}

/// Connects to the furthest peer in the list
Future<IpfsDHT> connectToFurthest(IpfsDHT dht, List<IpfsDHT> peers) async {
  if (peers.isEmpty) {
    throw ArgumentError('Peers list cannot be empty');
  }

  final dhtKadId = KadID.fromPeerId(dht.host().id);
  IpfsDHT? furthestPeer;
  BigInt? maxDistance; // KadID.distance returns BigInt

  for (final peer in peers) {
    final peerKadId = KadID.fromPeerId(peer.host().id);
    // The KadID class has a distance method
    final distance = dhtKadId.distance(peerKadId); 

    if (maxDistance == null || distance > maxDistance) {
      maxDistance = distance;
      furthestPeer = peer;
    }
  }

  if (furthestPeer == null) {
    // This should not happen if peers list is not empty, but as a safeguard:
    throw StateError('Could not determine the furthest peer.');
  }

  await connect(dht, furthestPeer);
  return furthestPeer;
}

/// Waits for well-formed routing tables
Future<void> waitForWellFormedTables(
  List<IpfsDHT> dhts,
  int minSize,
  int maxSize,
  Duration timeout,
) async {
  final waitLogger = Logger('waitForWellFormedTables');
  await waitUntil(() async {
    for (final dht in dhts) {
      final hostIdShort = dht.host().id.toBase58().substring(0, 6);
      final peers = await dht.routingTable.listPeers();
      waitLogger.info('Checking DHT ${hostIdShort}: RT size = ${peers.length}. Expected: [$minSize-$maxSize]');
      if (peers.length < minSize || peers.length > maxSize) {
        waitLogger.info('Condition NOT MET for DHT ${hostIdShort}. Size ${peers.length} is outside [$minSize-$maxSize].');
        return false; // Condition for waitUntil is NOT met
      }
    }
    waitLogger.info('Condition MET for all DHTs.');
    return true; // Condition for waitUntil IS met
  }, timeout: timeout);
}

/// Waits until a condition is met or times out
Future<void> waitUntil(
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  Duration interval = const Duration(milliseconds: 100),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!(await condition())) {
    if (stopwatch.elapsed > timeout) {
      throw TimeoutException('Condition not met within timeout');
    }
    await Future.delayed(interval);
  }
}

/// A mock network for testing
class MockNetwork {
  final List<Host> hosts;

  MockNetwork(this.hosts);

  Future<void> connectAllButSelf() async {
    // Connect all hosts except to themselves
    for (int i = 0; i < hosts.length; i++) {
      for (int j = 0; j < hosts.length; j++) {
        if (i != j) {  // Skip connecting a host to itself
          final hostA = hosts[i];
          final hostB = hosts[j];

          final peerIdA = hostA.id;
          final peerIdB = hostB.id;

          // Get addresses
          final addrsA = hostA.addrs;
          final addrsB = hostB.addrs;

          // Add dummy protocol for testing
          final dummyProtocol = ['/dummy-protocol/1.0.0'];

          // Add each other to their peerstores
          hostA.peerStore.addOrUpdatePeer(peerIdB, addrs: addrsB, protocols: dummyProtocol);
          hostB.peerStore.addOrUpdatePeer(peerIdA, addrs: addrsA, protocols: dummyProtocol);
        }
      }
    }
  }

  Future<void> close() async {
    // Close all hosts
    for (final host in hosts) {
      await host.close();
    }
  }
}

/// A test validator for testing
class TestValidator {
  bool validate(String key, Uint8List value) {
    // For testing purposes, always validate
    return true;
  }

  Future<Uint8List> select(String key, List<Uint8List> values) async {
    // For testing purposes, select the first value
    return values.first;
  }
}

/// A blank validator that always returns false
class BlankValidator {
  bool validate(String key, Uint8List value) {
    // For testing purposes, never validate
    return false;
  }

  Future<Uint8List> select(String key, List<Uint8List> values) async {
    // For testing purposes, select the first value
    return values.first;
  }
}
