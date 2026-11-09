import 'package:meta/meta.dart';

import '../utils/coercion_utils.dart';
import 'audio_models.dart';
import 'call_models.dart';

/// Base sealed class for all VoIP lifecycle, audio routing, and push token events.
///
/// Supports exhaustive Dart 3 `switch (event)` pattern matching.
@immutable
sealed class CallEvent {
  /// Base constructor for all [CallEvent] types.
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

  /// Exact UTC timestamp when the event occurred.
  final DateTime timestamp;

  /// Monotonically increasing sequence number for event ordering.
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
  /// Creates a [VoipPushTokenUpdated] event.
  const VoipPushTokenUpdated({
    required this.token,
    required this.environment,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  /// The raw hex-encoded PushKit device token or FCM push token.
  final String token;

  /// Target push environment (`production` or `development`/sandbox).
  final String environment;
}

/// Emitted when an incoming call has been reported to the native telecom subsystem.
final class CallIncomingReceived extends CallEvent {
  /// Creates a [CallIncomingReceived] event.
  const CallIncomingReceived({
    required this.request,
    required this.reportedViaPushKit,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  /// The original call request containing caller handle and metadata.
  final CallRequest request;

  /// Whether this call was reported automatically via native PushKit before Dart initialization.
  final bool reportedViaPushKit;
}

/// Emitted when an outgoing call has been initiated.
final class CallOutgoingStarted extends CallEvent {
  /// Creates a [CallOutgoingStarted] event.
  const CallOutgoingStarted({
    required this.callId,
    required this.request,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  /// Identifier of the outgoing call.
  final String callId;

  /// Call details including callee handle and timeout constraints.
  final CallRequest request;
}

/// Emitted when the user (or hardware accessory) answers an incoming call.
final class CallAnswered extends CallEvent {
  /// Creates a [CallAnswered] event.
  const CallAnswered({
    required this.callId,
    required this.source,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  /// Unique UUID of the answered call.
  final String callId;

  /// Whether answered via app UI, lock screen CallKit/notification, or Bluetooth accessory.
  final CallActionSource source;
}

/// Emitted when a call ends or is rejected.
final class CallEnded extends CallEvent {
  /// Creates a [CallEnded] event.
  const CallEnded({
    required this.callId,
    required this.reason,
    required this.source,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  /// Identifier of the terminated call.
  final String callId;

  /// Standardized cause of termination.
  final CallEndReason reason;

  /// Origin of the disconnect trigger.
  final CallActionSource source;
}

/// Emitted when a call's hold status changes (including automatic GSM interruption hold).
final class CallHeldChanged extends CallEvent {
  /// Creates a [CallHeldChanged] event.
  const CallHeldChanged({
    required this.callId,
    required this.isOnHold,
    required this.heldBySystem,
    required this.source,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  /// Identifier of the call whose hold state changed.
  final String callId;

  /// True if the call is placed on hold; false if resumed.
  final bool isOnHold;

  /// True if hold was enforced automatically due to cellular GSM activity.
  final bool heldBySystem;

  /// Origin that requested or caused the hold transition.
  final CallActionSource source;
}

/// Emitted when a call's microphone mute status changes.
final class CallMutedChanged extends CallEvent {
  /// Creates a [CallMutedChanged] event.
  const CallMutedChanged({
    required this.callId,
    required this.isMuted,
    required this.source,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  /// Identifier of the muted or unmuted call.
  final String callId;

  /// True if microphone input is muted; false if unmuted.
  final bool isMuted;

  /// Origin that caused the mute transition.
  final CallActionSource source;
}

/// Emitted when DTMF digits are played during an active call.
final class CallDtmfTonePlayed extends CallEvent {
  /// Creates a [CallDtmfTonePlayed] event.
  const CallDtmfTonePlayed({
    required this.callId,
    required this.digits,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  /// Call identifier on which digits were sent.
  final String callId;

  /// The DTMF digits transmitted (`0-9`, `*`, `#`, `A-D`).
  final String digits;
}

/// Emitted when the native voice audio session (`AVAudioSession` / `AudioManager`)
/// is activated or deactivated by CallKit / ConnectionService.
///
/// **CRITICAL FOR WEBRTC:** Do not enable WebRTC audio playout/recording on iOS
/// until `isActive == true` is received.
final class CallAudioSessionActivationChanged extends CallEvent {
  /// Creates a [CallAudioSessionActivationChanged] event.
  const CallAudioSessionActivationChanged({
    required this.isActive,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  /// True when native hardware audio session has been activated for voice communication.
  final bool isActive;
}

/// Emitted when the active audio route (Earpiece, Speaker, Bluetooth, Wired Headset) changes.
final class CallAudioRouteChanged extends CallEvent {
  /// Creates a [CallAudioRouteChanged] event.
  const CallAudioRouteChanged({
    required this.routeState,
    required this.reason,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  /// Updated route snapshot with active endpoint and available options.
  final AudioRouteState routeState;

  /// Diagnostic reason or trigger for the audio routing adjustment.
  final String reason;
}

/// Emitted by the deterministic `CallStateMachine` whenever a call transitions between states.
final class CallStateTransitioned extends CallEvent {
  /// Creates a [CallStateTransitioned] event.
  const CallStateTransitioned({
    required this.session,
    required this.previousState,
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  /// The updated call session snapshot reflecting the new state.
  final CallSession session;

  /// The state the call transitioned from.
  final CallState previousState;
}

/// Emitted for non-fatal diagnostics, ghost-call mitigation logs, or invalid state transition warnings.
final class CallDiagnosticEvent extends CallEvent {
  /// Creates a [CallDiagnosticEvent] for diagnostic telemetry.
  const CallDiagnosticEvent({
    required this.code,
    required this.message,
    this.details = const <String, Object?>{},
    required super.timestamp,
    super.sequenceNumber,
    super.fromColdStartBuffer,
  });

  /// Short machine-readable diagnostic code.
  final String code;

  /// Human-readable diagnostic description.
  final String message;

  /// Arbitrary diagnostic metadata payload.
  final Map<String, Object?> details;
}
