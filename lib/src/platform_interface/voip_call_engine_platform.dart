import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../models/audio_models.dart';
import '../models/call_events.dart';
import '../models/call_models.dart';
import '../models/engine_config.dart';
import 'method_channel_voip_call_engine.dart';

/// The interface that implementations of `voip_call_engine` must implement.
abstract class VoipCallEnginePlatform extends PlatformInterface {
  VoipCallEnginePlatform() : super(token: _token);

  static final Object _token = Object();

  static VoipCallEnginePlatform _instance = MethodChannelVoipCallEngine();

  /// The default instance of [VoipCallEnginePlatform] to use.
  static VoipCallEnginePlatform get instance => _instance;

  /// Platform-specific plugins should set this with their own platform-specific
  /// class that extends [VoipCallEnginePlatform] when they register themselves.
  static set instance(VoipCallEnginePlatform instance) {
    PlatformInterface.verify(instance, _token);
    _instance = instance;
  }

  /// Broadcast stream of all native + state-machine [CallEvent]s.
  Stream<CallEvent> get events {
    throw UnimplementedError('events has not been implemented.');
  }

  /// Initializes the native telecom subsystem (`CXProvider`, `PKPushRegistry`,
  /// `ConnectionService` / `CallsManager`, `WASAPI`, etc.) and drains any
  /// cold-start events accumulated while the Dart isolate was terminated.
  Future<List<CallEvent>> initialize(VoipEngineConfig config) {
    throw UnimplementedError('initialize() has not been implemented.');
  }

  /// Reports a new incoming call to the native OS telecom UI.
  Future<void> reportIncomingCall(CallRequest request) {
    throw UnimplementedError('reportIncomingCall() has not been implemented.');
  }

  /// Starts an outgoing call in the native OS telecom subsystem.
  Future<void> startOutgoingCall(CallRequest request) {
    throw UnimplementedError('startOutgoingCall() has not been implemented.');
  }

  /// Answers a ringing incoming call programmatically.
  Future<void> answerCall(String callId) {
    throw UnimplementedError('answerCall() has not been implemented.');
  }

  /// Ends or rejects a call and reports the [reason] to the native OS.
  Future<void> endCall(
    String callId, {
    CallEndReason reason = CallEndReason.localHangup,
  }) {
    throw UnimplementedError('endCall() has not been implemented.');
  }

  /// Places an active call on hold or resumes a held call.
  Future<void> setHold(String callId, {required bool isOnHold}) {
    throw UnimplementedError('setHold() has not been implemented.');
  }

  /// Mutes or unmutes the active microphone for [callId].
  Future<void> setMuted(String callId, {required bool isMuted}) {
    throw UnimplementedError('setMuted() has not been implemented.');
  }

  /// Sends DTMF tones (`0-9`, `*`, `#`) on [callId].
  Future<void> sendDtmf(String callId, String digits) {
    throw UnimplementedError('sendDtmf() has not been implemented.');
  }

  /// Notifies the native telecom layer that media transport is connected
  /// (e.g., iOS `CXProvider.reportOutgoingCall(with:connectedAt:)`).
  Future<void> reportCallConnected(String callId) {
    throw UnimplementedError('reportCallConnected() has not been implemented.');
  }

  /// Queries the current audio route and all available audio endpoints.
  Future<AudioRouteState> getAudioRouteState() {
    throw UnimplementedError('getAudioRouteState() has not been implemented.');
  }

  /// Switches the active voice audio route (`earpiece`, `speaker`, `bluetooth`, `wiredHeadset`)
  /// or selects a specific [deviceId] on desktop/web/Android 12+.
  Future<void> setAudioRoute(
    AudioRoute route, {
    String? deviceId,
  }) {
    throw UnimplementedError('setAudioRoute() has not been implemented.');
  }

  /// Returns the current VoIP Push token (e.g. iOS `PKPushRegistry` hex token) if available.
  Future<String?> getVoipPushToken() {
    throw UnimplementedError('getVoipPushToken() has not been implemented.');
  }
}
