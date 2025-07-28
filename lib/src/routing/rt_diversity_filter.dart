import 'dart:collection';

import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/discovery/peer_info.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';

import '../kbucket/peerdiversity/filter.dart';


/// Logger for the routing table diversity filter
final _logger = Logger('dht/RtDiversityFilter');


/// Filter for routing table peer diversity based on IP groups
class RtPeerIPGroupFilter implements PeerIPGroupFilter {
  /// The host
  final Host host;

  /// Maximum peers per CPL from the same IP group
  final int maxPerCpl;

  /// Maximum peers in the table from the same IP group
  final int maxForTable;

  /// Count of peers per CPL per IP group
  final Map<int, Map<String, int>> _cplIpGroupCount = {};

  /// Count of peers per IP group in the entire table
  final Map<String, int> _tableIpGroupCount = {};

  /// Lock for synchronization
  final _lock = Lock();

  /// Creates a new routing table peer diversity filter
  RtPeerIPGroupFilter({
    required this.host,
    required this.maxPerCpl,
    required this.maxForTable,
  });

  @override
  Future<bool> allow(PeerGroupInfo groupInfo) async {
    return await _lock.synchronized( () async {
      final key = groupInfo.ipGroupKey;
      final cpl = groupInfo.cpl;

      if ((_tableIpGroupCount[key] ?? 0) >= maxForTable) {
        _logger.fine('Rejecting (max for table) diversity: peer=${groupInfo.id}, cpl=$cpl, ip group=$key');
        return false;
      }

      final cplMap = _cplIpGroupCount[cpl];
      final allow = cplMap == null || (cplMap[key] ?? 0) < maxPerCpl;

      if (!allow) {
        _logger.fine('Rejecting (max for cpl) diversity: peer=${groupInfo.id}, cpl=$cpl, ip group=$key');
      }

      return allow;
    });
  }

  @override
  Future<void> increment(PeerGroupInfo groupInfo) async {
    await _lock.synchronized( () async {
      final key = groupInfo.ipGroupKey;
      final cpl = groupInfo.cpl;

      _tableIpGroupCount[key] = (_tableIpGroupCount[key] ?? 0) + 1;

      _cplIpGroupCount.putIfAbsent(cpl, () => {});
      _cplIpGroupCount[cpl]![key] = (_cplIpGroupCount[cpl]![key] ?? 0) + 1;
    });
  }

  @override
  Future<void> decrement(PeerGroupInfo groupInfo) async {
    await _lock.synchronized(() async {
      final key = groupInfo.ipGroupKey;
      final cpl = groupInfo.cpl;

      final tableCount = (_tableIpGroupCount[key] ?? 0) - 1;
      if (tableCount <= 0) {
        _tableIpGroupCount.remove(key);
      } else {
        _tableIpGroupCount[key] = tableCount;
      }

      if (_cplIpGroupCount.containsKey(cpl) && _cplIpGroupCount[cpl]!.containsKey(key)) {
        final cplCount = (_cplIpGroupCount[cpl]![key] ?? 0) - 1;
        if (cplCount <= 0) {
          _cplIpGroupCount[cpl]!.remove(key);
          if (_cplIpGroupCount[cpl]!.isEmpty) {
            _cplIpGroupCount.remove(cpl);
          }
        } else {
          _cplIpGroupCount[cpl]![key] = cplCount;
        }
      }
    });
  }

  @override
  List<MultiAddr> peerAddresses(PeerId peerId) {
    final conns = host.network.connsToPeer(peerId);
    return conns.map((c) => c.remoteMultiaddr).toList();
  }
}

/// Filters out peers from the response that are overrepresented by IP group.
/// If an IP group has more than [limit] peers, all peers with at least 1 address in that IP group
/// are filtered out.
List<PeerInfo> filterPeersByIPDiversity(List<PeerInfo> peers, int limit) {
  // If no diversity limit is set, return all peers
  if (limit <= 0) {
    return peers;
  }

  // Count peers per IP group
  final ipGroupPeers = <String, Set<PeerId>>{};

  for (final peer in peers) {
    // Find all IP groups this peer belongs to
    for (final addr in peer.addrs) {
      final ip = extractIP(addr);
      if (ip == null) continue;

      final group = ipGroupKey(ip);
      if (group.isEmpty) continue;

      ipGroupPeers.putIfAbsent(group, () => HashSet<PeerId>());
      ipGroupPeers[group]!.add(peer.peerId);
    }
  }

  // Identify overrepresented groups and tag peers for removal
  final peersToRemove = HashSet<PeerId>();

  for (final entry in ipGroupPeers.entries) {
    if (entry.value.length > limit) {
      peersToRemove.addAll(entry.value);
    }
  }

  if (peersToRemove.isEmpty) {
    // No groups are overrepresented, return all peers
    return peers;
  }

  // Filter out peers from overrepresented groups
  return peers.where((p) => !peersToRemove.contains(p.peerId)).toList();
}

/// Extracts the IP address from a multiaddress
String? extractIP(MultiAddr addr) {
  // Implementation depends on how multiaddresses are represented in your system
  // This is a simplified version
  try {
    // Parse the multiaddress to extract the IP component
    // For example, from "/ip4/192.168.1.1/tcp/8080" extract "192.168.1.1"
    final components = addr.toString().split('/');
    for (int i = 0; i < components.length - 1; i++) {
      if (components[i] == 'ip4' || components[i] == 'ip6') {
        return components[i + 1];
      }
    }
    return null;
  } catch (e) {
    return null;
  }
}

/// Generates an IP group key from an IP address
String ipGroupKey(String ip) {
  // Implementation depends on how IP grouping is done in your system
  // This is a simplified version that groups by the first 3 octets for IPv4
  // and by the first 6 hextets for IPv6
  try {
    if (ip.contains('.')) {
      // IPv4
      final parts = ip.split('.');
      if (parts.length != 4) return '';
      return '${parts[0]}.${parts[1]}.${parts[2]}';
    } else if (ip.contains(':')) {
      // IPv6
      final parts = ip.split(':');
      if (parts.length < 6) return '';
      return parts.sublist(0, 6).join(':');
    }
    return '';
  } catch (e) {
    return '';
  }
}
