import 'dart:typed_data';

import 'package:dart_multihash/dart_multihash.dart' as mh;
import 'package:dcid/dcid.dart';

/// Provider records are keyed by the multihash of a CID, not by the CID's
/// bytes. That is what the libp2p Kademlia spec and go-libp2p-kad-dht
/// (`cid.Hash()`) put in ADD_PROVIDER and GET_PROVIDERS messages and use as
/// the lookup target, and it makes every CID of the same content (v0 or v1,
/// any codec) share one set of providers.
///
/// Before 1.5.1 this package sent CIDv1 bytes instead, so a Dart node never
/// found a provider that a Go node announced.
Uint8List providerKeyOf(CID cid) => cid.multihash;

/// Reads a provider key from an ADD_PROVIDER or GET_PROVIDERS message.
///
/// The key is a multihash. Dart peers before 1.5.1 sent full CIDv1 bytes,
/// which are recognised by their version prefix (0x01, never a multihash
/// code in use) and reduced to their multihash.
///
/// Throws [FormatException] if [key] is neither.
Uint8List providerKeyFromWire(Uint8List key) {
  if (key.isEmpty) {
    throw const FormatException('empty provider key');
  }
  if (key[0] == CID.V1) {
    return CID.fromBytes(key).multihash;
  }
  try {
    mh.Multihash.decode(key);
  } catch (e) {
    throw FormatException('provider key is not a multihash: $e');
  }
  return key;
}

/// A CID whose multihash is [key], for the CID-typed [ProviderStore] API.
/// Stores key records by the multihash alone, so the codec is irrelevant.
CID cidForProviderKey(Uint8List key) => CID(CID.V1, _rawCodec, key);

const _rawCodec = 0x55;
