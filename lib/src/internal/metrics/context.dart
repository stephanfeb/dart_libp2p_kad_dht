// Ported from go-libp2p-kad-dht/internal/metrics/context.dart

import 'dart:async';

/// A key for storing attributes in a Zone.
const String _attributeZoneKey = 'dht_attributes';

/// Represents a set of key-value attributes for metrics.
class AttributeSet {
  final Map<String, String> _attributes = {};
  
  /// Creates a new attribute set with the given key-value pairs.
  AttributeSet(Map<String, String> attributes) {
    _attributes.addAll(attributes);
  }
  
  /// Creates an empty attribute set.
  AttributeSet.empty();
  
  /// Gets the value for a key, or null if not present.
  String? operator [](String key) => _attributes[key];
  
  /// Adds all attributes from another set to this one.
  void addAll(AttributeSet other) {
    _attributes.addAll(other._attributes);
  }
  
  /// Returns a copy of the internal attribute map.
  Map<String, String> toMap() => Map.from(_attributes);
}

/// A key-value attribute for metrics.
class Attribute {
  final String key;
  final String value;
  
  /// Creates a new attribute with the given key and value.
  const Attribute(this.key, this.value);
}

/// Runs a function with attributes added to the current Zone.
/// 
/// This is the Dart equivalent of ContextWithAttributes in Go.
T runWithAttributes<T>(T Function() fn, List<Attribute> attributes) {
  // Get existing attributes from the current zone, if any
  final currentZone = Zone.current;
  final existingAttrs = currentZone[_attributeZoneKey] as AttributeSet?;
  
  // Create a new attribute set with the given attributes
  final newAttrs = AttributeSet.empty();
  if (existingAttrs != null) {
    newAttrs.addAll(existingAttrs);
  }
  
  // Add the new attributes
  for (final attr in attributes) {
    newAttrs._attributes[attr.key] = attr.value;
  }
  
  // Run the function in a new zone with the updated attributes
  return runZoned(
    fn,
    zoneValues: {_attributeZoneKey: newAttrs},
  );
}

/// Gets the attributes from the current Zone.
/// 
/// This is the Dart equivalent of AttributesFromContext in Go.
AttributeSet attributesFromZone() {
  final currentZone = Zone.current;
  final attrs = currentZone[_attributeZoneKey] as AttributeSet?;
  return attrs ?? AttributeSet.empty();
}