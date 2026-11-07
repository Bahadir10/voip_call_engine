import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:voip_call_engine/voip_call_engine.dart';

void main() {
  group('Enterprise Chaos & Fuzz State Machine Verification (10,000 Steps)', () {
    test(
      'maintains all 5 strict telecom invariants across 10,000 randomized multi-call, GSM hold, audio barrier, and network drop operations',
      () {
        final rng = Random(20261107);
        var transitionEvents = 0;
        var diagnosticEvents = 0;

        final sm = CallStateMachine(
          requireAudioActivationBarrier: true,
          maxConcurrentCalls: 2,
          enableWatchdogTimers: false,
          onEventEmitted: (event) {
            if (event is CallStateTransitioned) transitionEvents++;
            if (event is CallDiagnosticEvent) diagnosticEvents++;
          },
        );

        final callPool = List<String>.generate(
          6,
          (i) => '0000000$i-1111-4222-8333-44445555666$i',
        );

        const reasons = CallEndReason.values;

        for (var step = 0; step < 10000; step++) {
          final callId = callPool[rng.nextInt(callPool.length)];
          final action = rng.nextInt(12);

          switch (action) {
            case 0:
              sm.registerIncomingCall(
                CallRequest(
                  callId: callId,
                  callerName: 'Fuzz Caller $step',
                  handle: CallHandle(
                    type: CallHandleType.phoneNumber,
                    value: '+90555000$step',
                  ),
                ),
              );
            case 1:
              sm.registerOutgoingCall(
                CallRequest(
                  callId: callId,
                  callerName: 'Fuzz Callee $step',
                  handle: CallHandle(
                    type: CallHandleType.generic,
                    value: 'sip:user$step@example.com',
                  ),
                ),
              );
            case 2:
              sm.markOutgoingRinging(callId);
            case 3:
              sm.markAnswered(callId);
            case 4:
              sm.markMediaConnected(callId);
            case 5:
              sm.onNativeAudioSessionChanged(rng.nextBool());
            case 6:
              sm.setHold(
                callId,
                isOnHold: rng.nextBool(),
                heldBySystem: rng.nextBool(),
              );
            case 7:
              final otherId = callPool[rng.nextInt(callPool.length)];
              if (otherId != callId) {
                sm.swapCalls(activeCallId: callId, heldCallId: otherId);
              }
            case 8:
              sm.setMuted(callId, isMuted: rng.nextBool());
            case 9:
              sm.markReconnecting(callId);
            case 10:
              sm.endCall(
                callId,
                reason: reasons[rng.nextInt(reasons.length)],
              );
            case 11:
              if (rng.nextInt(5) == 0) {
                sm.pruneEndedSessions();
              }
          }

          // Verify all 5 strict invariants after EVERY SINGLE operation!
          sm.verifyInvariants();
        }

        expect(transitionEvents, greaterThan(1000));
        expect(diagnosticEvents, greaterThan(100));
        sm.dispose();
      },
    );
  });
}
