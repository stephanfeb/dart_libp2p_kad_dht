/// Peer diversity filter implementation for libp2p-kbucket
/// 
/// This file contains the implementation of a peer diversity filter that accepts or rejects peers
/// based on whitelisting rules and diversity policies.

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:logging/logging.dart';

// Logger for the diversity filter
final _dfLog = Logger('diversityFilter');

/// PeerIPGroupKey is a unique key that represents ONE of the IP Groups the peer belongs to.
/// A peer has one PeerIPGroupKey per address. Thus, a peer can belong to MULTIPLE Groups if it has
/// multiple addresses.
/// For now, given a peer address, our grouping mechanism is as follows:
///  1. For IPv6 addresses, we group by the ASN of the IP address.
///  2. For IPv4 addresses, all addresses that belong to same legacy (Class A)/8 allocations
///     OR share the same /16 prefix are in the same group.
typedef PeerIPGroupKey = String;

// Legacy IPv4 Class A networks.
final _legacyClassA = [
  '12.0.0.0/8',
  '17.0.0.0/8',
  '19.0.0.0/8',
  '38.0.0.0/8',
  '48.0.0.0/8',
  '56.0.0.0/8',
  '73.0.0.0/8',
  '53.0.0.0/8'
];

// List of legacy CIDR networks
final _legacyCidrs = _legacyClassA.map((cidr) {
  final parts = cidr.split('/');
  final ip = InternetAddress(parts[0]);
  final prefixLength = int.parse(parts[1]);
  return _CIDREntry(ip, prefixLength);
}).toList();


/// CplDiversityStats contains the peer diversity stats for a Cpl.
class CplDiversityStats {
  final int cpl;
  final Map<PeerId, List<PeerIPGroupKey>> peers;

  CplDiversityStats(this.cpl, this.peers);
}

/// A simple CIDR entry for checking if an IP is in a network
class _CIDREntry {
  final InternetAddress network;
  final int prefixLength;

  _CIDREntry(this.network, this.prefixLength);

  /// Check if an IP address is in this CIDR range
  bool contains(InternetAddress ip) {
    // Only support IPv4 for now
    if (ip.type != InternetAddressType.IPv4) return false;
    
    final ipBytes = ip.rawAddress;
    final networkBytes = network.rawAddress;
    
    // Calculate the mask
    final mask = _createMask(prefixLength);
    
    // Check if the masked IP equals the masked network
    for (var i = 0; i < ipBytes.length; i++) {
      if ((ipBytes[i] & mask[i]) != (networkBytes[i] & mask[i])) {
        return false;
      }
    }
    
    return true;
  }
  
  /// Create a network mask for the given prefix length
  Uint8List _createMask(int prefixLength) {
    final mask = Uint8List(4);
    for (var i = 0; i < 4; i++) {
      if (prefixLength >= 8) {
        mask[i] = 0xFF;
        prefixLength -= 8;
      } else if (prefixLength > 0) {
        mask[i] = (0xFF << (8 - prefixLength)) & 0xFF;
        prefixLength = 0;
      } else {
        mask[i] = 0;
      }
    }
    return mask;
  }
}

/// PeerGroupInfo represents the grouping info for a Peer.
class PeerGroupInfo {
  /// The peer ID
  final PeerId id;
  
  /// The common prefix length
  final int cpl;
  
  /// The IP group key
  final PeerIPGroupKey ipGroupKey;

  /// Constructor for PeerGroupInfo
  PeerGroupInfo({
    required this.id,
    required this.cpl,
    required this.ipGroupKey,
  });
}

/// PeerIPGroupFilter is the interface that must be implemented by callers who want to
/// instantiate a `Filter`. This interface provides the function hooks
/// that are used/called by the `Filter`.
abstract class PeerIPGroupFilter {
  /// Allow is called by the Filter to test if a peer with the given
  /// grouping info should be allowed/rejected by the Filter. This will be called ONLY
  /// AFTER the peer has successfully passed all of the Filter's internal checks.
  /// Note: If the peer is whitelisted on the Filter, the peer will be allowed by the Filter without calling this function.
  Future<bool> allow(PeerGroupInfo info);

  /// Increment is called by the Filter when a peer with the given Grouping Info.
  /// is added to the Filter state. This will happen after the peer has passed
  /// all of the Filter's internal checks and the Allow function defined above for all of it's Groups.
  void increment(PeerGroupInfo info);

  /// Decrement is called by the Filter when a peer with the given
  /// Grouping Info is removed from the Filter. This will happen when the caller/user of the Filter
  /// no longer wants the peer and the IP groups it belongs to to count towards the Filter state.
  void decrement(PeerGroupInfo info);

  /// PeerAddresses is called by the Filter to determine the addresses of the given peer
  /// it should use to determine the IP groups it belongs to.
  List<MultiAddr> peerAddresses(PeerId peerId);
}

/// Filter is a peer diversity filter that accepts or rejects peers based on the whitelisting rules configured
/// AND the diversity policies defined by the implementation of the PeerIPGroupFilter interface
/// passed to it.
class Filter {
  /// An implementation of the `PeerIPGroupFilter` interface
  final PeerIPGroupFilter _pgm;
  
  /// Map of peer IDs to their group information
  final Map<PeerId, List<PeerGroupInfo>> _peerGroups = {};
  
  /// Set of whitelisted peers
  final Set<PeerId> _wlpeers = {};
  
  /// Key for logging
  final String _logKey;
  
  /// Function to calculate CPL (Common Prefix Length)
  final int Function(PeerId) _cplFnc;
  
  /// Map of CPL to peer groups
  final Map<int, Map<PeerId, List<PeerIPGroupKey>>> _cplPeerGroups = {};

  /// Creates a new Filter for Peer Diversity.
  Filter(this._pgm, this._logKey, this._cplFnc);

  /// Removes a peer from the filter
  void remove(PeerId peerId) {
    final cpl = _cplFnc(peerId);
    
    for (final info in _peerGroups[peerId] ?? []) {
      _pgm.decrement(info);
    }
    
    _peerGroups.remove(peerId);
    
    if (_cplPeerGroups.containsKey(cpl)) {
      _cplPeerGroups[cpl]?.remove(peerId);
      
      if (_cplPeerGroups[cpl]?.isEmpty ?? false) {
        _cplPeerGroups.remove(cpl);
      }
    }
  }

  /// TryAdd attempts to add the peer to the Filter state and returns true if it's successful, false otherwise.
  Future<bool> tryAdd(PeerId peerId) async {
    if (_wlpeers.contains(peerId)) {
      return true;
    }
    
    final cpl = _cplFnc(peerId);
    
    // Don't allow peers for which we can't determine addresses
    final addrs = _pgm.peerAddresses(peerId);
    if (addrs.isEmpty) {
      _dfLog.fine('no addresses found for peer: appKey=$_logKey, peer=$peerId');
      return false;
    }
    
    final peerGroups = <PeerGroupInfo>[];
    for (final addr in addrs) {
      final ip = _extractIP(addr);
      if (ip == null) {
        _dfLog.warning('failed to parse IP from multiaddr: appKey=$_logKey, multiaddr=${addr.toString()}');
        return false;
      }
      
      // Reject the peer if we can't determine a grouping for one of its addresses
      final key = ipGroupKey(ip);
      if (key.isEmpty) {
        _dfLog.warning('group key is empty: appKey=$_logKey, ip=${ip.address}, peer=$peerId');
        return false;
      }
      
      final group = PeerGroupInfo(
        id: peerId,
        cpl: cpl,
        ipGroupKey: key,
      );
      
      if (!await _pgm.allow(group)) {
        return false;
      }
      
      peerGroups.add(group);
    }
    
    _cplPeerGroups.putIfAbsent(cpl, () => {});
    
    for (final group in peerGroups) {
      _pgm.increment(group);
      
      _peerGroups.putIfAbsent(peerId, () => []).add(group);
      _cplPeerGroups[cpl]!.putIfAbsent(peerId, () => []).add(group.ipGroupKey);
    }
    
    return true;
  }

  /// WhitelistPeers will always allow the given peers.
  void whitelistPeers(List<PeerId> peers) {
    for (final peer in peers) {
      _wlpeers.add(peer);
    }
  }


  /// GetDiversityStats returns the diversity stats for each CPL and is sorted by the CPL.
  List<CplDiversityStats> getDiversityStats() {
    final stats = <CplDiversityStats>[];
    
    final sortedCpls = _cplPeerGroups.keys.toList()..sort();
    
    for (final cpl in sortedCpls) {
      final ps = Map<PeerId, List<PeerIPGroupKey>>.from(_cplPeerGroups[cpl]!);
      final cd = CplDiversityStats(cpl, ps);
      stats.add(cd);
    }
    
    return stats;
  }
  
  /// Extract IP address from a multiaddr
  InternetAddress? _extractIP(MultiAddr addr) {
    try {
      final protocols = addr.protocols;
      for (final proto in protocols) {
        if (proto.name == 'ip4' || proto.name == 'ip6') {
          //we take the first matching component
          final (_, String value) = addr.components.where((el) {
            final (protocol, value ) = el;
            if (protocol.name == proto.name){
              return true;
            }
            return false;
          }).first;

          return proto.toInternetAddress(value);
        }
      }
    } catch (e) {
      _dfLog.warning('Error extracting IP: $e');
    }
    return null;
  }
}

/// Returns the PeerIPGroupKey to which the given IP belongs.
PeerIPGroupKey ipGroupKey(InternetAddress ip) {
  if (ip.type == InternetAddressType.IPv4) {
    // Check if it belongs to a legacy Class A network
    for (final cidr in _legacyCidrs) {
      if (cidr.contains(ip)) {
        // Return the /8 prefix as the key
        final mask = Uint8List(4);
        mask[0] = 0xFF;
        final masked = Uint8List(4);
        for (var i = 0; i < 4; i++) {
          masked[i] = ip.rawAddress[i] & mask[i];
        }
        return InternetAddress.fromRawAddress(masked).address;
      }
    }
    
    // Otherwise, return the /16 prefix
    final mask = Uint8List(4);
    mask[0] = 0xFF;
    mask[1] = 0xFF;
    final masked = Uint8List(4);
    for (var i = 0; i < 4; i++) {
      masked[i] = ip.rawAddress[i] & mask[i];
    }
    return InternetAddress.fromRawAddress(masked).address;
  } else {
    // IPv6 address - in a real implementation, we would get the ASN
    // For now, we'll just return a placeholder since ASN lookup requires additional dependencies
    // In a real implementation, you would use something like:
    // final asn = asnForIPv6(ip);
    // if (asn == 0) {
    //   return 'unknown ASN: ${ip.address.substring(0, 8)}';
    // }
    // return asn.toString();
    
    // Placeholder implementation:
    return 'ipv6:${ip.address.substring(0, 8)}';
  }
}