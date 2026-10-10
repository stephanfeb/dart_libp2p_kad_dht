/// The DHT key for a discovery namespace.
library;

import 'dart:convert';

import 'package:dcid/dcid.dart';

/// Returns the CID that [advertise] and [findPeers] use for namespace [ns]:
/// CIDv1, codec raw, multihash sha2-256 of the UTF-8 bytes of [ns].
///
/// This is `nsToCid` in go-libp2p's routing discovery, so Dart and Go peers
/// find each other's advertisements for the same namespace.
CID namespaceToCid(String ns) => CID.fromData(CID.V1, 'raw', utf8.encode(ns));
