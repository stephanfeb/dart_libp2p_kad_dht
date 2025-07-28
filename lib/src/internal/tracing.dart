// Ported from go-libp2p-kad-dht/internal/tracing.go

import 'dart:convert';
import 'dart:typed_data';
import 'package:multibase/multibase.dart' as mb;

/// A simple tracer implementation for DHT operations.
/// 
/// This is a simplified version of the Go implementation which used OpenTelemetry.
/// A more complete implementation would use a proper tracing library.
class DhtTracer {
  /// The name of the tracer.
  static const String name = 'dart-libp2p-kad-dht';

  /// Starts a new span for a DHT operation.
  /// 
  /// Returns a [Span] object that should be completed when the operation is done.
  static Span startSpan(String operationName) {
    return Span('$name.$operationName');
  }

  /// Formats a DHT key into a suitable tracing attribute.
  /// 
  /// DHT keys can be either valid UTF-8 or binary, when they are derived from, for example, a multihash.
  /// This function ensures the key is properly encoded for tracing.
  static TraceAttribute keyAsAttribute(String name, String key) {
    final bytes = utf8.encode(key);

    // Check if the key is valid UTF-8
    try {
      utf8.decode(bytes);
      return TraceAttribute(name, key);
    } catch (_) {
      // Not valid UTF-8, encode as multibase
      try {
        final codec = mb.MultibaseCodec(encodeBase: mb.Multibase.base58btc);
        return TraceAttribute(name, codec.encode(Uint8List.fromList(key.codeUnits)));
      } catch (e) {
        // Should be unreachable
        throw Exception('Failed to encode key as multibase: $e');
      }
    }
  }
}

/// Represents a span in a trace.
class Span {
  final String name;
  final DateTime startTime;
  final Map<String, String> attributes = {};

  /// Creates a new span with the given name.
  Span(this.name) : startTime = DateTime.now();

  /// Adds an attribute to the span.
  void setAttribute(TraceAttribute attribute) {
    attributes[attribute.key] = attribute.value;
  }

  /// Records an error that occurred during the span.
  void setError(dynamic error) {
    attributes['error'] = error.toString();
  }

  /// Completes the span, recording its duration.
  void end() {
    final duration = DateTime.now().difference(startTime);
    // In a real implementation, this would record the span to a tracing system
    print('Span $name completed in ${duration.inMilliseconds}ms');
  }
}

/// Represents a key-value attribute for tracing.
class TraceAttribute {
  final String key;
  final String value;

  /// Creates a new attribute with the given key and value.
  const TraceAttribute(this.key, this.value);
}
