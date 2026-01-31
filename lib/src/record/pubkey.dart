/// Public key validator implementation and public key retrieval functions.
import 'dart:async';
import 'dart:typed_data';
import 'package:dart_libp2p/core/crypto/keys.dart' as crypto;
import 'package:dart_libp2p/core/crypto/pb/crypto.pb.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_multihash/dart_multihash.dart';
import 'package:logging/logging.dart';
import '../dht/dht.dart';
import '../internal/cancelable_context.dart';
import '../internal/routing_exceptions.dart';
import '../internal/tracing.dart';
import 'util.dart';
import 'validator.dart';

/// Logger for the public key operations
final _logger = Logger('dht/pubkey');

/// A class to hold a public key and an error
class PubKeyResult {
  /// The public key
  final crypto.PublicKey? pubKey;

  /// The error, if any
  final Exception? error;

  /// Creates a new public key result
  PubKeyResult(this.pubKey, this.error);
}

/// A validator that validates public keys.
class PublicKeyValidator implements Validator {
  /// Creates a new public key validator.
  PublicKeyValidator();

  @override
  Future<void> validate(String key, Uint8List value) async {
    // Split the key into namespace and path
    final (ns, keyPath) = splitKey(key);

    // Check if the namespace is 'pk'
    if (ns != 'pk') {
      throw Exception('namespace not \'pk\'');
    }

    // Convert the key path to bytes
    final keyHash = Uint8List.fromList(keyPath.codeUnits);

    // Validate that the key path is a valid multihash
    try {
      Multihash.decode(keyHash);
    } catch (e) {
      throw Exception('key did not contain valid multihash: $e');
    }

    // Unmarshal the public key
    PublicKey pk;
    try {
      pk = await PublicKey.fromBuffer(value);
    } catch (e) {
      throw Exception('failed to unmarshal public key: $e');
    }

    // Get the peer ID from the public key
    PeerId id;
    try {
      final pubKey = crypto.publicKeyFromProto(pk);
      id = PeerId.fromPublicKey(pubKey);
    } catch (e) {
      throw Exception('failed to get peer ID from public key: $e');
    }

    // Check if the key hash matches the peer ID
    if (!_bytesEqual(keyHash, id.toBytes())) {
      throw Exception('public key does not match storage key');
    }
  }

  @override
  Future<int> select(String key, List<Uint8List> values) async {
    if (values.isEmpty) { // It's good practice to check for empty list
        throw Exception("can't select from no values for key '$key'");
    }
    // All public keys are equivalently valid, so return the first one
    return 0;
  }

  // Helper method to compare two byte arrays
  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Extension methods for IpfsDHT to handle public key operations
extension PublicKeyExtension on IpfsDHT {
  /// Gets the public key when given a Peer ID. It will extract from
  /// the Peer ID if inlined or ask the node it belongs to or ask the DHT.
  Future<crypto.PublicKey> getPublicKey(String ctx, PeerId p) async {
    final span = DhtTracer.startSpan('IpfsDHT.GetPublicKey');
    span.setAttribute(DhtTracer.keyAsAttribute('PeerId', p.toString()));

    try {
      if (!enableValues) {
        throw RoutingNotSupportedException();
      }

      _logger.fine('getPublicKey for: $p');

      // Check the peerId directly. Will also try to extract the public key from the peer
      // ID itself if possible (if inlined).
      final pk = await peerstore.keyBook.pubKey(p);
      if (pk != null) {
        return pk;
      }



      // Try getting the public key both directly from the node it identifies
      // and from the DHT, in parallel
      final completer = Completer<crypto.PublicKey>();

      // Create a new context that can be cancelled
      final cancelableContext = createCancelableContext(ctx);

      // Channel for results
      final resultChannel = StreamController<PubKeyResult>();

      // Get public key from node
      getPublicKeyFromNode(cancelableContext.context, p).then((pubKey) {
        resultChannel.add(PubKeyResult(pubKey, null));
      }).catchError((error) {
        resultChannel.add(PubKeyResult(null, error is Exception ? error : Exception(error.toString())));
      });

      // Get public key from DHT
      getPublicKeyFromDHT(cancelableContext.context, p).then((pubKey) {
        resultChannel.add(PubKeyResult(pubKey, null));
      }).catchError((error) {
        resultChannel.add(PubKeyResult(null, error is Exception ? error : Exception(error.toString())));
      });

      // Wait for results
      var error;
      var count = 0;

      resultChannel.stream.listen((result) {
        count++;

        if (result.pubKey != null) {
          // Found the public key
          try {
            peerstore.keyBook.addPubKey(p, result.pubKey!);
          } catch (e) {
            _logger.severe('Failed to add public key to peerstore: $p, error: $e');
          }

          if (!completer.isCompleted) {
            completer.complete(result.pubKey);
            cancelableContext.cancel();
            resultChannel.close();
          }
        } else {
          error = result.error;
        }

        // If we've received both results and neither had a public key, complete with the error
        if (count >= 2 && !completer.isCompleted) {
          completer.completeError(error ?? Exception('Failed to get public key'));
          resultChannel.close();
        }
      });

      return await completer.future;
    } catch (e) {
      span.setError(e);
      rethrow;
    } finally {
      span.end();
    }
  }

  /// Gets the public key from the DHT
  Future<crypto.PublicKey> getPublicKeyFromDHT(String ctx, PeerId p) async {
    // Only retrieve one value, because the public key is immutable
    // so there's no need to retrieve multiple versions
    final pkKey = keyForPublicKey(p);
    final val = await getValue(pkKey, null);

    try {
      // Handle null value
      if (val == null) {
        throw Exception('No public key found in DHT');
      }

      final protoPubKey = await PublicKey.fromBuffer(val);
      final pubKey = crypto.publicKeyFromProto(protoPubKey);
      _logger.fine('Got public key for $p from DHT');
      return pubKey;
    } catch (e) {
      _logger.severe('Could not unmarshal public key retrieved from DHT for $p');
      throw Exception('Could not unmarshal public key: $e');
    }
  }

  /// Gets the public key from the node itself
  Future<crypto.PublicKey> getPublicKeyFromNode(String ctx, PeerId p) async {
    // Check peerId, just in case...
    final pk = await p.extractPublicKey();
    if (pk != null) {
      return pk;
    }

    // Get the key from the node itself
    final pkKey = keyForPublicKey(p);
    final record = await protoMessenger.getValue(ctx, p, pkKey);

    // Node doesn't have key
    if (record == null) {
      throw Exception('Node $p not responding with its public key');
    }

    try {
      final protoPubKey = PublicKey.fromBuffer(record.value);
      final pubKey = crypto.publicKeyFromProto(protoPubKey);

      // Make sure the public key matches the peer ID
      final id = PeerId.fromPublicKey(pubKey);
      if (id != p) {
        throw Exception('Public key $id does not match peer $p');
      }

      _logger.fine('Got public key from node $p itself');
      return pubKey;
    } catch (e) {
      _logger.severe('Could not unmarshal public key for $p');
      throw Exception('Could not unmarshal public key: $e');
    }
  }
}

/// Creates a DHT record key for a public key.
/// Per the libp2p spec, the key is `/pk/` followed by the raw peer ID bytes
/// (multihash), not a base58-encoded string.
String keyForPublicKey(PeerId id) {
  return '/pk/${String.fromCharCodes(id.toBytes())}';
}
