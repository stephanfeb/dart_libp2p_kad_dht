//
//  Generated code. Do not modify.
//  source: dht.proto
//
// @dart = 2.12

// ignore_for_file: annotate_overrides, camel_case_types
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use messageDescriptor instead')
const Message$json = {
  '1': 'Message',
  '2': [
    {'1': 'type', '3': 1, '4': 1, '5': 14, '6': '.record.pb.Message.MessageType', '10': 'type'},
    {'1': 'cluster_level_raw', '3': 10, '4': 1, '5': 5, '10': 'clusterLevelRaw'},
    {'1': 'key', '3': 2, '4': 1, '5': 12, '10': 'key'},
    {'1': 'record', '3': 3, '4': 1, '5': 11, '6': '.record.pb.Record', '10': 'record'},
    {'1': 'closer_peers', '3': 8, '4': 3, '5': 11, '6': '.record.pb.Message.Peer', '10': 'closerPeers'},
    {'1': 'provider_peers', '3': 9, '4': 3, '5': 11, '6': '.record.pb.Message.Peer', '10': 'providerPeers'},
  ],
  '3': [Message_Peer$json],
  '4': [Message_MessageType$json, Message_ConnectionType$json],
};

@$core.Deprecated('Use messageDescriptor instead')
const Message_Peer$json = {
  '1': 'Peer',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 12, '10': 'id'},
    {'1': 'addrs', '3': 2, '4': 3, '5': 12, '10': 'addrs'},
    {'1': 'connection', '3': 3, '4': 1, '5': 14, '6': '.record.pb.Message.ConnectionType', '10': 'connection'},
  ],
};

@$core.Deprecated('Use messageDescriptor instead')
const Message_MessageType$json = {
  '1': 'MessageType',
  '2': [
    {'1': 'PUT_VALUE', '2': 0},
    {'1': 'GET_VALUE', '2': 1},
    {'1': 'ADD_PROVIDER', '2': 2},
    {'1': 'GET_PROVIDERS', '2': 3},
    {'1': 'FIND_NODE', '2': 4},
    {'1': 'PING', '2': 5},
  ],
};

@$core.Deprecated('Use messageDescriptor instead')
const Message_ConnectionType$json = {
  '1': 'ConnectionType',
  '2': [
    {'1': 'NOT_CONNECTED', '2': 0},
    {'1': 'CONNECTED', '2': 1},
    {'1': 'CAN_CONNECT', '2': 2},
    {'1': 'CANNOT_CONNECT', '2': 3},
  ],
};

/// Descriptor for `Message`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List messageDescriptor = $convert.base64Decode(
    'CgdNZXNzYWdlEjIKBHR5cGUYASABKA4yHi5yZWNvcmQucGIuTWVzc2FnZS5NZXNzYWdlVHlwZV'
    'IEdHlwZRIqChFjbHVzdGVyX2xldmVsX3JhdxgKIAEoBVIPY2x1c3RlckxldmVsUmF3EhAKA2tl'
    'eRgCIAEoDFIDa2V5EikKBnJlY29yZBgDIAEoCzIRLnJlY29yZC5wYi5SZWNvcmRSBnJlY29yZB'
    'I6CgxjbG9zZXJfcGVlcnMYCCADKAsyFy5yZWNvcmQucGIuTWVzc2FnZS5QZWVyUgtjbG9zZXJQ'
    'ZWVycxI+Cg5wcm92aWRlcl9wZWVycxgJIAMoCzIXLnJlY29yZC5wYi5NZXNzYWdlLlBlZXJSDX'
    'Byb3ZpZGVyUGVlcnMabwoEUGVlchIOCgJpZBgBIAEoDFICaWQSFAoFYWRkcnMYAiADKAxSBWFk'
    'ZHJzEkEKCmNvbm5lY3Rpb24YAyABKA4yIS5yZWNvcmQucGIuTWVzc2FnZS5Db25uZWN0aW9uVH'
    'lwZVIKY29ubmVjdGlvbiJpCgtNZXNzYWdlVHlwZRINCglQVVRfVkFMVUUQABINCglHRVRfVkFM'
    'VUUQARIQCgxBRERfUFJPVklERVIQAhIRCg1HRVRfUFJPVklERVJTEAMSDQoJRklORF9OT0RFEA'
    'QSCAoEUElORxAFIlcKDkNvbm5lY3Rpb25UeXBlEhEKDU5PVF9DT05ORUNURUQQABINCglDT05O'
    'RUNURUQQARIPCgtDQU5fQ09OTkVDVBACEhIKDkNBTk5PVF9DT05ORUNUEAM=');

