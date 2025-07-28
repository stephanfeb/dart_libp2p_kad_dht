import 'dart:typed_data';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/p2p/multiaddr/protocol.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/network.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';

import 'dht_options.dart';

/// CIDR for public IPv6 addresses
const String publicCIDR6 = "2000::/3";

/// Public IPv6 network
final IPNet? public6 = _parseIPNet(publicCIDR6);

/// Parses a CIDR string into an IPNet
IPNet? _parseIPNet(String cidr) {
  try {
    final parts = cidr.split('/');
    if (parts.length != 2) return null;
    
    final ip = IP.parse(parts[0]);
    final prefixLen = int.parse(parts[1]);
    
    return IPNet(ip, prefixLen);
  } catch (e) {
    print('Error parsing CIDR: $cidr - $e');
    return null;
  }
}

/// Simple IP address class for network operations
class IP {
  final Uint8List bytes;
  
  IP(this.bytes);
  
  /// Parse an IP address string
  static IP parse(String ipStr) {
    // This is a simplified implementation
    // In a real implementation, this would properly parse IPv4 and IPv6 addresses
    return IP(Uint8List(16)); // Placeholder
  }
  
  /// Returns true if this is an IPv4 address
  bool get isIPv4 => bytes.length == 4 || 
      (bytes.length == 16 && 
       bytes[10] == 0xFF && 
       bytes[11] == 0xFF && 
       bytes.sublist(0, 10).every((b) => b == 0));
  
  /// Returns the IPv4 address if this is an IPv4 address, null otherwise
  Uint8List? toIPv4() {
    if (bytes.length == 4) return bytes;
    if (bytes.length == 16 && 
        bytes[10] == 0xFF && 
        bytes[11] == 0xFF && 
        bytes.sublist(0, 10).every((b) => b == 0)) {
      return bytes.sublist(12, 16);
    }
    return null;
  }
  
  /// Returns true if this IP equals another IP
  bool equals(IP other) {
    if (bytes.length != other.bytes.length) return false;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != other.bytes[i]) return false;
    }
    return true;
  }
}

/// IP network class for CIDR operations
class IPNet {
  final IP ip;
  final int prefixLen;
  
  IPNet(this.ip, this.prefixLen);
  
  /// Returns true if the network contains the given IP
  bool contains(IP ip) {
    // This is a simplified implementation
    // In a real implementation, this would properly check if the IP is in the network
    return false; // Placeholder
  }
}

/// isPublicAddr follows the logic of manet.IsPublicAddr, except it uses
/// a stricter definition of "public" for ipv6: namely "is it in 2000::/3"?
bool isPublicAddr(MultiAddr addr) {
  try {
    final ip = toIP(addr);
    if (ip == null) return false;
    
    if (ip.toIPv4() != null) {
      return !inAddrRange(ip, private4) && !inAddrRange(ip, unroutable4);
    }
    
    return public6?.contains(ip) ?? false;
  } catch (e) {
    return false;
  }
}

/// isPrivateAddr follows the logic of manet.IsPrivateAddr, except that
/// it uses a stricter definition of "public" for ipv6
bool isPrivateAddr(MultiAddr addr) {
  try {
    final ip = toIP(addr);
    if (ip == null) return false;
    
    if (ip.toIPv4() != null) {
      return inAddrRange(ip, private4);
    }
    
    return !(public6?.contains(ip) ?? false) && !inAddrRange(ip, unroutable6);
  } catch (e) {
    return false;
  }
}

/// Extracts the IP address from a multiaddr
IP? toIP(MultiAddr addr) {
  try {
    // Get the string representation of the multiaddr
    final addrStr = addr.toString();
    
    // Check for IPv4 addresses
    if (addrStr.startsWith('/ip4/')) {
      final parts = addrStr.split('/');
      if (parts.length >= 3) {
        final ipStr = parts[2];
        return _parseIPv4(ipStr);
      }
    }
    
    // Check for IPv6 addresses
    if (addrStr.startsWith('/ip6/')) {
      final parts = addrStr.split('/');
      if (parts.length >= 3) {
        final ipStr = parts[2];
        return _parseIPv6(ipStr);
      }
    }
    
    return null;
  } catch (e) {
    return null;
  }
}

/// Parse an IPv4 address string into an IP object
IP? _parseIPv4(String ipStr) {
  try {
    final parts = ipStr.split('.');
    if (parts.length != 4) return null;
    
    final bytes = Uint8List(4);
    for (int i = 0; i < 4; i++) {
      final part = int.parse(parts[i]);
      if (part < 0 || part > 255) return null;
      bytes[i] = part;
    }
    
    return IP(bytes);
  } catch (e) {
    return null;
  }
}

/// Parse an IPv6 address string into an IP object
IP? _parseIPv6(String ipStr) {
  try {
    // This is a simplified IPv6 parser
    // A full implementation would handle all IPv6 formats
    if (ipStr == '::1') {
      // IPv6 loopback
      final bytes = Uint8List(16);
      bytes[15] = 1;
      return IP(bytes);
    }
    
    // For now, return a placeholder for other IPv6 addresses
    // A full implementation would parse the complete IPv6 format
    return IP(Uint8List(16));
  } catch (e) {
    return null;
  }
}

/// Private IPv4 networks
final List<IPNet> private4 = [
  // 10.0.0.0/8
  // 172.16.0.0/12
  // 192.168.0.0/16
  // Placeholders - would be properly initialized in a real implementation
];

/// Unroutable IPv4 networks
final List<IPNet> unroutable4 = [
  // 0.0.0.0/8
  // 127.0.0.0/8
  // etc.
  // Placeholders - would be properly initialized in a real implementation
];

/// Unroutable IPv6 networks
final List<IPNet> unroutable6 = [
  // ::/128
  // ::1/128
  // etc.
  // Placeholders - would be properly initialized in a real implementation
];

/// Checks if an IP is in any of the given IP networks
bool inAddrRange(IP ip, List<IPNet> ipnets) {
  for (final ipnet in ipnets) {
    if (ipnet.contains(ip)) {
      return true;
    }
  }
  return false;
}

/// Checks if a multiaddr is a relay address
bool isRelayAddr(MultiAddr addr) {
  for (final p in addr.protocols) {
    if (p.code == Protocols.circuit.code) {
      return true;
    }
  }
  return false;
}

/// PublicQueryFilter returns true if the peer is suspected of being publicly accessible
bool publicQueryFilter(dynamic dht, AddrInfo peerInfo) {
  if (peerInfo.addrs.isEmpty) {
    return false;
  }
  
  var hasPublicAddr = false;
  for (final addr in peerInfo.addrs) {
    if (!isRelayAddr(addr) && isPublicAddr(addr)) {
      hasPublicAddr = true;
      break;
    }
  }
  return hasPublicAddr;
}

/// Interface for objects that have a Host
abstract class HasHost {
  Host get host;
}

/// PublicRoutingTableFilter allows a peer to be added to the routing table if the connections to that peer indicate
/// that it is on a public network
Future<bool> publicRoutingTableFilter(dynamic dht, PeerId peerId) async {
  if (dht is! HasHost) return false;
  
  final host = dht.host;
  final conns = host.network.connsToPeer(peerId);
  if (conns.isEmpty) {
    return false;
  }
  
  // Do we have a public address for this peer?
  final id = conns[0].remotePeer;
  final known = await host.peerStore.peerInfo(id);
  for (final addr in known.addrs) {
    if (!isRelayAddr(addr) && isPublicAddr(addr)) {
      return true;
    }
  }
  
  return false;
}

/// PrivateQueryFilter doesn't currently restrict which peers we are willing to query from the local DHT.
bool privateQueryFilter(dynamic dht, AddrInfo peerInfo) {
  return peerInfo.addrs.isNotEmpty;
}

/// Cache duration for the router
const Duration routerCacheTime = Duration(minutes: 2);

/// Router cache
class RouterCache {
  dynamic router;
  DateTime expires = DateTime.now();
  
  /// Gets the cached router, refreshing if needed
  dynamic getCachedRouter() {
    final now = DateTime.now();
    if (now.isBefore(expires)) {
      return router;
    }
    
    // Refresh the router
    router = null; // In a real implementation, this would create a new router
    expires = now.add(routerCacheTime);
    return router;
  }
}

/// Global router cache
final routerCache = RouterCache();

/// PrivateRoutingTableFilter allows a peer to be added to the routing table if the connections to that peer indicate
/// that it is on a private network
bool privateRoutingTableFilter(dynamic dht, PeerId peerId) {
  if (dht is! HasHost) return false;
  
  final host = dht.host;
  final conns = host.network.connsToPeer(peerId);
  return privRTFilter(dht, conns);
}

/// Helper function for private routing table filter
bool privRTFilter(dynamic dht, List<Conn> conns) {
  if (dht is! HasHost) return false;
  
  final host = dht.host;
  final router = routerCache.getCachedRouter();
  
  final myAdvertisedIPs = <IP>[];
  for (final addr in host.addrs) {
    if (isPublicAddr(addr) && !isRelayAddr(addr)) {
      final ip = toIP(addr);
      if (ip != null) {
        myAdvertisedIPs.add(ip);
      }
    }
  }
  
  for (final conn in conns) {
    final remoteAddr = conn.remoteMultiaddr;
    if (isPrivateAddr(remoteAddr) && !isRelayAddr(remoteAddr)) {
      return true;
    }
    
    if (isPublicAddr(remoteAddr)) {
      final ip = toIP(remoteAddr);
      if (ip == null) continue;
      
      // If the IP is the same as one of the local host's public advertised IPs - then consider it local
      for (final myIP in myAdvertisedIPs) {
        if (myIP.equals(ip)) {
          return true;
        }
        if (ip.toIPv4() == null) {
          if (myIP.toIPv4() == null && isEUI(ip) && sameV6Net(myIP, ip)) {
            return true;
          }
        }
      }
      
      // If there's no gateway - a direct host in the OS routing table - then consider it local
      // This is relevant in particular to ipv6 networks where the addresses may all be public,
      // but the nodes are aware of direct links between each other.
      if (router != null) {
        final route = router.route(ip);
        if (route != null && route.gateway == null && route.error == null) {
          return true;
        }
      }
    }
  }
  
  return false;
}

/// Checks if an IPv6 address is an EUI-64 address
bool isEUI(IP ip) {
  // Per RFC 2373
  return ip.bytes.length == 16 && ip.bytes[11] == 0xFF && ip.bytes[12] == 0xFE;
}

/// Checks if two IPv6 addresses are in the same network
bool sameV6Net(IP a, IP b) {
  return a.bytes.length == 16 && 
         b.bytes.length == 16 && 
         _bytesEqual(a.bytes.sublist(0, 8), b.bytes.sublist(0, 8));
}

/// Compares two byte arrays for equality
bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Checks if a multiaddr contains a localhost/loopback address
bool isLocalhostAddr(MultiAddr addr) {
  try {
    final ip = toIP(addr);
    if (ip == null) return false;
    
    final ipv4 = ip.toIPv4();
    if (ipv4 != null) {
      // Check for 127.0.0.0/8 range (127.0.0.1, 127.0.0.0, etc.)
      return ipv4[0] == 127;
    }
    
    // For IPv6, check for ::1 (loopback)
    if (ip.bytes.length == 16) {
      // Check if it's ::1
      bool isLoopback = true;
      for (int i = 0; i < 15; i++) {
        if (ip.bytes[i] != 0) {
          isLoopback = false;
          break;
        }
      }
      return isLoopback && ip.bytes[15] == 1;
    }
    
    return false;
  } catch (e) {
    return false;
  }
}

/// Filters out localhost addresses from a list of multiaddrs
List<MultiAddr> filterLocalhostAddrs(List<MultiAddr> addrs) {
  return addrs.where((addr) => !isLocalhostAddr(addr)).toList();
}

/// Checks if a peer has valid connectedness
bool hasValidConnectedness(Host host, PeerId id) {
  final connectedness = host.network.connectedness(id);
  return connectedness == Connectedness.connected || connectedness == Connectedness.limited;
}
