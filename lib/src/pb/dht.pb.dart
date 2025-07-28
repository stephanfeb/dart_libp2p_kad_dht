//
//  Generated code. Do not modify.
//  source: dht.proto
//
// @dart = 2.12

// ignore_for_file: annotate_overrides, camel_case_types
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'dht.pbenum.dart';
import 'record.pb.dart' as $0;

export 'dht.pbenum.dart';

class Message_Peer extends $pb.GeneratedMessage {
  factory Message_Peer() => create();
  Message_Peer._() : super();
  factory Message_Peer.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory Message_Peer.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'Message.Peer', package: const $pb.PackageName(_omitMessageNames ? '' : 'record.pb'), createEmptyInstance: create)
    ..a<$core.List<$core.int>>(1, _omitFieldNames ? '' : 'id', $pb.PbFieldType.OY)
    ..p<$core.List<$core.int>>(2, _omitFieldNames ? '' : 'addrs', $pb.PbFieldType.PY)
    ..e<Message_ConnectionType>(3, _omitFieldNames ? '' : 'connection', $pb.PbFieldType.OE, defaultOrMaker: Message_ConnectionType.NOT_CONNECTED, valueOf: Message_ConnectionType.valueOf, enumValues: Message_ConnectionType.values)
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  Message_Peer clone() => Message_Peer()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  Message_Peer copyWith(void Function(Message_Peer) updates) => super.copyWith((message) => updates(message as Message_Peer)) as Message_Peer;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Message_Peer create() => Message_Peer._();
  Message_Peer createEmptyInstance() => create();
  static $pb.PbList<Message_Peer> createRepeated() => $pb.PbList<Message_Peer>();
  @$core.pragma('dart2js:noInline')
  static Message_Peer getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Message_Peer>(create);
  static Message_Peer? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get id => $_getN(0);
  @$pb.TagNumber(1)
  set id($core.List<$core.int> v) { $_setBytes(0, v); }
  @$pb.TagNumber(1)
  $core.bool hasId() => $_has(0);
  @$pb.TagNumber(1)
  void clearId() => clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.List<$core.int>> get addrs => $_getList(1);

  @$pb.TagNumber(3)
  Message_ConnectionType get connection => $_getN(2);
  @$pb.TagNumber(3)
  set connection(Message_ConnectionType v) { setField(3, v); }
  @$pb.TagNumber(3)
  $core.bool hasConnection() => $_has(2);
  @$pb.TagNumber(3)
  void clearConnection() => clearField(3);
}

class Message extends $pb.GeneratedMessage {
  factory Message() => create();
  Message._() : super();
  factory Message.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory Message.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'Message', package: const $pb.PackageName(_omitMessageNames ? '' : 'record.pb'), createEmptyInstance: create)
    ..e<Message_MessageType>(1, _omitFieldNames ? '' : 'type', $pb.PbFieldType.OE, defaultOrMaker: Message_MessageType.PUT_VALUE, valueOf: Message_MessageType.valueOf, enumValues: Message_MessageType.values)
    ..a<$core.List<$core.int>>(2, _omitFieldNames ? '' : 'key', $pb.PbFieldType.OY)
    ..aOM<$0.Record>(3, _omitFieldNames ? '' : 'record', subBuilder: $0.Record.create)
    ..pc<Message_Peer>(8, _omitFieldNames ? '' : 'closerPeers', $pb.PbFieldType.PM, subBuilder: Message_Peer.create)
    ..pc<Message_Peer>(9, _omitFieldNames ? '' : 'providerPeers', $pb.PbFieldType.PM, subBuilder: Message_Peer.create)
    ..a<$core.int>(10, _omitFieldNames ? '' : 'clusterLevelRaw', $pb.PbFieldType.O3)
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  Message clone() => Message()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  Message copyWith(void Function(Message) updates) => super.copyWith((message) => updates(message as Message)) as Message;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Message create() => Message._();
  Message createEmptyInstance() => create();
  static $pb.PbList<Message> createRepeated() => $pb.PbList<Message>();
  @$core.pragma('dart2js:noInline')
  static Message getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Message>(create);
  static Message? _defaultInstance;

  @$pb.TagNumber(1)
  Message_MessageType get type => $_getN(0);
  @$pb.TagNumber(1)
  set type(Message_MessageType v) { setField(1, v); }
  @$pb.TagNumber(1)
  $core.bool hasType() => $_has(0);
  @$pb.TagNumber(1)
  void clearType() => clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.int> get key => $_getN(1);
  @$pb.TagNumber(2)
  set key($core.List<$core.int> v) { $_setBytes(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasKey() => $_has(1);
  @$pb.TagNumber(2)
  void clearKey() => clearField(2);

  @$pb.TagNumber(3)
  $0.Record get record => $_getN(2);
  @$pb.TagNumber(3)
  set record($0.Record v) { setField(3, v); }
  @$pb.TagNumber(3)
  $core.bool hasRecord() => $_has(2);
  @$pb.TagNumber(3)
  void clearRecord() => clearField(3);
  @$pb.TagNumber(3)
  $0.Record ensureRecord() => $_ensure(2);

  @$pb.TagNumber(8)
  $core.List<Message_Peer> get closerPeers => $_getList(3);

  @$pb.TagNumber(9)
  $core.List<Message_Peer> get providerPeers => $_getList(4);

  @$pb.TagNumber(10)
  $core.int get clusterLevelRaw => $_getIZ(5);
  @$pb.TagNumber(10)
  set clusterLevelRaw($core.int v) { $_setSignedInt32(5, v); }
  @$pb.TagNumber(10)
  $core.bool hasClusterLevelRaw() => $_has(5);
  @$pb.TagNumber(10)
  void clearClusterLevelRaw() => clearField(10);
}


const _omitFieldNames = $core.bool.fromEnvironment('protobuf.omit_field_names');
const _omitMessageNames = $core.bool.fromEnvironment('protobuf.omit_message_names');
