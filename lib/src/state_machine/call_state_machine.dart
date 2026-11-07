import 'dart:async';
import 'dart:collection';

import '../models/call_events.dart';
import '../models/call_models.dart';

class _TombstoneEntry {
  const _TombstoneEntry({
    required this.reason,
    required this.expiresAt,
  });

  final CallEndReason reason;
  final DateTime expiresAt;
}

/// Exception thrown when an illegal call state transition is requested in strict mode.
class InvalidCallStateTransitionException implements Exception {
  const InvalidCallStateTransitionException({
    required this.callId,
    required this.fromState,
    required this.attemptedTargetState,
    required this.reason,
  });

  final String callId;
  final CallState fromState;
  final CallState attemptedTargetState;
  final String reason;

  @override
  String toString() =>
      'InvalidCallStateTransitionException(callId: $callId, '
      '${fromState.name} -> ${attemptedTargetState.name}: $reason)';
}

/// Deterministic state machine governing single and multi-call VoIP lifecycles,
/// CallKit/ConnectionService audio activation barriers, GSM hold interruptions,
/// out-of-order early-cancel tombstones, and watchdog timeouts.
class CallStateMachine {
  CallStateMachine({
    this.requireAudioActivationBarrier = true,
    this.maxConcurrentCalls = 2,
    this.enableWatchdogTimers = false,
    this.connectingTimeout = const Duration(seconds: 20),
    this.reconnectingTimeout = const Duration(seconds: 15),
    this.tombstoneTtl = const Duration(seconds: 60),
    this.onEventEmitted,
  });

  /// When true (default for iOS CallKit), an answered or connected call remains in
  /// [CallState.connecting] until the native audio session reports activation
  /// (`provider(_:didActivate:)`), preventing silent WebRTC audio race conditions.
  final bool requireAudioActivationBarrier;

  /// Maximum concurrent active + held calls allowed.
  final int maxConcurrentCalls;

  /// Whether automatic watchdog timers for ringing, connecting, and reconnecting states are active.
  final bool enableWatchdogTimers;

  /// Maximum time a call may remain in [CallState.connecting] before failing with [CallEndReason.connectionFailed].
  final Duration connectingTimeout;

  /// Maximum time a call may remain in [CallState.reconnecting] before failing with [CallEndReason.connectionFailed].
  final Duration reconnectingTimeout;

  /// How long an out-of-order early-cancel tombstone is retained.
  final Duration tombstoneTtl;

  /// Optional listener invoked whenever a state transition or diagnostic event occurs.
  final void Function(CallEvent event)? onEventEmitted;

  final Map<String, CallSession> _sessions = <String, CallSession>{};
  final Set<String> _mediaConnectedCallIds = <String>{};
  final Map<String, _TombstoneEntry> _tombstones = <String, _TombstoneEntry>{};
  final Map<String, Timer> _watchdogTimers = <String, Timer>{};

  bool _isNativeAudioSessionActive = false;
  int _sequenceCounter = 0;

  /// Current active/non-ended calls indexed by `callId`.
  UnmodifiableMapView<String, CallSession> get activeSessions =>
      UnmodifiableMapView<String, CallSession>(
        Map<String, CallSession>.fromEntries(
          _sessions.entries.where((e) => e.value.state != CallState.ended),
        ),
      );

  /// All tracked sessions including recently ended ones.
  UnmodifiableMapView<String, CallSession> get allSessions =>
      UnmodifiableMapView<String, CallSession>(_sessions);

  /// Whether the native telecom audio session (`AVAudioSession` / `AudioManager`) is currently active.
  bool get isNativeAudioSessionActive => _isNativeAudioSessionActive;

  /// Returns the session for [callId] if present.
  CallSession? getSession(String callId) => _sessions[callId];

  /// Valid state transitions map.
  static const Map<CallState, Set<CallState>> _allowedTransitions =
      <CallState, Set<CallState>>{
    CallState.idle: <CallState>{
      CallState.incomingRinging,
      CallState.outgoingDialing,
      CallState.ended,
    },
    CallState.incomingRinging: <CallState>{
      CallState.connecting,
      CallState.active,
      CallState.ended,
    },
    CallState.outgoingDialing: <CallState>{
      CallState.outgoingRinging,
      CallState.connecting,
      CallState.active,
      CallState.ended,
    },
    CallState.outgoingRinging: <CallState>{
      CallState.connecting,
      CallState.active,
      CallState.ended,
    },
    CallState.connecting: <CallState>{
      CallState.active,
      CallState.onHold,
      CallState.reconnecting,
      CallState.ended,
    },
    CallState.active: <CallState>{
      CallState.onHold,
      CallState.reconnecting,
      CallState.ended,
    },
    CallState.onHold: <CallState>{
      CallState.active,
      CallState.reconnecting,
      CallState.ended,
    },
    CallState.reconnecting: <CallState>{
      CallState.active,
      CallState.onHold,
      CallState.ended,
    },
    CallState.ended: <CallState>{},
  };

  /// Checks whether transitioning from [from] to [to] is legal.
  static bool canTransition(CallState from, CallState to) {
    if (from == to) return true;
    return _allowedTransitions[from]?.contains(to) ?? false;
  }

  /// Registers a newly received incoming call in [CallState.incomingRinging].
  ///
  /// If an out-of-order `Cancel` / `endCall` arrived earlier for [request.callId]
  /// (present in the Tombstone registry), the call is immediately terminated with
  /// [CallEndReason.remoteCancelled] without ringing.
  CallSession registerIncomingCall(
    CallRequest request, {
    DateTime? timestamp,
  }) {
    final now = (timestamp ?? DateTime.now()).toUtc();
    _pruneExpiredTombstones(now);

    final tombstone = _tombstones.remove(request.callId);
    if (tombstone != null) {
      final tombstonedSession = CallSession(
        callId: request.callId,
        direction: CallDirection.incoming,
        state: CallState.ended,
        callerName: request.callerName,
        handle: request.handle,
        createdAt: now,
        endedAt: now,
        endReason: tombstone.reason,
        avatarUrl: request.avatarUrl,
        hasVideo: request.hasVideo,
        capabilities: request.capabilities,
        metadata: request.metadata,
      );
      _sessions[request.callId] = tombstonedSession;
      _emitDiagnostic(
        code: 'EARLY_CANCEL_TOMBSTONE_HIT',
        message:
            'Incoming call ${request.callId} was already cancelled prior to arrival; suppressed ringing.',
        details: <String, Object?>{
          'callId': request.callId,
          'reason': tombstone.reason.name,
        },
      );
      _emitTransition(tombstonedSession, CallState.idle, now);
      return tombstonedSession;
    }

    final existing = _sessions[request.callId];
    if (existing != null) {
      if (existing.state != CallState.ended) {
        _emitDiagnostic(
          code: 'DUPLICATE_INCOMING_CALL',
          message:
              'Call ${request.callId} already exists in state ${existing.state.name}.',
        );
      } else {
        _emitDiagnostic(
          code: 'ENDED_CALL_REPLAY_IGNORED',
          message:
              'Call ${request.callId} already ended (${existing.endReason?.name}); ignoring duplicate incoming signal.',
        );
      }
      return existing;
    }

    final liveCount = activeSessions.length;
    if (liveCount >= maxConcurrentCalls) {
      final rejectedSession = CallSession(
        callId: request.callId,
        direction: CallDirection.incoming,
        state: CallState.ended,
        callerName: request.callerName,
        handle: request.handle,
        createdAt: now,
        endedAt: now,
        endReason: CallEndReason.systemBlocked,
        avatarUrl: request.avatarUrl,
        hasVideo: request.hasVideo,
        capabilities: request.capabilities,
        metadata: request.metadata,
      );
      _sessions[request.callId] = rejectedSession;
      _emitTransition(rejectedSession, CallState.idle, now);
      return rejectedSession;
    }

    final session = CallSession(
      callId: request.callId,
      direction: CallDirection.incoming,
      state: CallState.incomingRinging,
      callerName: request.callerName,
      handle: request.handle,
      createdAt: now,
      avatarUrl: request.avatarUrl,
      hasVideo: request.hasVideo,
      audioSessionActive: _isNativeAudioSessionActive,
      capabilities: request.capabilities,
      metadata: request.metadata,
    );
    _sessions[request.callId] = session;
    _scheduleWatchdog(
      callId: request.callId,
      duration: request.timeoutDuration,
      expectedStates: const <CallState>{CallState.incomingRinging},
      reason: CallEndReason.unansweredTimeout,
    );
    _emitTransition(session, CallState.idle, now);
    return session;
  }

  /// Registers a newly started outgoing call in [CallState.outgoingDialing].
  CallSession registerOutgoingCall(
    CallRequest request, {
    DateTime? timestamp,
  }) {
    final now = (timestamp ?? DateTime.now()).toUtc();
    final existing = _sessions[request.callId];
    if (existing != null) {
      return existing;
    }

    final liveCount = activeSessions.length;
    if (liveCount >= maxConcurrentCalls) {
      final blockedSession = CallSession(
        callId: request.callId,
        direction: CallDirection.outgoing,
        state: CallState.ended,
        callerName: request.callerName,
        handle: request.handle,
        createdAt: now,
        endedAt: now,
        endReason: CallEndReason.systemBlocked,
        avatarUrl: request.avatarUrl,
        hasVideo: request.hasVideo,
        capabilities: request.capabilities,
        metadata: request.metadata,
      );
      _sessions[request.callId] = blockedSession;
      _emitTransition(blockedSession, CallState.idle, now);
      return blockedSession;
    }

    _autoHoldOtherActiveCalls(exceptCallId: request.callId, timestamp: now);

    final session = CallSession(
      callId: request.callId,
      direction: CallDirection.outgoing,
      state: CallState.outgoingDialing,
      callerName: request.callerName,
      handle: request.handle,
      createdAt: now,
      avatarUrl: request.avatarUrl,
      hasVideo: request.hasVideo,
      audioSessionActive: _isNativeAudioSessionActive,
      capabilities: request.capabilities,
      metadata: request.metadata,
    );
    _sessions[request.callId] = session;
    _scheduleWatchdog(
      callId: request.callId,
      duration: request.timeoutDuration,
      expectedStates: const <CallState>{
        CallState.outgoingDialing,
        CallState.outgoingRinging,
      },
      reason: CallEndReason.unansweredTimeout,
    );
    _emitTransition(session, CallState.idle, now);
    return session;
  }

  /// Transitions an outgoing dialing call to [CallState.outgoingRinging] when remote peer alerts.
  CallSession? markOutgoingRinging(String callId, {DateTime? timestamp}) {
    return _transition(
      callId: callId,
      targetState: CallState.outgoingRinging,
      timestamp: timestamp,
    );
  }

  /// Marks an incoming call as answered by the user/system, automatically placing any
  /// other currently active call on hold (Call Waiting / Multi-Call support).
  ///
  /// Idempotent if the call is already in [CallState.connecting] or [CallState.active].
  CallSession? markAnswered(
    String callId, {
    DateTime? timestamp,
  }) {
    final session = _sessions[callId];
    if (session == null) return null;
    if (session.state == CallState.ended) return session;
    if (session.state == CallState.connecting ||
        session.state == CallState.active) {
      return session;
    }

    final now = (timestamp ?? DateTime.now()).toUtc();
    _autoHoldOtherActiveCalls(exceptCallId: callId, timestamp: now);

    final canPromoteToActive = _mediaConnectedCallIds.contains(callId) &&
        (!requireAudioActivationBarrier || _isNativeAudioSessionActive);

    if (canPromoteToActive) {
      _cancelWatchdog(callId);
      return _transition(
        callId: callId,
        targetState: CallState.active,
        isOnHold: false,
        heldBySystem: false,
        timestamp: now,
        connectedAt: now,
      );
    } else {
      _scheduleWatchdog(
        callId: callId,
        duration: connectingTimeout,
        expectedStates: const <CallState>{CallState.connecting},
        reason: CallEndReason.connectionFailed,
      );
      return _transition(
        callId: callId,
        targetState: CallState.connecting,
        timestamp: now,
      );
    }
  }

  /// Marks signaling/WebRTC media transport as connected for [callId].
  ///
  /// If [requireAudioActivationBarrier] is true and the native audio session is not yet
  /// active, the call remains in [CallState.connecting] until [onNativeAudioSessionChanged]
  /// reports `isActive: true`.
  CallSession? markMediaConnected(
    String callId, {
    DateTime? timestamp,
  }) {
    final session = _sessions[callId];
    if (session == null || session.state == CallState.ended) return session;

    final now = (timestamp ?? DateTime.now()).toUtc();
    _mediaConnectedCallIds.add(callId);

    // Do not promote an unanswered incomingRinging call to active before the user answers it!
    if (session.state == CallState.incomingRinging) {
      return session;
    }

    if (!requireAudioActivationBarrier || _isNativeAudioSessionActive) {
      _cancelWatchdog(callId);
      _autoHoldOtherActiveCalls(exceptCallId: callId, timestamp: now);
      return _transition(
        callId: callId,
        targetState: CallState.active,
        isOnHold: false,
        heldBySystem: false,
        timestamp: now,
        connectedAt: session.connectedAt ?? now,
      );
    } else {
      if (session.state != CallState.onHold) {
        _scheduleWatchdog(
          callId: callId,
          duration: connectingTimeout,
          expectedStates: const <CallState>{CallState.connecting},
          reason: CallEndReason.connectionFailed,
        );
        return _transition(
          callId: callId,
          targetState: CallState.connecting,
          timestamp: now,
        );
      }
      return session;
    }
  }

  /// Updates the native audio session barrier (`AVAudioSession` / `AudioManager`).
  ///
  /// When `isActive` becomes `true`, any call waiting in [CallState.connecting] whose
  /// media is already connected is automatically promoted to [CallState.active].
  void onNativeAudioSessionChanged(
    bool isActive, {
    DateTime? timestamp,
  }) {
    final now = (timestamp ?? DateTime.now()).toUtc();
    _isNativeAudioSessionActive = isActive;

    var promotedOneToActive = false;
    for (final entry in _sessions.entries.toList()) {
      final session = entry.value;
      if (session.state == CallState.ended) continue;

      final updated = session.copyWith(audioSessionActive: isActive);
      _sessions[entry.key] = updated;

      if (isActive &&
          !promotedOneToActive &&
          session.state == CallState.connecting &&
          _mediaConnectedCallIds.contains(entry.key)) {
        promotedOneToActive = true;
        _cancelWatchdog(entry.key);
        _autoHoldOtherActiveCalls(exceptCallId: entry.key, timestamp: now);
        _transition(
          callId: entry.key,
          targetState: CallState.active,
          isOnHold: false,
          heldBySystem: false,
          timestamp: now,
          connectedAt: session.connectedAt ?? now,
        );
      } else if (!isActive &&
          requireAudioActivationBarrier &&
          session.state == CallState.active) {
        // If native audio session is deactivated while call is active, demote to onHold
        _transition(
          callId: entry.key,
          targetState: CallState.onHold,
          isOnHold: true,
          heldBySystem: true,
          timestamp: now,
        );
      }
    }
  }

  /// Places a call on hold or resumes it from hold.
  ///
  /// If [heldBySystem] is true, records that the hold was caused by an OS/GSM interruption.
  CallSession? setHold(
    String callId, {
    required bool isOnHold,
    bool heldBySystem = false,
    DateTime? timestamp,
  }) {
    final session = _sessions[callId];
    if (session == null || session.state == CallState.ended) return session;

    final now = (timestamp ?? DateTime.now()).toUtc();
    if (isOnHold) {
      if (!canTransition(session.state, CallState.onHold)) {
        _emitDiagnostic(
          code: 'INVALID_HOLD_STATE',
          message: 'Cannot place call $callId on hold while in ${session.state.name}.',
        );
        return session;
      }
      return _transition(
        callId: callId,
        targetState: CallState.onHold,
        isOnHold: true,
        heldBySystem: heldBySystem,
        timestamp: now,
      );
    } else {
      if (requireAudioActivationBarrier && !_isNativeAudioSessionActive) {
        _emitDiagnostic(
          code: 'UNHOLD_BLOCKED_BY_AUDIO_BARRIER',
          message:
              'Cannot resume call $callId to active while native audio session is inactive.',
        );
        return session;
      }
      _autoHoldOtherActiveCalls(exceptCallId: callId, timestamp: now);
      return _transition(
        callId: callId,
        targetState: CallState.active,
        isOnHold: false,
        heldBySystem: false,
        timestamp: now,
      );
    }
  }

  /// Swaps two calls when one is [CallState.active] and another is [CallState.onHold].
  void swapCalls({
    required String activeCallId,
    required String heldCallId,
    DateTime? timestamp,
  }) {
    final now = (timestamp ?? DateTime.now()).toUtc();
    setHold(activeCallId, isOnHold: true, timestamp: now);
    setHold(heldCallId, isOnHold: false, timestamp: now);
  }

  /// Updates microphone mute status for [callId].
  CallSession? setMuted(
    String callId, {
    required bool isMuted,
  }) {
    final session = _sessions[callId];
    if (session == null || session.state == CallState.ended) return session;
    final updated = session.copyWith(isMuted: isMuted);
    _sessions[callId] = updated;
    return updated;
  }

  /// Transitions an active/connecting/held call to [CallState.reconnecting] when ICE/network drops.
  CallSession? markReconnecting(String callId, {DateTime? timestamp}) {
    final session = _sessions[callId];
    if (session == null || session.state == CallState.ended) return session;
    if (!canTransition(session.state, CallState.reconnecting)) {
      return session;
    }

    _scheduleWatchdog(
      callId: callId,
      duration: reconnectingTimeout,
      expectedStates: const <CallState>{CallState.reconnecting},
      reason: CallEndReason.connectionFailed,
    );
    return _transition(
      callId: callId,
      targetState: CallState.reconnecting,
      isOnHold: false,
      timestamp: timestamp,
    );
  }

  /// Terminates a call session and records the [CallEndReason].
  ///
  /// If [callId] is not yet registered in `_sessions` (e.g., an out-of-order `Cancel`
  /// arrived over WebSocket before the PushKit/FCM `IncomingCall` arrived), records a
  /// Tombstone entry so the subsequent incoming call will be immediately suppressed.
  CallSession? endCall(
    String callId, {
    required CallEndReason reason,
    DateTime? timestamp,
  }) {
    final now = (timestamp ?? DateTime.now()).toUtc();
    _cancelWatchdog(callId);
    _mediaConnectedCallIds.remove(callId);

    final session = _sessions[callId];
    if (session == null) {
      _pruneExpiredTombstones(now);
      _tombstones[callId] = _TombstoneEntry(
        reason: reason,
        expiresAt: now.add(tombstoneTtl),
      );
      _emitDiagnostic(
        code: 'EARLY_CANCEL_TOMBSTONE_RECORDED',
        message:
            'Recorded early termination tombstone ($reason) for unseen call $callId.',
        details: <String, Object?>{'callId': callId, 'reason': reason.name},
      );
      return null;
    }

    if (session.state == CallState.ended) return session;

    return _transition(
      callId: callId,
      targetState: CallState.ended,
      endReason: reason,
      endedAt: now,
      isOnHold: false,
      heldBySystem: false,
      timestamp: now,
    );
  }

  /// Applies an incoming [CallEvent] from the native platform or cold-start buffer
  /// to keep the state machine synchronized.
  void applyNativeEvent(CallEvent event) {
    switch (event) {
      case CallIncomingReceived(:final request, :final timestamp):
        registerIncomingCall(request, timestamp: timestamp);
      case CallOutgoingStarted(:final request, :final timestamp):
        registerOutgoingCall(request, timestamp: timestamp);
      case CallAnswered(:final callId, :final timestamp):
        markAnswered(callId, timestamp: timestamp);
      case CallHeldChanged(
          :final callId,
          :final isOnHold,
          :final heldBySystem,
          :final timestamp
        ):
        setHold(
          callId,
          isOnHold: isOnHold,
          heldBySystem: heldBySystem,
          timestamp: timestamp,
        );
      case CallMutedChanged(:final callId, :final isMuted):
        setMuted(callId, isMuted: isMuted);
      case CallAudioSessionActivationChanged(:final isActive, :final timestamp):
        onNativeAudioSessionChanged(isActive, timestamp: timestamp);
      case CallEnded(:final callId, :final reason, :final timestamp):
        endCall(callId, reason: reason, timestamp: timestamp);
      case VoipPushTokenUpdated():
      case CallDtmfTonePlayed():
      case CallAudioRouteChanged():
      case CallStateTransitioned():
      case CallDiagnosticEvent():
        break;
    }
  }

  /// Verifies all 5 enterprise telecom state machine invariants.
  /// Throws a [StateError] if any invariant is violated.
  void verifyInvariants() {
    final live = activeSessions.values.toList();

    // Invariant 1: Live calls must never exceed maxConcurrentCalls.
    if (live.length > maxConcurrentCalls) {
      throw StateError(
        'Invariant Violation #1: Live calls (${live.length}) exceeded maxConcurrentCalls ($maxConcurrentCalls).',
      );
    }

    // Invariant 2: At most ONE call can be in CallState.active at any instant.
    final activeList = live.where((c) => c.state == CallState.active).toList();
    if (activeList.length > 1) {
      throw StateError(
        'Invariant Violation #2: Multiple calls in CallState.active simultaneously: '
        '${activeList.map((e) => e.callId).toList()}',
      );
    }

    for (final session in _sessions.values) {
      // Invariant 3: When requireAudioActivationBarrier is true and native audio is inactive,
      // no call can be in CallState.active.
      if (requireAudioActivationBarrier &&
          !_isNativeAudioSessionActive &&
          session.state == CallState.active) {
        throw StateError(
          'Invariant Violation #3: Call ${session.callId} is active while native audio barrier is locked.',
        );
      }

      // Invariant 4: A call in CallState.active must never have isOnHold == true,
      // and a call in CallState.onHold must have isOnHold == true.
      if (session.state == CallState.active && session.isOnHold) {
        throw StateError(
          'Invariant Violation #4a: Call ${session.callId} is in CallState.active but has isOnHold == true.',
        );
      }
      if (session.state == CallState.onHold && !session.isOnHold) {
        throw StateError(
          'Invariant Violation #4b: Call ${session.callId} is in CallState.onHold but has isOnHold == false.',
        );
      }

      // Invariant 5: An ended call must always have a non-null endReason and endedAt, and isOnHold == false.
      if (session.state == CallState.ended) {
        if (session.endReason == null || session.endedAt == null || session.isOnHold) {
          throw StateError(
            'Invariant Violation #5: Ended call ${session.callId} has corrupted terminal fields: '
            'endReason=${session.endReason}, endedAt=${session.endedAt}, isOnHold=${session.isOnHold}.',
          );
        }
      }
    }
  }

  /// Clears ended sessions from memory.
  void pruneEndedSessions() {
    _sessions.removeWhere((_, session) => session.state == CallState.ended);
  }

  /// Cancels all active watchdog timers.
  void dispose() {
    for (final timer in _watchdogTimers.values) {
      timer.cancel();
    }
    _watchdogTimers.clear();
  }

  void _scheduleWatchdog({
    required String callId,
    required Duration duration,
    required Set<CallState> expectedStates,
    required CallEndReason reason,
  }) {
    _cancelWatchdog(callId);
    if (!enableWatchdogTimers) return;

    _watchdogTimers[callId] = Timer(duration, () {
      _watchdogTimers.remove(callId);
      final current = _sessions[callId];
      if (current != null && expectedStates.contains(current.state)) {
        _emitDiagnostic(
          code: 'WATCHDOG_TIMEOUT',
          message:
              'Call $callId timed out in state ${current.state.name} after ${duration.inSeconds}s.',
          details: <String, Object?>{
            'callId': callId,
            'state': current.state.name,
            'reason': reason.name,
          },
        );
        endCall(callId, reason: reason);
      }
    });
  }

  void _cancelWatchdog(String callId) {
    _watchdogTimers.remove(callId)?.cancel();
  }

  void _pruneExpiredTombstones(DateTime now) {
    _tombstones.removeWhere((_, entry) => !entry.expiresAt.isAfter(now));
  }

  void _autoHoldOtherActiveCalls({
    required String exceptCallId,
    required DateTime timestamp,
  }) {
    for (final entry in _sessions.entries.toList()) {
      if (entry.key != exceptCallId && entry.value.state == CallState.active) {
        _transition(
          callId: entry.key,
          targetState: CallState.onHold,
          isOnHold: true,
          timestamp: timestamp,
        );
      }
    }
  }

  CallSession? _transition({
    required String callId,
    required CallState targetState,
    bool? isOnHold,
    bool? heldBySystem,
    DateTime? connectedAt,
    DateTime? endedAt,
    CallEndReason? endReason,
    DateTime? timestamp,
  }) {
    final current = _sessions[callId];
    if (current == null) {
      _emitDiagnostic(
        code: 'UNKNOWN_CALL_ID',
        message:
            'Attempted transition to ${targetState.name} for unknown call $callId.',
      );
      return null;
    }

    final previousState = current.state;
    if (!canTransition(previousState, targetState)) {
      _emitDiagnostic(
        code: 'INVALID_STATE_TRANSITION',
        message:
            'Illegal state transition for call $callId: ${previousState.name} -> ${targetState.name}.',
        details: <String, Object?>{
          'callId': callId,
          'from': previousState.name,
          'to': targetState.name,
        },
      );
      return current;
    }

    final now = (timestamp ?? DateTime.now()).toUtc();
    final updated = current.copyWith(
      state: targetState,
      isOnHold: isOnHold ?? current.isOnHold,
      heldBySystem: heldBySystem ?? current.heldBySystem,
      audioSessionActive: _isNativeAudioSessionActive,
      connectedAt: connectedAt ?? current.connectedAt,
      endedAt: endedAt ?? current.endedAt,
      endReason: endReason ?? current.endReason,
    );
    _sessions[callId] = updated;

    if (previousState != targetState) {
      _emitTransition(updated, previousState, now);
    }
    return updated;
  }

  void _emitTransition(
    CallSession session,
    CallState previousState,
    DateTime timestamp,
  ) {
    onEventEmitted?.call(
      CallStateTransitioned(
        session: session,
        previousState: previousState,
        timestamp: timestamp,
        sequenceNumber: ++_sequenceCounter,
      ),
    );
  }

  void _emitDiagnostic({
    required String code,
    required String message,
    Map<String, Object?> details = const <String, Object?>{},
  }) {
    onEventEmitted?.call(
      CallDiagnosticEvent(
        code: code,
        message: message,
        details: details,
        timestamp: DateTime.now().toUtc(),
        sequenceNumber: ++_sequenceCounter,
      ),
    );
  }
}
