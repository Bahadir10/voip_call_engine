import 'package:meta/meta.dart';

import '../utils/coercion_utils.dart';

/// Represents the lifecycle state of a single VoIP call.
enum CallState {
  /// Initial state before signaling starts.
  idle,

  /// Incoming call has been reported to the native telecom subsystem and is ringing.
  incomingRinging,

  /// Outgoing call has been initiated locally and is dialing.
  outgoingDialing,

  /// Outgoing call reached remote peer and remote device is ringing.
  outgoingRinging,

  /// Call has been answered (locally or remotely) and media/audio session is negotiating.
  connecting,

  /// Call media is connected and native audio session is active.
  active,

  /// Call is currently placed on hold (either by user action or GSM interruption).
  onHold,

  /// Call media temporarily lost connectivity and is attempting ICE/signaling reconnection.
  reconnecting,

  /// Call has terminated and resources have been released.
  ended,
}

/// Direction of a VoIP call.
enum CallDirection {
  incoming,
  outgoing,
}

/// Type of caller handle (phone number, email, or generic SIP/user identifier).
enum CallHandleType {
  generic,
  phoneNumber,
  emailAddress,
}

/// Reason why a call ended, normalized across iOS (`CXCallEndedReason`),
/// Android (`DisconnectCause`), Windows, macOS, and Web.
enum CallEndReason {
  /// Local user hung up an active or dialing call.
  localHangup,

  /// Remote party hung up an active call.
  remoteHangup,

  /// Local user rejected an incoming call.
  localRejected,

  /// Remote party rejected an outgoing call (Busy).
  remoteBusy,

  /// Incoming or outgoing call timed out without being answered.
  unansweredTimeout,

  /// Incoming call was answered on another device belonging to the same user.
  answeredElsewhere,

  /// Incoming call was cancelled by the caller before being answered (or Ghost Call protection).
  remoteCancelled,

  /// Media or signaling connection failed fatally.
  connectionFailed,

  /// Blocked by system Do-Not-Disturb, permission denial, or telecom restriction.
  systemBlocked,
}

/// Origin of a call control action (e.g., answering, muting, holding, ending).
enum CallActionSource {
  /// Triggered programmatically by the Flutter app UI.
  appUi,

  /// Triggered from the native system UI (iOS CallKit screen, Android CallStyle notification, Windows Toast).
  systemUi,

  /// Triggered by hardware buttons (Bluetooth headset, wired inline remote, CarPlay / Android Auto).
  hardwareAccessory,

  /// Triggered automatically by the OS (e.g., GSM cellular call interruption placing VoIP call on hold).
  systemInterruption,

  /// Triggered by remote signaling server.
  remoteSignaling,
}

/// Immutable representation of a caller/callee address handle.
@immutable
class CallHandle {
  const CallHandle({
    required this.type,
    required this.value,
  });

  factory CallHandle.fromMap(Map<Object?, Object?> map) {
    final typeName = CoercionUtils.asString(map['type'], fallback: 'generic');
    return CallHandle(
      type: CallHandleType.values.firstWhere(
        (e) => e.name == typeName,
        orElse: () => CallHandleType.generic,
      ),
      value: CoercionUtils.asString(map['value']),
    );
  }

  final CallHandleType type;
  final String value;

  Map<String, Object?> toMap() => <String, Object?>{
        'type': type.name,
        'value': value,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CallHandle && other.type == type && other.value == value;

  @override
  int get hashCode => Object.hash(type, value);

  @override
  String toString() => 'CallHandle(${type.name}: $value)';
}

/// Capabilities supported by a specific call session.
@immutable
class CallCapabilities {
  const CallCapabilities({
    this.supportsHold = true,
    this.supportsMute = true,
    this.supportsDtmf = true,
    this.supportsGrouping = false,
    this.supportsVideo = false,
  });

  factory CallCapabilities.fromMap(Map<Object?, Object?> map) {
    return CallCapabilities(
      supportsHold: CoercionUtils.asBool(map['supportsHold'], fallback: true),
      supportsMute: CoercionUtils.asBool(map['supportsMute'], fallback: true),
      supportsDtmf: CoercionUtils.asBool(map['supportsDtmf'], fallback: true),
      supportsGrouping:
          CoercionUtils.asBool(map['supportsGrouping'], fallback: false),
      supportsVideo:
          CoercionUtils.asBool(map['supportsVideo'], fallback: false),
    );
  }

  final bool supportsHold;
  final bool supportsMute;
  final bool supportsDtmf;
  final bool supportsGrouping;
  final bool supportsVideo;

  Map<String, Object?> toMap() => <String, Object?>{
        'supportsHold': supportsHold,
        'supportsMute': supportsMute,
        'supportsDtmf': supportsDtmf,
        'supportsGrouping': supportsGrouping,
        'supportsVideo': supportsVideo,
      };
}

/// Request payload used to report an incoming call or start an outgoing call.
@immutable
class CallRequest {
  const CallRequest({
    required this.callId,
    required this.callerName,
    required this.handle,
    this.avatarUrl,
    this.hasVideo = false,
    this.capabilities = const CallCapabilities(),
    this.metadata = const <String, String>{},
    this.timeoutDuration = const Duration(seconds: 45),
  });

  factory CallRequest.fromMap(Map<Object?, Object?> map) {
    return CallRequest(
      callId: CoercionUtils.asString(
        map['callId'],
        fallback: '00000000-0000-4000-8000-000000000000',
      ),
      callerName: CoercionUtils.asString(
        map['callerName'],
        fallback: 'Unknown',
      ),
      handle: CallHandle.fromMap(CoercionUtils.asObjectMap(map['handle'])),
      avatarUrl: CoercionUtils.asNullableString(map['avatarUrl']),
      hasVideo: CoercionUtils.asBool(map['hasVideo'], fallback: false),
      capabilities: CallCapabilities.fromMap(
        CoercionUtils.asObjectMap(map['capabilities']),
      ),
      metadata: CoercionUtils.asStringMap(map['metadata']),
      timeoutDuration: Duration(
        milliseconds: CoercionUtils.asInt(
          map['timeoutMs'],
          fallback: 45000,
          min: 1000,
          max: 300000,
        ),
      ),
    );
  }

  /// Must be a valid UUID v4 string (required by iOS CallKit `UUID`).
  final String callId;
  final String callerName;
  final CallHandle handle;
  final String? avatarUrl;
  final bool hasVideo;
  final CallCapabilities capabilities;
  final Map<String, String> metadata;
  final Duration timeoutDuration;

  Map<String, Object?> toMap() => <String, Object?>{
        'callId': callId,
        'callerName': callerName,
        'handle': handle.toMap(),
        'avatarUrl': avatarUrl,
        'hasVideo': hasVideo,
        'capabilities': capabilities.toMap(),
        'metadata': metadata,
        'timeoutMs': timeoutDuration.inMilliseconds,
      };
}

/// Complete immutable snapshot of a VoIP call session managed by the state machine.
@immutable
class CallSession {
  const CallSession({
    required this.callId,
    required this.direction,
    required this.state,
    required this.callerName,
    required this.handle,
    required this.createdAt,
    this.avatarUrl,
    this.hasVideo = false,
    this.isMuted = false,
    this.isOnHold = false,
    this.heldBySystem = false,
    this.audioSessionActive = false,
    this.connectedAt,
    this.endedAt,
    this.endReason,
    this.capabilities = const CallCapabilities(),
    this.metadata = const <String, String>{},
  });

  factory CallSession.fromMap(Map<Object?, Object?> map) {
    final directionStr =
        CoercionUtils.asString(map['direction'], fallback: 'incoming');
    final stateStr = CoercionUtils.asString(map['state'], fallback: 'idle');
    final endReasonStr = CoercionUtils.asNullableString(map['endReason']);
    final connectedMs = map['connectedAtMs'];
    final endedMs = map['endedAtMs'];

    return CallSession(
      callId: CoercionUtils.asString(
        map['callId'],
        fallback: '00000000-0000-4000-8000-000000000000',
      ),
      direction: CallDirection.values.firstWhere(
        (e) => e.name == directionStr,
        orElse: () => CallDirection.incoming,
      ),
      state: CallState.values.firstWhere(
        (e) => e.name == stateStr,
        orElse: () => CallState.idle,
      ),
      callerName:
          CoercionUtils.asString(map['callerName'], fallback: 'Unknown'),
      handle: CallHandle.fromMap(CoercionUtils.asObjectMap(map['handle'])),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        CoercionUtils.asInt(map['createdAtMs'], fallback: 0, min: 0),
        isUtc: true,
      ),
      avatarUrl: CoercionUtils.asNullableString(map['avatarUrl']),
      hasVideo: CoercionUtils.asBool(map['hasVideo']),
      isMuted: CoercionUtils.asBool(map['isMuted']),
      isOnHold: CoercionUtils.asBool(map['isOnHold']),
      heldBySystem: CoercionUtils.asBool(map['heldBySystem']),
      audioSessionActive: CoercionUtils.asBool(map['audioSessionActive']),
      connectedAt: connectedMs != null
          ? DateTime.fromMillisecondsSinceEpoch(
              CoercionUtils.asInt(connectedMs, fallback: 0, min: 0),
              isUtc: true,
            )
          : null,
      endedAt: endedMs != null
          ? DateTime.fromMillisecondsSinceEpoch(
              CoercionUtils.asInt(endedMs, fallback: 0, min: 0),
              isUtc: true,
            )
          : null,
      endReason: endReasonStr != null
          ? CallEndReason.values.firstWhere(
              (e) => e.name == endReasonStr,
              orElse: () => CallEndReason.localHangup,
            )
          : null,
      capabilities: CallCapabilities.fromMap(
        CoercionUtils.asObjectMap(map['capabilities']),
      ),
      metadata: CoercionUtils.asStringMap(map['metadata']),
    );
  }

  final String callId;
  final CallDirection direction;
  final CallState state;
  final String callerName;
  final CallHandle handle;
  final DateTime createdAt;
  final String? avatarUrl;
  final bool hasVideo;
  final bool isMuted;
  final bool isOnHold;

  /// True if the call was placed on hold automatically due to a native GSM call interruption.
  final bool heldBySystem;

  /// True when the native audio subsystem (`AVAudioSession` / `AudioManager`) has activated voice routing.
  final bool audioSessionActive;
  final DateTime? connectedAt;
  final DateTime? endedAt;
  final CallEndReason? endReason;
  final CallCapabilities capabilities;
  final Map<String, String> metadata;

  CallSession copyWith({
    CallState? state,
    String? callerName,
    CallHandle? handle,
    String? avatarUrl,
    bool? hasVideo,
    bool? isMuted,
    bool? isOnHold,
    bool? heldBySystem,
    bool? audioSessionActive,
    DateTime? connectedAt,
    DateTime? endedAt,
    CallEndReason? endReason,
    CallCapabilities? capabilities,
    Map<String, String>? metadata,
  }) {
    return CallSession(
      callId: callId,
      direction: direction,
      state: state ?? this.state,
      callerName: callerName ?? this.callerName,
      handle: handle ?? this.handle,
      createdAt: createdAt,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      hasVideo: hasVideo ?? this.hasVideo,
      isMuted: isMuted ?? this.isMuted,
      isOnHold: isOnHold ?? this.isOnHold,
      heldBySystem: heldBySystem ?? this.heldBySystem,
      audioSessionActive: audioSessionActive ?? this.audioSessionActive,
      connectedAt: connectedAt ?? this.connectedAt,
      endedAt: endedAt ?? this.endedAt,
      endReason: endReason ?? this.endReason,
      capabilities: capabilities ?? this.capabilities,
      metadata: metadata ?? this.metadata,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        'callId': callId,
        'direction': direction.name,
        'state': state.name,
        'callerName': callerName,
        'handle': handle.toMap(),
        'createdAtMs': createdAt.toUtc().millisecondsSinceEpoch,
        'avatarUrl': avatarUrl,
        'hasVideo': hasVideo,
        'isMuted': isMuted,
        'isOnHold': isOnHold,
        'heldBySystem': heldBySystem,
        'audioSessionActive': audioSessionActive,
        'connectedAtMs': connectedAt?.toUtc().millisecondsSinceEpoch,
        'endedAtMs': endedAt?.toUtc().millisecondsSinceEpoch,
        'endReason': endReason?.name,
        'capabilities': capabilities.toMap(),
        'metadata': metadata,
      };

  @override
  String toString() =>
      'CallSession(id: $callId, state: ${state.name}, caller: $callerName, '
      'hold: $isOnHold, muted: $isMuted, audioActive: $audioSessionActive)';
}
