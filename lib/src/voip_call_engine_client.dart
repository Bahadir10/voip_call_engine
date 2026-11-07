import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'models/audio_models.dart';
import 'models/call_events.dart';
import 'models/call_models.dart';
import 'models/engine_config.dart';
import 'platform_interface/voip_call_engine_platform.dart';
import 'state_machine/call_state_machine.dart';
import 'utils/coercion_utils.dart';

/// Callback signature invoked when the native voice audio session (`AVAudioSession` /
/// `AudioManager`) is activated or deactivated by CallKit / ConnectionService.
typedef WebRtcAudioActivationHook = FutureOr<void> Function(bool isAudioEnabled);

/// Dedicated controller for inspecting and switching voice audio routes and
/// synchronizing WebRTC audio activation with CallKit/ConnectionService.
class VoipAudioController {
  VoipAudioController._(this._engine);

  final VoipCallEngine _engine;
  final Set<WebRtcAudioActivationHook> _webrtcHooks =
      <WebRtcAudioActivationHook>{};

  /// Whether the native OS voice audio session is currently active.
  bool get isAudioSessionActive =>
      _engine._stateMachine.isNativeAudioSessionActive;

  /// Registers a hook that will be invoked automatically when CallKit / ConnectionService
  /// activates or deactivates the voice audio session.
  ///
  /// Example with `flutter_webrtc`:
  /// ```dart
  /// VoipCallEngine.instance.audio.registerWebRtcHook((enabled) async {
  ///   await Helper.setAppleAudioConfiguration(...);
  /// });
  /// ```
  void registerWebRtcHook(WebRtcAudioActivationHook hook) {
    _webrtcHooks.add(hook);
    if (isAudioSessionActive) {
      unawaited(Future<void>.sync(() => hook(true)));
    }
  }

  /// Removes a previously registered [WebRtcAudioActivationHook].
  void unregisterWebRtcHook(WebRtcAudioActivationHook hook) {
    _webrtcHooks.remove(hook);
  }

  /// Queries the current [AudioRouteState] including all connected audio endpoints.
  Future<AudioRouteState> getRouteState() {
    return _engine._platform.getAudioRouteState();
  }

  /// Switches the active voice route (`earpiece`, `speaker`, `bluetooth`, `wiredHeadset`)
  /// or targets a specific hardware [deviceId].
  Future<void> setRoute(
    AudioRoute route, {
    String? deviceId,
  }) {
    return _engine._platform.setAudioRoute(route, deviceId: deviceId);
  }

  Future<void> _notifyWebRtcHooks(bool isActive) async {
    for (final hook in _webrtcHooks.toList()) {
      await hook(isActive);
    }
  }
}

/// High-level, production-grade controller for VoIP call lifecycles, CallKit,
/// ConnectionService, multi-call hold/swap, and deterministic audio routing.
class VoipCallEngine {
  /// Creates a custom [VoipCallEngine] instance (useful for isolated unit testing).
  @visibleForTesting
  VoipCallEngine.custom({
    VoipCallEnginePlatform? platform,
    bool requireAudioActivationBarrier = true,
    int maxConcurrentCalls = 2,
  }) : _platformOverride = platform {
    _initStateMachine(
      requireAudioActivationBarrier: requireAudioActivationBarrier,
      maxConcurrentCalls: maxConcurrentCalls,
    );
  }

  VoipCallEngine._internal() : _platformOverride = null {
    _initStateMachine(
      requireAudioActivationBarrier: true,
      maxConcurrentCalls: 2,
    );
  }

  /// Singleton instance of [VoipCallEngine].
  static final VoipCallEngine instance = VoipCallEngine._internal();

  final VoipCallEnginePlatform? _platformOverride;
  late CallStateMachine _stateMachine;
  late final VoipAudioController audio = VoipAudioController._(this);

  final StreamController<CallEvent> _mergedEventsController =
      StreamController<CallEvent>.broadcast();
  StreamSubscription<CallEvent>? _platformEventsSub;
  bool _isInitialized = false;

  VoipCallEnginePlatform get _platform =>
      _platformOverride ?? VoipCallEnginePlatform.instance;

  void _initStateMachine({
    required bool requireAudioActivationBarrier,
    required int maxConcurrentCalls,
  }) {
    _stateMachine = CallStateMachine(
      requireAudioActivationBarrier: requireAudioActivationBarrier,
      maxConcurrentCalls: maxConcurrentCalls,
      onEventEmitted: _mergedEventsController.add,
    );
  }

  /// Broadcast stream of all native and state-machine [CallEvent]s.
  Stream<CallEvent> get events => _mergedEventsController.stream;

  /// All currently active (non-ended) call sessions indexed by `callId`.
  UnmodifiableMapView<String, CallSession> get activeCalls =>
      _stateMachine.activeSessions;

  /// All tracked call sessions including ended ones.
  UnmodifiableMapView<String, CallSession> get allCalls =>
      _stateMachine.allSessions;

  /// Returns the [CallSession] for [callId] if present.
  CallSession? getCall(String callId) => _stateMachine.getSession(callId);

  /// Initializes the engine, configures native CallKit / ConnectionService / Desktop handlers,
  /// and drains any cold-start events accumulated while the Flutter Engine was terminated.
  Future<List<CallEvent>> initialize([
    VoipEngineConfig config = const VoipEngineConfig(),
  ]) async {
    _initStateMachine(
      requireAudioActivationBarrier: config.ios.useManualWebRtcAudioBarrier,
      maxConcurrentCalls: config.maxConcurrentCalls,
    );

    await _platformEventsSub?.cancel();
    _platformEventsSub = _platform.events.listen(_handlePlatformEvent);

    final drainedColdStartEvents = await _platform.initialize(config);
    _isInitialized = true;
    return drainedColdStartEvents;
  }

  /// Reports a new incoming call to the native OS telecom UI and state machine.
  Future<CallSession> reportIncomingCall(CallRequest request) async {
    _ensureListening();
    await _platform.reportIncomingCall(request);
    return _stateMachine.getSession(request.callId) ??
        _stateMachine.registerIncomingCall(request);
  }

  /// Starts a new outgoing call in the native OS telecom subsystem and state machine.
  Future<CallSession> startOutgoingCall(CallRequest request) async {
    _ensureListening();
    await _platform.startOutgoingCall(request);
    return _stateMachine.getSession(request.callId) ??
        _stateMachine.registerOutgoingCall(request);
  }

  /// Answers a ringing incoming call. Idempotent if already answered.
  Future<CallSession?> answerCall(String callId) async {
    final existing = _stateMachine.getSession(callId);
    if (existing != null &&
        (existing.state == CallState.connecting ||
            existing.state == CallState.active)) {
      return existing;
    }
    await _platform.answerCall(callId);
    return _stateMachine.markAnswered(callId);
  }

  /// Notifies the engine that WebRTC / SIP media transport is connected for [callId].
  ///
  /// Once both media transport AND native audio session activation (`AVAudioSession` /
  /// `AudioManager`) are ready, the call transitions to [CallState.active].
  Future<CallSession?> reportCallConnected(String callId) async {
    await _platform.reportCallConnected(callId);
    return _stateMachine.markMediaConnected(callId);
  }

  /// Places an active call on hold or resumes a held call.
  Future<CallSession?> setHold(
    String callId, {
    required bool isOnHold,
  }) async {
    await _platform.setHold(callId, isOnHold: isOnHold);
    return _stateMachine.setHold(callId, isOnHold: isOnHold);
  }

  /// Swaps an active call and a held call in a single atomic operation.
  Future<void> swapCalls({
    required String activeCallId,
    required String heldCallId,
  }) async {
    await _platform.setHold(activeCallId, isOnHold: true);
    await _platform.setHold(heldCallId, isOnHold: false);
    _stateMachine.swapCalls(
      activeCallId: activeCallId,
      heldCallId: heldCallId,
    );
  }

  /// Mutes or unmutes the microphone for [callId].
  Future<CallSession?> setMuted(
    String callId, {
    required bool isMuted,
  }) async {
    await _platform.setMuted(callId, isMuted: isMuted);
    return _stateMachine.setMuted(callId, isMuted: isMuted);
  }

  /// Sends RFC 4733 sanitized DTMF tones (`0-9`, `*`, `#`, `A-D`, `,`) on [callId].
  Future<void> sendDtmf(String callId, String digits) async {
    final sanitized = CoercionUtils.sanitizeDtmfDigits(digits);
    if (sanitized.isEmpty) return;
    await _platform.sendDtmf(callId, sanitized);
  }

  /// Ends or rejects a call with the specified [reason]. Idempotent if already ended.
  Future<CallSession?> endCall(
    String callId, {
    CallEndReason reason = CallEndReason.localHangup,
  }) async {
    final existing = _stateMachine.getSession(callId);
    if (existing != null && existing.state == CallState.ended) {
      return existing;
    }
    await _platform.endCall(callId, reason: reason);
    return _stateMachine.endCall(callId, reason: reason);
  }

  /// Returns the current VoIP Push token (e.g., iOS `PKPushRegistry` token) if available.
  Future<String?> getVoipPushToken() {
    return _platform.getVoipPushToken();
  }

  void _ensureListening() {
    if (!_isInitialized && _platformEventsSub == null) {
      _platformEventsSub = _platform.events.listen(_handlePlatformEvent);
    }
  }

  void _handlePlatformEvent(CallEvent event) {
    _stateMachine.applyNativeEvent(event);
    _mergedEventsController.add(event);

    if (event is CallAudioSessionActivationChanged) {
      unawaited(audio._notifyWebRtcHooks(event.isActive));
    }
  }

  /// Disposes internal stream subscriptions and watchdog timers.
  @visibleForTesting
  Future<void> dispose() async {
    _stateMachine.dispose();
    await _platformEventsSub?.cancel();
    _platformEventsSub = null;
    await _mergedEventsController.close();
  }
}
