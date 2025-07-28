import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/core/routing/options.dart' as ro;
import '../internal/config/quorum.dart';

/// Quorum is a DHT option that tells the DHT how many peers it needs to get
/// values from before returning the best one. Zero means the DHT query
/// should complete instead of returning early.
///
/// Default: 0
ro.Option quorum(int n) {
  return (ro.RoutingOptions options) async {
    options.other ??= {};
    options.other?[QuorumOptionKey()] = n;
    return;
  };
}