import 'package:flutter_test/flutter_test.dart';
import 'package:voip_call_engine/voip_call_engine.dart';

void main() {
  const ghostCallId = '77777777-8888-4999-8000-111122223333';
  const call1Id = '11111111-2222-4333-8444-555566667777';

  group('Enterprise Resilience — Tombstones, Watchdog Timeouts & Idempotency', () {
    test(
      'suppresses late incoming call when out-of-order Cancel arrives first (Tombstone Cache)',
      () {
        final diagnostics = <CallDiagnosticEvent>[];
        final sm = CallStateMachine(
          onEventEmitted: (event) {
            if (event is CallDiagnosticEvent) diagnostics.add(event);
          },
        );

        // 1. WebSocket delivers Cancel BEFORE PushKit/FCM Incoming Call arrives
        final earlyEnd = sm.endCall(
          ghostCallId,
          reason: CallEndReason.remoteCancelled,
        );
        expect(earlyEnd, isNull);
        expect(
          diagnostics.any((d) => d.code == 'EARLY_CANCEL_TOMBSTONE_RECORDED'),
          isTrue,
        );

        // 2. 800ms later, PushKit/FCM Incoming Call arrives for the same callId
        final lateIncoming = sm.registerIncomingCall(
          const CallRequest(
            callId: ghostCallId,
            callerName: 'Late Push Caller',
            handle: CallHandle(
              type: CallHandleType.phoneNumber,
              value: '+905559998877',
            ),
          ),
        );

        expect(lateIncoming.state, CallState.ended);
        expect(lateIncoming.endReason, CallEndReason.remoteCancelled);
        expect(sm.activeSessions, isEmpty);
        expect(
          diagnostics.any((d) => d.code == 'EARLY_CANCEL_TOMBSTONE_HIT'),
          isTrue,
        );
        sm.dispose();
      },
    );

    test(
      'Watchdog automatically terminates unanswered ringing call with unansweredTimeout',
      () async {
        final sm = CallStateMachine(
          enableWatchdogTimers: true,
        );

        sm.registerIncomingCall(
          const CallRequest(
            callId: call1Id,
            callerName: 'Unanswered Caller',
            handle: CallHandle(
              type: CallHandleType.phoneNumber,
              value: '+905550001111',
            ),
            timeoutDuration: Duration(milliseconds: 40),
          ),
        );
        expect(sm.getSession(call1Id)?.state, CallState.incomingRinging);

        await Future<void>.delayed(const Duration(milliseconds: 80));
        final session = sm.getSession(call1Id)!;
        expect(session.state, CallState.ended);
        expect(session.endReason, CallEndReason.unansweredTimeout);
        sm.dispose();
      },
    );

    test(
      'Watchdog terminates stuck connecting call and allows recovery during reconnecting grace period',
      () async {
        final sm = CallStateMachine(
          requireAudioActivationBarrier: false,
          enableWatchdogTimers: true,
          connectingTimeout: const Duration(milliseconds: 50),
          reconnectingTimeout: const Duration(milliseconds: 80),
        );

        // Part A: Stuck in connecting -> auto fails after 50ms
        sm.registerIncomingCall(
          const CallRequest(
            callId: call1Id,
            callerName: 'Stuck ICE Caller',
            handle: CallHandle(type: CallHandleType.generic, value: 'user1'),
          ),
        );
        sm.markAnswered(call1Id);
        expect(sm.getSession(call1Id)?.state, CallState.connecting);

        await Future<void>.delayed(const Duration(milliseconds: 90));
        expect(sm.getSession(call1Id)?.state, CallState.ended);
        expect(sm.getSession(call1Id)?.endReason, CallEndReason.connectionFailed);

        // Part B: Active call drops to reconnecting, then recovers before 80ms timeout
        const call2Id = '22222222-3333-4444-8555-666677778888';
        sm.registerIncomingCall(
          const CallRequest(
            callId: call2Id,
            callerName: 'Recovering Caller',
            handle: CallHandle(type: CallHandleType.generic, value: 'user2'),
          ),
        );
        sm.markAnswered(call2Id);
        sm.markMediaConnected(call2Id);
        expect(sm.getSession(call2Id)?.state, CallState.active);

        sm.markReconnecting(call2Id);
        expect(sm.getSession(call2Id)?.state, CallState.reconnecting);

        await Future<void>.delayed(const Duration(milliseconds: 25));
        sm.markMediaConnected(call2Id); // Reconnected within grace window!
        expect(sm.getSession(call2Id)?.state, CallState.active);

        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(
          sm.getSession(call2Id)?.state,
          CallState.active,
          reason: 'Reconnect watchdog must be cancelled once media recovers',
        );
        sm.dispose();
      },
    );

    test('RFC 4733 DTMF sanitizer strips illegal characters and preserves valid tones', () {
      expect(
        CoercionUtils.sanitizeDtmfDigits('123-*#aBcD-!@\$%^&()_+=xyz,9'),
        '123*#ABCD,9',
      );
      expect(CoercionUtils.sanitizeDtmfDigits('xyz!@%'), isEmpty);
      expect(
        CoercionUtils.isValidUuid('11111111-2222-4333-8444-555566667777'),
        isTrue,
      );
      expect(CoercionUtils.isValidUuid('not-a-uuid'), isFalse);
    });
  });
}
