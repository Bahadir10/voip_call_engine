import 'package:meta/meta.dart';

import '../utils/coercion_utils.dart';
import 'audio_models.dart';
import 'call_models.dart';

/// Base sealed class for all VoIP lifecycle, audio routing, and push token events.
///
/// Supports exhaustive Dart 3 `switch (event)` pattern matching.
@immutable
sealed class CallEvent {
  const CallEvent({
    required this.timestamp,
    this.sequenceNumber = 0,
    this.fromColdStartBuffer = false,
  });

  /// Deserialize a native event map emitted by the platform implementation or cold-start ring buffer.
  factory CallEvent.fromMap(Map<Object?, Object?> map) {
    final type = CoercionUtils.asString(map['type'], fallback: 'unknown');
    final timestampMs = CoercionUtils.asInt(
      map['timestampMs'],
      fallback: DateTime.now().toUtc().millisecondsSinceEpoch,
      min: 0,
    );
    final timestamp =
        DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true);
    final sequenceNumber = CoercionUtils.asInt(map['sequenceNumber']);
    final fromColdStart = CoercionUtils.asBool(map['fromColdStartBuffer']);

    switch (type) {
      case 'voipPushTokenUpdated':
        return VoipPushTokenUpdated(
          token: CoercionUtils.asString(map['token']),
          environment:
              CoercionUtils.asString(map['environment'], fallback: 'production'),
          timestamp: timestamp,
          sequenceNumber: sequenceNumber,
          fromColdStartBuffer: fromColdStart,
        );
      case 'incomingReceived':
        return CallIncomingReceived(
          request: CallRequest.fromMap(CoercionUtils.asObjectMap(map['request'])),
          reportedViaPushKit: CoercionUtils.asBool(map['reportedViaPushKit']),
          timestamp: timestamp,
          sequenceNumber: sequenceNumber,
          fromColdStartBuffer: fromColdStart,
        );
      case 'outgoingStarted':
        final req =
            CallRequest.fromMap(CoercionUtils.asObjectMap(map['request']));
        return CallOutgoingStarted(
          callId: CoercionUtils.asString(map['callId'], fallback: req.callId),
          request: req,
          timestamp: timestamp,
          sequenceNumber: sequenceNumber,
          fromColdStartBuffer: fromColdStart,
        );
      case 'answered':
        return CallAnswered(
          callId: CoercionUtils.asString(map['callId']),
          source: _parseSource(CoercionUtils.asNullableString(map['source'])),
          timestamp: timestamp,
          sequenceNumber: sequenceNumber,
          fromColdStartBuffer: fromColdStart,
        );
      case 'ended':
        return CallEnded(
          callId: CoercionUtils.asString(map['callId']),
          reason: _parseEndReason(CoercionUtils.asNullableString(map['reason'])),
          source: _parseSource(CoercionUtils.asNullableString(map['source'])),
          timestamp: timestamp,
          sequenceNumber: sequenceNumber,
          fromColdStartBuffer: fromColdStart,
        );
      case 'heldChanged':
        return CallHeldChanged(
          callId: CoercionUtils.asString(map['callId']),
          isOnHold: CoercionUtils.asBool(map['isOnHold']),
          heldBySystem: CoercionUtils.asBool(map['heldBySystem']),
          source: _parseSource(CoercionUtils.asNullableString(map['source'])),
          timestamp: timestamp,
          sequenceNumber: sequenceNumber,
          fromColdStartBuffer: fromColdStart,
        );
      case 'mutedChanged':
        return CallMutedChanged(
          callId: CoercionUtils.asString(map['callId']),
          isMuted: CoercionUtils.asBool(map['isMuted']),
          source: _parseSource(CoercionUtils.asNullableString(map['source'])),
          timestamp: timestamp,
          sequenceNumber: sequenceNumber,
          fromColdStartBuffer: fromColdStart,
        );
      case 'dtmfReceived':
        return CallDtmfTonePlayed(
          callId: CoercionUtils.asString(map['callId']),
          digits: CoercionUtils.sanitizeDtmfDigits(
            CoercionUtils.asString(map['digits']),
          ),
          timestamp: timestamp,
          sequenceNumber: sequenceNumber,
          fromColdStartBuffer: fromColdStart,
        );
      case 'audioSessionActivationChanged':
        return CallAudioSessionActivationChanged(
          isActive: CoercionUtils.asBool(map['isActive']),
          timestamp: timestamp,
          sequenceNumber: sequenceNumber,
          fromColdStartBuffer: fromColdStart,
        );
      case 'audioRouteChanged':
        return CallAudioRouteChanged(
          routeState: AudioRouteState.fromMap(
            CoercionUtils.asObjectMap(map['routeState']),
          ),
          reason: CoercionUtils.asString(
            map['reason'],
            fallback: 'routeConfigurationChange',
          ),
          timestamp: timestamp,
          sequenceNumber: sequenceNumber,
          fromColdStartBuffer: fromColdStart,
        );
      case 'stateTransitioned':
        final prevStr =
            CoercionUtils.asString(map['previousState'], fallback: 'idle');
        return CallStateTransitioned(
          session: CallSession.fromMap(CoercionUtils.asObjectMap(map['session'])),
          previousState: CallState.values.firstWhere(
            (e) => e.name == prevStr,
            orElse: () => CallState.idle,
          ),
          timestamp: timestamp,
          sequenceNumber: sequenceNumber,
          fromColdStartBuffer: fromColdStart,
        );
      default:
        final rawDetails = CoercionUtils.asObjectMap(map['details']);
        return CallDiagnosticEvent(
          code: CoercionUtils.asString(map['code'], fallback: type),
          message: CoercionUtils.asString(
            map['message'],
            fallback: 'Unhandled native event',
          ),
          details: rawDetails.map(
            (k, v) => MapEntry(k.toString(), v),
          ),
          timestamp: timestamp,
          sequenceNumber: sequenceNumber,
          fromColdStartBuffer: fromColdStart,
        );
    }
  }

  final DateTime timestamp;
  final int sequenceNumber;

  /// True if this event occurred while the Flutter engine was terminated/initializing
  /// and was replayed from the native ring buffer upon `handshakeReady()`.
  final bool fromColdStartBuffer;

  static CallActionSource _parseSource(String? name) {
    if (name == null) return CallActionSource.systemUi;
    return CallActionSource.values.firstWhere(
      (e) => e.name == name,
      orElse: () => CallActionSource.systemUi,
    );
  }

  static CallEndReason _parseEndReason(String? name) {
    if (name == null) return CallEndReason.localHangup;
    return CallEndReason.values.firstWhere(
      (e) => e.name == name,
      orElse: () => CallEndReason.localHangup,
    );
  }
}

/// Emitted when iOS PushKit (`PKPushRegistry`) or Android FCM token is registered/refreshed.
final class VoipPushTokenUpdated extends CallEvent {
  const VoipPushTokenUpdated({
    required this.token,
    required this.environment,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  final String token;
  final String environment;
}

/// Emitted when an incoming call has been reported to the native telecom subsystem.
final class CallIncomingReceived extends CallEvent {
  const CallIncomingReceived({
    required this.request,
    required this.reportedViaPushKit,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  final CallRequest request;
  final bool reportedViaPushKit;
}

/// Emitted when an outgoing call has been initiated.
final class CallOutgoingStarted extends CallEvent {
  const CallOutgoingStarted({
    required this.callId,
    required this.request,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  final String callId;
  final CallRequest request;
}

/// Emitted when the user (or hardware accessory) answers an incoming call.
final class CallAnswered extends CallEvent {
  const CallAnswered({
    required this.callId,
    required this.source,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  final String callId;
  final CallActionSource source;
}

/// Emitted when a call ends or is rejected.
final class CallEnded extends CallEvent {
  const CallEnded({
    required this.callId,
    required this.reason,
    required this.source,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  final String callId;
  final CallEndReason reason;
  final CallActionSource source;
}

/// Emitted when a call's hold status changes (including automatic GSM interruption hold).
final class CallHeldChanged extends CallEvent {
  const CallHeldChanged({
    required this.callId,
    required this.isOnHold,
    required this.heldBySystem,
    required this.source,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  final String callId;
  final bool isOnHold;
  final bool heldBySystem;
  final CallActionSource source;
}

/// Emitted when a call's microphone mute status changes.
final class CallMutedChanged extends CallEvent {
  const CallMutedChanged({
    required this.callId,
    required this.isMuted,
    required this.source,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  final String callId;
  final bool isMuted;
  final CallActionSource source;
}

/// Emitted when DTMF digits are played during an active call.
final class CallDtmfTonePlayed extends CallEvent {
  const CallDtmfTonePlayed({
    required this.callId,
    required this.digits,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  final String callId;
  final String digits;
}

/// Emitted when the native voice audio session (`AVAudioSession` / `AudioManager`)
/// is activated or deactivated by CallKit / ConnectionService.
///
/// **CRITICAL FOR WEBRTC:** Do not enable WebRTC audio playout/recording on iOS
/// until `isActive == true` is received.
final class CallAudioSessionActivationChanged extends CallEvent {
  const CallAudioSessionActivationChanged({
    required this.isActive,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  final bool isActive;
}

/// Emitted when the active audio route (Earpiece, Speaker, Bluetooth, Wired Headset) changes.
final class CallAudioRouteChanged extends CallEvent {
  const CallAudioRouteChanged({
    required this.routeState,
    required this.reason,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  final AudioRouteState routeState;
  final String reason;
}

/// Emitted by the deterministic `CallStateMachine` whenever a call transitions between states.
final class CallStateTransitioned extends CallEvent {
  const CallStateTransitioned({
    required this.session,
    required this.previousState,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  final CallSession session;
  final CallState previousState;
}

/// Emitted for non-fatal diagnostics, ghost-call mitigation logs, or invalid state transition warnings.
final class CallDiagnosticEvent extends CallEvent {
  const CallDiagnosticEvent({
    required this.code,
    required this.message,
    this.details = const <String, Object?>{},
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  final String code;
  final String message;
  final Map<String, Object?> details;
}
