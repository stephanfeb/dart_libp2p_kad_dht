import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';

/// Bootstrap configuration for DHT v2
/// 
/// This provides default bootstrap peers and configuration options
/// for connecting to the IPFS/libp2p network.
class BootstrapConfig {
  /// Default IPFS bootstrap peers
  static const List<String> defaultBootstrapPeers = [ ];
  
  /// Gets default bootstrap peers as MultiAddr objects
  static List<MultiAddr> getDefaultBootstrapPeers() {
    final peers = <MultiAddr>[];
    
    for (final addrStr in defaultBootstrapPeers) {
      try {
        final addr = MultiAddr(addrStr);
        peers.add(addr);
      } catch (e) {
        print('Error parsing bootstrap address: $addrStr - $e');
      }
    }
    
    return peers;
  }
  
  /// Gets default bootstrap peers as AddrInfo objects
  static List<AddrInfo> getDefaultBootstrapPeerAddrInfos() {
    final addrInfos = <AddrInfo>[];
    
    for (final addr in getDefaultBootstrapPeers()) {
      try {
        final info = AddrInfo.fromMultiaddr(addr);
        addrInfos.add(info);
      } catch (e) {
        print('Failed to convert bootstrapper address to peer addr info: ${addr.toString()} - $e');
      }
    }
    
    return addrInfos;
  }
  
  /// Extracts peer ID from multiaddr
  static PeerId? extractPeerIdFromMultiaddr(MultiAddr addr) {
    try {

      if (addr.peerId == null) return null;

      return PeerId.fromString(addr.peerId!);
    } catch (e) {
      print('Error extracting peer ID from $addr: $e');
    }
    return null;
  }
  
  /// Validates bootstrap peer configuration
  static bool validateBootstrapPeers(List<MultiAddr> peers) {
    if (peers.isEmpty) {
      return false;
    }
    
    for (final addr in peers) {
      final peerId = extractPeerIdFromMultiaddr(addr);
      if (peerId == null) {
        return false;
      }
    }
    
    return true;
  }
} 