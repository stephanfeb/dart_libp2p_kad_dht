/// Protocol identifiers for the DHT.
///
/// This file defines the protocol identifiers used by the DHT for communication
/// between nodes in the network.

import '../amino/defaults.dart';

/// ProtocolDHT is the default DHT protocol.
const ProtocolID protocolDHT = AminoConstants.protocolID;

/// DefaultProtocols spoken by the DHT.
final List<ProtocolID> defaultProtocols = protocols;