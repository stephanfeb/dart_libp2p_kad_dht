# DHT v2 Expanded Integration Test Plan

## Overview

This document outlines comprehensive integration test scenarios for the DHT v2 implementation. These tests go beyond basic functionality to cover real-world scenarios, edge cases, and system resilience.

## Current Test Coverage

The existing `dht_v2_integration_test.dart` covers:

**Basic DHT Operations:**
- Single node creation and lifecycle
- Basic provide/findProviders operations
- Record put/get operations
- Configuration options
- Provider store integration

**Multi-Node Network Formation (Pre-Connected):**
- Mesh network operations (5-10 nodes)
- Linear chain topology operations
- Star topology operations
- Network cluster merging
- Bootstrap network formation
- **Note**: All multi-node tests use manually populated routing tables

**Actual Peer Discovery & Bootstrap:**
- Bootstrap-based peer discovery with local peers
- Multi-node bootstrap chain discovery
- Bootstrap failure and recovery scenarios
- Late-joining node discovery
- Natural peer discovery without bootstrap
- Bootstrap with mixed available/unavailable peers
- **Note**: All tests use actual DHT protocols for peer discovery

## Proposed Test Scenarios

### 1. Network Topology & Connectivity Tests

#### 1.1 Multi-Node Network Formation (Pre-Connected Networks)
**Priority: High** ✅ **COMPLETED**
- [x] **Mesh Network (5-10 nodes)**: Create nodes with pre-populated routing tables in mesh topology and verify network operations
- [x] **Linear Chain Topology**: Test A→B→C→D routing with manually established connections
- [x] **Star Topology**: Central hub with spoke nodes using pre-established connections, verify hub-spoke communication
- [x] **Network Cluster Merging**: Test merging of isolated clusters through bridge connections

**Implementation Notes:**
- ✅ Use controlled network creation with known topologies
- ✅ Manually populate routing tables to simulate established connections
- ✅ Test network operations and content discovery with pre-connected peers

**Implementation Status:**
- All tests implemented and passing in `dht_v2_integration_test.dart`
- Uses `_establishPeerConnections()` to manually populate routing tables
- Tests network behavior **after** peers already know about each other
- **Note**: These tests do NOT test the actual peer discovery mechanisms

**What These Tests Actually Verify:**
- Network operations work correctly with various topologies
- Routing table management functions properly
- Content discovery works across different network structures
- Network merge scenarios function as expected
- DHT protocol operations (provide/findProviders) work with established connections

**What These Tests Do NOT Test:**
- Actual peer discovery through DHT protocols
- Bootstrap peer discovery mechanisms
- Peer exchange during queries
- Natural network formation without manual intervention

#### 1.2 Actual Peer Discovery & Bootstrap Scenarios
**Priority: High** ✅ **COMPLETED**
- [x] **Natural Peer Discovery**: Nodes discover each other through DHT protocols without manual setup
- [x] **Bootstrap-Based Discovery**: Nodes discover network through bootstrap peers only
- [x] **Peer Exchange Discovery**: Nodes learn about new peers through FIND_NODE queries
- [x] **Multiple Bootstrap Peers**: Mix of available/unavailable bootstrap nodes
- [x] **Bootstrap Failure Recovery**: Test recovery when initial peers are unreachable
- [x] **Late-Joining Nodes**: New nodes finding existing network content through discovery
- [x] **Bootstrap State Variations**: Empty vs populated routing tables

**Implementation Notes:**
- ✅ Remove manual peer setup (`_establishPeerConnections()`)
- ✅ Test actual DHT protocol-based peer discovery
- ✅ Create deterministic bootstrap scenarios
- ✅ Test bootstrap timeout and retry logic
- ✅ Verify peer discovery propagation through network protocols
- ✅ Measure discovery time and success rates

**Key Differences from Section 1.1:**
- ✅ Start with empty routing tables (except bootstrap peers)
- ✅ Let DHT protocols handle all peer discovery
- ✅ Test the discovery mechanisms themselves, not just network operations
- ✅ Verify that peers can find each other naturally through the DHT

**Implementation Status:**
- All tests implemented and passing in `dht_v2_integration_test.dart`
- Uses actual DHT bootstrap mechanisms (no manual peer setup)
- Tests real peer discovery through DHT protocols
- Includes bootstrap failure scenarios and recovery
- Validates peer exchange through network queries
- Tests late-joining node discovery and content finding

**What These Tests Actually Verify:**
- DHT bootstrap process works correctly with local peers
- Peer discovery through DHT protocols (FIND_NODE queries)
- Bootstrap failure handling and recovery mechanisms
- Network formation through actual DHT networking
- Late-joining node integration with existing networks
- Mixed bootstrap peer availability scenarios

### 2. Fault Tolerance & Recovery Tests

#### 2.1 Node Failure Scenarios
**Priority: High** ✅ **COMPLETED**
- [x] **Graceful vs Abrupt Shutdown**: Compare impact of different shutdown methods
- [x] **Bootstrap Node Failure**: Network recovery when bootstrap nodes go offline
- [x] **Routing Table Rebuilding**: Recovery after mass node departures
- [x] **Content Availability**: Verify content remains accessible during node churn

**Implementation Notes:**
- ✅ Simulate different failure modes (network partition, process kill, graceful shutdown)
- ✅ Measure recovery time and success rates
- ✅ Test redundancy mechanisms

**Implementation Status:**
- All tests implemented and running in `dht_v2_integration_test.dart`
- Uses controlled failure simulation with proper cleanup
- Tests network resilience under different failure conditions
- Measures content availability during continuous node churn
- **Note**: Tests may require tuning based on network conditions and timing

#### 2.2 Network Partitioning
**Priority: Medium**
- [ ] **Network Split/Merge**: Test partition into two groups and reconnection
- [ ] **Content Synchronization**: Verify sync after partition healing
- [ ] **Routing Table Consistency**: Test consistency after network merges
- [ ] **Duplicate Content Handling**: Manage duplicates across partitions

**Implementation Notes:**
- Use network simulation to create controlled partitions
- Test conflict resolution mechanisms
- Verify eventual consistency

### 3. Performance & Scalability Tests

#### 3.1 Load Testing
**Priority: Medium**
- [ ] **Concurrent Operations**: Multiple nodes performing simultaneous operations
- [ ] **High-Frequency Updates**: Rapid record updates with same keys
- [ ] **Large Routing Tables**: Performance with 100+ peers
- [ ] **Memory Usage Monitoring**: Growth over extended operation periods

**Implementation Notes:**
- Use performance benchmarks and metrics collection
- Test resource limits and degradation patterns
- Monitor memory leaks and resource cleanup

#### 3.2 Large-Scale Network Tests
**Priority: Low**
- [ ] **50+ Node Networks**: Measure lookup performance at scale
- [ ] **Content Distribution**: Test distribution across large networks
- [ ] **Routing Efficiency**: Test efficiency with high node turnover
- [ ] **Bootstrap Time Scaling**: Measure bootstrap time vs network size

**Implementation Notes:**
- May require containerized test environment
- Focus on performance metrics and scalability limits
- Test network formation patterns

### 4. Protocol-Specific Behavior Tests

#### 4.1 DHT Mode Interactions
**Priority: High**
- [ ] **Mixed Client/Server Networks**: Test heterogeneous node types
- [ ] **Client-Only Networks**: Verify graceful failure handling
- [ ] **Server Node Load**: Test server handling many client connections
- [ ] **Mode Transitions**: Test dynamic client↔server transitions

**Implementation Notes:**
- Test different network compositions
- Verify protocol compliance in mixed environments
- Test load balancing across server nodes

#### 4.2 Record Management
**Priority: High**
- [ ] **Record Expiration**: Test cleanup mechanisms
- [ ] **Record Validation**: Different validator types in network
- [ ] **Version Conflict Resolution**: Handle concurrent updates
- [ ] **Record Replication**: Test replication across nodes

**Implementation Notes:**
- Test time-based and usage-based expiration
- Verify validator chain execution
- Test conflict resolution algorithms

### 5. Data Integrity & Validation Tests

#### 5.1 Record Validation
**Priority: High**
- [ ] **IPNS Record Validation**: Multi-node IPNS scenarios
- [ ] **Public Key Validation**: Cross-network key verification
- [ ] **Malformed Record Handling**: Reject invalid records
- [ ] **Signature Verification**: End-to-end signature validation

**Implementation Notes:**
- Test with real cryptographic operations
- Verify security properties across network
- Test attack resistance

#### 5.2 Content Integrity
**Priority: Medium**
- [ ] **Provider Record Consistency**: Verify consistency across nodes
- [ ] **Stale Provider Cleanup**: Test cleanup mechanisms
- [ ] **Provider Record Expiration**: Time-based cleanup
- [ ] **Duplicate Provider Handling**: Manage redundant providers

**Implementation Notes:**
- Test data consistency guarantees
- Verify cleanup and maintenance processes
- Test provider record lifecycle

### 6. Concurrency & Race Condition Tests

#### 6.1 Concurrent Operations
**Priority: High**
- [ ] **Simultaneous Provides**: Same CID from different nodes
- [ ] **Concurrent Record Updates**: Same key updates
- [ ] **Parallel Bootstrap**: Multiple simultaneous bootstraps
- [ ] **Routing Table Races**: Concurrent routing table updates

**Implementation Notes:**
- Use deterministic concurrency testing
- Test locking and synchronization mechanisms
- Verify data consistency under concurrent access

#### 6.2 Resource Contention
**Priority: Medium**
- [ ] **Connection Limits**: Test behavior under connection limits
- [ ] **Memory Pressure**: Test under memory constraints
- [ ] **CPU-Intensive Operations**: Crypto validation under load
- [ ] **I/O Bottlenecks**: Test with persistent storage

**Implementation Notes:**
- Test resource exhaustion scenarios
- Verify graceful degradation
- Test backpressure mechanisms

### 7. Real-World Scenario Tests

#### 7.1 Network Churn Simulation
**Priority: Medium**
- [ ] **Continuous Join/Leave**: Simulate realistic churn patterns
- [ ] **Seasonal Availability**: Test periodic availability patterns
- [ ] **Mobile Node Scenarios**: Frequent disconnects and reconnects
- [ ] **Network Stability Metrics**: Long-term stability measurement

**Implementation Notes:**
- Use realistic churn models based on research
- Test adaptation to changing network conditions
- Monitor long-term network health

#### 7.2 Diverse Network Conditions
**Priority: Low**
- [ ] **High-Latency Connections**: Test with simulated latency
- [ ] **Unreliable Connections**: Packet loss simulation
- [ ] **Bandwidth Constraints**: Limited bandwidth scenarios
- [ ] **Asymmetric Networks**: Different connection qualities

**Implementation Notes:**
- Use network simulation tools
- Test protocol adaptation mechanisms
- Verify performance under adverse conditions

### 8. Edge Cases & Error Handling

#### 8.1 Malicious Behavior Simulation
**Priority: Medium**
- [ ] **False Information**: Nodes providing incorrect data
- [ ] **Non-Cooperative Nodes**: Nodes refusing to cooperate
- [ ] **Spam Prevention**: Test anti-spam mechanisms
- [ ] **Resource Exhaustion Attacks**: Test DoS resistance

**Implementation Notes:**
- Test security and resilience properties
- Verify attack mitigation strategies
- Test reputation and trust mechanisms

#### 8.2 Protocol Edge Cases
**Priority: Medium**
- [ ] **Maximum Message Size**: Test size limit handling
- [ ] **Routing Table Overflow**: Test overflow scenarios
- [ ] **Circular Reference Detection**: Prevent routing loops
- [ ] **Protocol Version Compatibility**: Test version negotiation

**Implementation Notes:**
- Test protocol boundary conditions
- Verify error handling and recovery
- Test backwards compatibility

### 9. Integration with External Systems

#### 9.1 Storage Backend Tests
**Priority: Low**
- [ ] **Different Provider Stores**: Test various implementations
- [ ] **Datastore Persistence**: Test across restarts
- [ ] **Storage Backend Failures**: Test failure handling
- [ ] **Storage Migration**: Test migration scenarios

**Implementation Notes:**
- Test pluggable storage interfaces
- Verify data durability and recovery
- Test upgrade and migration paths

#### 9.2 Network Stack Integration
**Priority: Low**
- [ ] **Transport Protocol Tests**: Different transport protocols
- [ ] **NAT Traversal**: Test NAT scenarios
- [ ] **IPv4/IPv6 Dual-Stack**: Test dual-stack operations
- [ ] **Connection Multiplexing**: Test connection reuse

**Implementation Notes:**
- Test with different network stacks
- Verify interoperability
- Test network-specific optimizations

### 10. Metrics & Observability Tests

#### 10.1 Performance Monitoring
**Priority: Medium**
- [ ] **Metrics Collection**: Test metrics during operations
- [ ] **Performance Degradation**: Test degradation detection
- [ ] **Resource Usage Monitoring**: Monitor resource consumption
- [ ] **Query Success/Failure Rates**: Track operation success rates

**Implementation Notes:**
- Test metrics infrastructure
- Verify monitoring and alerting
- Test performance analysis tools

#### 10.2 Debugging & Diagnostics
**Priority: Low**
- [ ] **Routing Table Inspection**: Test inspection capabilities
- [ ] **Network Topology Visualization**: Test topology data
- [ ] **Error Reporting**: Test error reporting mechanisms
- [ ] **Performance Profiling**: Test profiling integration

**Implementation Notes:**
- Test debugging and diagnostic tools
- Verify troubleshooting capabilities
- Test integration with monitoring systems

## Implementation Strategy

### Phase 1: Core Functionality (High Priority)
1. ✅ Multi-node network formation tests (pre-connected networks)
2. ✅ Actual peer discovery and bootstrap scenarios
3. ✅ Node failure and recovery tests
4. ⚠️ **NEXT**: DHT mode interactions
5. Record validation tests
6. Concurrency and race condition tests

### Phase 2: Resilience and Performance (Medium Priority)
1. Network partitioning tests
2. Load testing scenarios
3. Content integrity tests
4. Real-world scenario simulation
5. Edge case and error handling
6. Performance monitoring tests

### Phase 3: Advanced Features (Low Priority)
1. Large-scale network tests
2. Diverse network conditions
3. External system integration
4. Debugging and diagnostics
5. Network stack integration

## Test Infrastructure Requirements

### Testing Framework Extensions
- Network simulation utilities
- Controlled failure injection
- Performance measurement tools
- Concurrent operation orchestration
- Long-running test support

### Test Environment Setup
- Containerized test environments
- Network topology simulation
- Resource constraint simulation
- Monitoring and metrics collection
- Automated test execution

### Success Criteria
- ✅ Pre-connected network formation tests implemented and passing
- ✅ Actual peer discovery mechanisms tested and verified
- ⚠️ **PENDING**: All high-priority tests implemented and passing
- Performance benchmarks established
- Failure recovery mechanisms verified
- Documentation for test scenarios
- Continuous integration integration

### Current Status Summary
- **Completed**: 
  - Multi-node network formation with pre-connected peers (Section 1.1)
  - Actual peer discovery and bootstrap scenarios (Section 1.2)
  - Node failure and recovery tests (Section 2.1)
- **Next Priority**: DHT mode interactions (Section 4.1)
- **Total Progress**: 3/10 major test categories completed (30%)

## Notes

- Tests should be designed to be deterministic and repeatable
- Performance tests may require dedicated hardware or cloud resources
- Some tests may need to run for extended periods to verify stability
- Mock implementations may be needed for external dependencies
- Test data should be representative of real-world usage patterns 