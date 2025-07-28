import 'package:dart_libp2p/core/peer/peer_id.dart';

import '../pb/record.dart';

/// Interface for a protocol messenger that can send and receive messages.
abstract class ProtocolMessenger {
  /// Gets a value from a peer.
  /// 
  /// Returns null if the value is not found.
  Future<Record?> getValue(String ctx, PeerId peerId, String key);
}