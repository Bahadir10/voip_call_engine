import 'dart:async';

import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'src/models/audio_models.dart';
import 'src/models/call_events.dart';
import 'src/models/call_models.dart';
import 'src/models/engine_config.dart';
import 'src/platform_interface/voip_call_engine_platform.dart';

/// Web implementation of [VoipCallEnginePlatform].
class VoipCallEngineWeb extends VoipCallEnginePlatform {
  VoipCallEngineWeb();

  /// Registers [VoipCallEngineWeb] as the default platform instance on Web.
  static void registerWith(Registrar registrar) {
    VoipCallEnginePlatform.instance = VoipCallEngineWeb();
  }

  final StreamController<CallEvent> _eventController =
      StreamController<CallEvent>.broadcast();

  AudioRoute _activeRoute = AudioRoute.speaker;
  bool _isAudioSessionActive = false;
  bool _isMuted = false;
  int _sequenceCounter = 0;

  @override
  Stream<CallEvent> get events => _eventController.stream;

  @override
  Future<List<CallEvent>> initialize(VoipEngineConfig config) async {
    return const <CallEvent>[];
  }

  @override
  Future<void> reportIncomingCall(CallRequest request) async {
    _emit(
      CallIncomingReceived(
        request: request,
        reportedViaPushKit: false,
        timestamp: DateTime.now().toUtc(),
        sequenceNumber: ++_sequenceCounter,
      ),
    );
  }

  @override
  Future<void> startOutgoingCall(CallRequest request) async {
    _isAudioSessionActive = true;
    final now = DateTime.now().toUtc();
    _emit(
      CallOutgoingStarted(
        callId: request.callId,
        request: request,
        timestamp: now,
        sequenceNumber: ++_sequenceCounter,
      ),
    );
    _emit(
      CallAudioSessionActivationChanged(
        isActive: true,
        timestamp: now,
        sequenceNumber: ++_sequenceCounter,
      ),
    );
  }

  @override
  Future<void> answerCall(String callId) async {
    _isAudioSessionActive = true;
    final now = DateTime.now().toUtc();
    _emit(
      CallAnswered(
        callId: callId,
        source: CallActionSource.appUi,
        timestamp: now,
        sequenceNumber: ++_sequenceCounter,
      ),
    );
    _emit(
      CallAudioSessionActivationChanged(
        isActive: true,
        timestamp: now,
        sequenceNumber: ++_sequenceCounter,
      ),
    );
  }

  @override
  Future<void> endCall(
    String callId, {
    CallEndReason reason = CallEndReason.localHangup,
  }) async {
    _isAudioSessionActive = false;
    _emit(
      CallEnded(
        callId: callId,
        reason: reason,
        source: CallActionSource.appUi,
        timestamp: DateTime.now().toUtc(),
        sequenceNumber: ++_sequenceCounter,
      ),
    );
  }

  @override
  Future<void> setHold(String callId, {required bool isOnHold}) async {
    _emit(
      CallHeldChanged(
        callId: callId,
        isOnHold: isOnHold,
        heldBySystem: false,
        source: CallActionSource.appUi,
        timestamp: DateTime.now().toUtc(),
        sequenceNumber: ++_sequenceCounter,
      ),
    );
  }

  @override
  Future<void> setMuted(String callId, {required bool isMuted}) async {
    _isMuted = isMuted;
    _emit(
      CallMutedChanged(
        callId: callId,
        isMuted: isMuted,
        source: CallActionSource.appUi,
        timestamp: DateTime.now().toUtc(),
        sequenceNumber: ++_sequenceCounter,
      ),
    );
  }

  @override
  Future<void> sendDtmf(String callId, String digits) async {
    _emit(
      CallDtmfTonePlayed(
        callId: callId,
        digits: digits,
        timestamp: DateTime.now().toUtc(),
        sequenceNumber: ++_sequenceCounter,
      ),
    );
  }

  @override
  Future<void> reportCallConnected(String callId) async {
    _isAudioSessionActive = true;
    _emit(
      CallAudioSessionActivationChanged(
        isActive: true,
        timestamp: DateTime.now().toUtc(),
        sequenceNumber: ++_sequenceCounter,
      ),
    );
  }

  @override
  Future<AudioRouteState> getAudioRouteState() async {
    return AudioRouteState(
      activeRoute: _activeRoute,
      availableRoutes: const <AudioRoute>[
        AudioRoute.speaker,
        AudioRoute.wiredHeadset,
        AudioRoute.bluetooth,
        AudioRoute.systemDefault,
      ],
      activeDevice: AudioDevice(
        id: 'web_default_sink',
        name: 'Browser Audio Output (${_activeRoute.name})',
        route: _activeRoute,
        isDefault: true,
      ),
      availableDevices: const <AudioDevice>[
        AudioDevice(
          id: 'web_default_sink',
          name: 'Default Browser Speaker',
          route: AudioRoute.speaker,
          isDefault: true,
        ),
        AudioDevice(
          id: 'web_headset_sink',
          name: 'Headset / USB Audio Sink',
          route: AudioRoute.wiredHeadset,
        ),
      ],
      isAudioSessionActive: _isAudioSessionActive,
      isMicrophoneMuted: _isMuted,
    );
  }

  @override
  Future<void> setAudioRoute(
    AudioRoute route, {
    String? deviceId,
  }) async {
    _activeRoute = route;
    final state = await getAudioRouteState();
    _emit(
      CallAudioRouteChanged(
        routeState: state,
        reason: 'setSinkId',
        timestamp: DateTime.now().toUtc(),
        sequenceNumber: ++_sequenceCounter,
      ),
    );
  }

  @override
  Future<String?> getVoipPushToken() async => null;

  void _emit(CallEvent event) {
    _eventController.add(event);
  }
}
