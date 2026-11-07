import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/audio_models.dart';
import '../models/call_events.dart';
import '../models/call_models.dart';
import '../models/engine_config.dart';
import 'voip_call_engine_platform.dart';

/// Default binary-messenger implementation of [VoipCallEnginePlatform] communicating
/// with the native iOS, Android, Windows, and macOS plugins.
class MethodChannelVoipCallEngine extends VoipCallEnginePlatform {
  MethodChannelVoipCallEngine({
    MethodChannel? methodChannel,
  }) : _channel = methodChannel ??
            const MethodChannel('dev.flutter.telecom/voip_call_engine') {
    _channel.setMethodCallHandler(_handleNativeCallback);
  }

  final MethodChannel _channel;
  final StreamController<CallEvent> _eventController =
      StreamController<CallEvent>.broadcast();

  @visibleForTesting
  MethodChannel get channel => _channel;

  @override
  Stream<CallEvent> get events => _eventController.stream;

  Future<dynamic> _handleNativeCallback(MethodCall call) async {
    if (call.method == 'onNativeCallEvent') {
      final raw = call.arguments as Map<Object?, Object?>?;
      if (raw != null) {
        final event = CallEvent.fromMap(raw);
        _eventController.add(event);
      }
    }
    return null;
  }

  @override
  Future<List<CallEvent>> initialize(VoipEngineConfig config) async {
    final rawBufferedEvents = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'initializeAndDrainColdStartBuffer',
      config.toMap(),
    );
    final drained = <CallEvent>[];
    if (rawBufferedEvents != null) {
      for (final raw in rawBufferedEvents) {
        final copy = Map<Object?, Object?>.from(raw);
        copy['fromColdStartBuffer'] = true;
        final event = CallEvent.fromMap(copy);
        drained.add(event);
        _eventController.add(event);
      }
    }
    return drained;
  }

  @override
  Future<void> reportIncomingCall(CallRequest request) async {
    await _channel.invokeMethod<void>(
      'reportIncomingCall',
      request.toMap(),
    );
  }

  @override
  Future<void> startOutgoingCall(CallRequest request) async {
    await _channel.invokeMethod<void>(
      'startOutgoingCall',
      request.toMap(),
    );
  }

  @override
  Future<void> answerCall(String callId) async {
    await _channel.invokeMethod<void>(
      'answerCall',
      <String, Object?>{'callId': callId},
    );
  }

  @override
  Future<void> endCall(
    String callId, {
    CallEndReason reason = CallEndReason.localHangup,
  }) async {
    await _channel.invokeMethod<void>(
      'endCall',
      <String, Object?>{
        'callId': callId,
        'reason': reason.name,
      },
    );
  }

  @override
  Future<void> setHold(String callId, {required bool isOnHold}) async {
    await _channel.invokeMethod<void>(
      'setHold',
      <String, Object?>{
        'callId': callId,
        'isOnHold': isOnHold,
      },
    );
  }

  @override
  Future<void> setMuted(String callId, {required bool isMuted}) async {
    await _channel.invokeMethod<void>(
      'setMuted',
      <String, Object?>{
        'callId': callId,
        'isMuted': isMuted,
      },
    );
  }

  @override
  Future<void> sendDtmf(String callId, String digits) async {
    await _channel.invokeMethod<void>(
      'sendDtmf',
      <String, Object?>{
        'callId': callId,
        'digits': digits,
      },
    );
  }

  @override
  Future<void> reportCallConnected(String callId) async {
    await _channel.invokeMethod<void>(
      'reportCallConnected',
      <String, Object?>{'callId': callId},
    );
  }

  @override
  Future<AudioRouteState> getAudioRouteState() async {
    final map = await _channel.invokeMapMethod<Object?, Object?>(
      'getAudioRouteState',
    );
    if (map == null) {
      return const AudioRouteState(
        activeRoute: AudioRoute.earpiece,
        availableRoutes: <AudioRoute>[
          AudioRoute.earpiece,
          AudioRoute.speaker,
        ],
      );
    }
    return AudioRouteState.fromMap(map);
  }

  @override
  Future<void> setAudioRoute(
    AudioRoute route, {
    String? deviceId,
  }) async {
    await _channel.invokeMethod<void>(
      'setAudioRoute',
      <String, Object?>{
        'route': route.name,
        'deviceId': deviceId,
      },
    );
  }

  @override
  Future<String?> getVoipPushToken() async {
    return _channel.invokeMethod<String>('getVoipPushToken');
  }
}
