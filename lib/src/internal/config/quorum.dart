// Ported from go-libp2p-kad-dht/internal/config/quorum.go

/// A key for storing quorum options in a routing options map.
class QuorumOptionKey {
  const QuorumOptionKey();
  
  @override
  bool operator ==(Object other) => other is QuorumOptionKey;
  
  @override
  int get hashCode => 0;
}

/// The default quorum value.
const int defaultQuorum = 0;

/// Gets the quorum value from routing options.
/// 
/// Returns [defaultQuorum] (0) if no option is found.
int getQuorum(Map<Object, Object?> options) {
  final value = options[const QuorumOptionKey()];
  if (value is int) {
    return value;
  }
  return defaultQuorum;
}