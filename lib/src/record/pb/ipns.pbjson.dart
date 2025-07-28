//
//  Generated code. Do not modify.
//  source: ipns.proto
//
// @dart = 2.12

// ignore_for_file: annotate_overrides, camel_case_types
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use ipnsEntryDescriptor instead')
const IpnsEntry$json = {
  '1': 'IpnsEntry',
  '2': [
    {'1': 'value', '3': 1, '4': 1, '5': 12, '10': 'value'},
    {'1': 'signatureV1', '3': 2, '4': 1, '5': 12, '10': 'signatureV1'},
    {'1': 'validityType', '3': 3, '4': 1, '5': 14, '6': '.ipns.pb.IpnsEntry.ValidityType', '10': 'validityType'},
    {'1': 'validity', '3': 4, '4': 1, '5': 12, '10': 'validity'},
    {'1': 'sequence', '3': 5, '4': 1, '5': 4, '10': 'sequence'},
    {'1': 'ttl', '3': 6, '4': 1, '5': 4, '10': 'ttl'},
    {'1': 'pubKey', '3': 7, '4': 1, '5': 12, '10': 'pubKey'},
    {'1': 'signatureV2', '3': 8, '4': 1, '5': 12, '10': 'signatureV2'},
    {'1': 'data', '3': 9, '4': 1, '5': 12, '10': 'data'},
  ],
  '4': [IpnsEntry_ValidityType$json],
};

@$core.Deprecated('Use ipnsEntryDescriptor instead')
const IpnsEntry_ValidityType$json = {
  '1': 'ValidityType',
  '2': [
    {'1': 'EOL', '2': 0},
  ],
};

/// Descriptor for `IpnsEntry`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List ipnsEntryDescriptor = $convert.base64Decode(
    'CglJcG5zRW50cnkSFAoFdmFsdWUYASABKAxSBXZhbHVlEiAKC3NpZ25hdHVyZVYxGAIgASgMUg'
    'tzaWduYXR1cmVWMRJDCgx2YWxpZGl0eVR5cGUYAyABKA4yHy5pcG5zLnBiLklwbnNFbnRyeS5W'
    'YWxpZGl0eVR5cGVSDHZhbGlkaXR5VHlwZRIaCgh2YWxpZGl0eRgEIAEoDFIIdmFsaWRpdHkSGg'
    'oIc2VxdWVuY2UYBSABKARSCHNlcXVlbmNlEhAKA3R0bBgGIAEoBFIDdHRsEhYKBnB1YktleRgH'
    'IAEoDFIGcHViS2V5EiAKC3NpZ25hdHVyZVYyGAggASgMUgtzaWduYXR1cmVWMhISCgRkYXRhGA'
    'kgASgMUgRkYXRhIhcKDFZhbGlkaXR5VHlwZRIHCgNFT0wQAA==');

@$core.Deprecated('Use ipnsSignatureV2CheckerDescriptor instead')
const IpnsSignatureV2Checker$json = {
  '1': 'IpnsSignatureV2Checker',
  '2': [
    {'1': 'pubKey', '3': 7, '4': 1, '5': 12, '10': 'pubKey'},
    {'1': 'signatureV2', '3': 8, '4': 1, '5': 12, '10': 'signatureV2'},
  ],
};

/// Descriptor for `IpnsSignatureV2Checker`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List ipnsSignatureV2CheckerDescriptor = $convert.base64Decode(
    'ChZJcG5zU2lnbmF0dXJlVjJDaGVja2VyEhYKBnB1YktleRgHIAEoDFIGcHViS2V5EiAKC3NpZ2'
    '5hdHVyZVYyGAggASgMUgtzaWduYXR1cmVWMg==');

