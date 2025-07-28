import 'package:dart_libp2p/core/routing/routing.dart';

/// Exception thrown when a routing operation is not supported.
class RoutingNotSupportedException implements Exception {
  final String message;
  
  /// Creates a new routing not supported exception.
  RoutingNotSupportedException([this.message = 'Operation not supported']);
  
  @override
  String toString() => 'RoutingNotSupportedException: $message';
}