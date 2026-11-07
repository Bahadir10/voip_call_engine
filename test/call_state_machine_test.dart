import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voip_call_engine/voip_call_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const call1Request = CallRequest(
    callId: '11111111-1111-4111-8111-111111111111',
    callerName: 'Alice Yılmaz',
    handle: CallHandle(type: CallHandleType.phoneNumber, value: '+905551112233'),
  );

  const call2Request = CallRequest(
    callId: '22222222-2222-4222-8222-222222222222',
    callerName: 'Bob Kaya',
    handle: CallHandle(type: CallHandleType.phoneNumber, value: '+905554445566'),
  );

  group('CallStateMachine — Audio Barrier & Single Call Lifecycle', () {
    test(
      'keeps answered call in connecting state until both media and native audio session activate',
      () {
        final emittedEvents = <CallEvent>[];
        final sm = CallStateMachine(
          requireAudioActivationBarrier: true,
          onEventEmitted: emittedEvents.add,
        );

        final ringing = sm.registerIncomingCall(call1Request);
        expect(ringing.state, CallState.incomingRinging);

        // User swipes to answer in CallKit
        final answered = sm.markAnswered(call1Request.callId)!;
        expect(answered.state, CallState.connecting);

        // WebRTC ICE/SDP finishes connecting BEFORE CallKit didActivate(audioSession)
        final mediaReady = sm.markMediaConnected(call1Request.callId)!;
        expect(
          mediaReady.state,
          CallState.connecting,
          reason: 'Must wait for CallKit AVAudioSession activation barrier',
        );

        // Now CallKit fires provider(_:didActivate:)
        sm.onNativeAudioSessionChanged(true);
        final active = sm.getSession(call1Request.callId)!;
        expect(active.state, CallState.active);
        expect(active.audioSessionActive, isTrue);
        expect(active.connectedAt, isNotNull);

        // End call
        final ended = sm.endCall(
          call1Request.callId,
          reason: CallEndReason.remoteHangup,
        )!;
        expect(ended.state, CallState.ended);
        expect(ended.endReason, CallEndReason.remoteHangup);
        expect(sm.activeSessions, isEmpty);
      },
    );

    test('emits diagnostic event and refuses illegal transition from ended to active', () {
      final diagnostics = <CallDiagnosticEvent>[];
      final sm = CallStateMachine(
        onEventEmitted: (event) {
          if (event is CallDiagnosticEvent) {
            diagnostics.add(event);
          }
        },
      );

      sm.registerIncomingCall(call1Request);
      sm.endCall(call1Request.callId, reason: CallEndReason.localRejected);

      final result = sm.setHold(call1Request.callId, isOnHold: true);
      expect(result?.state, CallState.ended);
      expect(diagnostics, isEmpty); // setHold returns early on ended calls

      // Direct markOutgoingRinging on an ended call triggers INVALID_STATE_TRANSITION
      sm.markOutgoingRinging(call1Request.callId);
      expect(diagnostics.single.code, 'INVALID_STATE_TRANSITION');
    });
  });

  group('CallStateMachine — Multi-Call Hold, Swap & GSM Interruption', () {
    test('automatically places Call 1 on hold when Call 2 is answered and swaps cleanly', () {
      final sm = CallStateMachine(requireAudioActivationBarrier: false);

      sm.registerIncomingCall(call1Request);
      sm.markAnswered(call1Request.callId);
      sm.markMediaConnected(call1Request.callId);
      expect(sm.getSession(call1Request.callId)!.state, CallState.active);

      // Second call arrives (Call Waiting)
      sm.registerIncomingCall(call2Request);
      expect(sm.getSession(call2Request.callId)!.state, CallState.incomingRinging);
      expect(sm.getSession(call1Request.callId)!.state, CallState.active);

      // User answers Call 2 -> Call 1 must auto-hold
      sm.markAnswered(call2Request.callId);
      sm.markMediaConnected(call2Request.callId);

      expect(sm.getSession(call1Request.callId)!.state, CallState.onHold);
      expect(sm.getSession(call1Request.callId)!.isOnHold, isTrue);
      expect(sm.getSession(call2Request.callId)!.state, CallState.active);

      // Swap calls
      sm.swapCalls(
        activeCallId: call2Request.callId,
        heldCallId: call1Request.callId,
      );
      expect(sm.getSession(call1Request.callId)!.state, CallState.active);
      expect(sm.getSession(call2Request.callId)!.state, CallState.onHold);
    });

    test('tracks GSM cellular call interruption with heldBySystem flag', () {
      final sm = CallStateMachine(requireAudioActivationBarrier: false);
      sm.registerIncomingCall(call1Request);
      sm.markAnswered(call1Request.callId);
      sm.markMediaConnected(call1Request.callId);

      // Android ConnectionService / iOS CallKit puts call on hold due to GSM call
      final held = sm.setHold(
        call1Request.callId,
        isOnHold: true,
        heldBySystem: true,
      )!;
      expect(held.state, CallState.onHold);
      expect(held.heldBySystem, isTrue);

      // GSM call finishes and user resumes VoIP call
      final resumed = sm.setHold(
        call1Request.callId,
        isOnHold: false,
      )!;
      expect(resumed.state, CallState.active);
      expect(resumed.heldBySystem, isFalse);
    });
  });

  group('MethodChannelVoipCallEngine — Cold-Start Native Buffer Replay', () {
    test('drains buffered PushKit + CallKit events in FIFO order on initialize', () async {
      const channelName = 'dev.flutter.telecom/voip_call_engine_test';
      const channel = MethodChannel(channelName);
      final platform = MethodChannelVoipCallEngine(methodChannel: channel);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'initializeAndDrainColdStartBuffer') {
          return <Map<String, Object?>>[
            <String, Object?>{
              'type': 'incomingReceived',
              'sequenceNumber': 1,
              'timestampMs': 1700000000000,
              'reportedViaPushKit': true,
              'request': call1Request.toMap(),
            },
            <String, Object?>{
              'type': 'answered',
              'sequenceNumber': 2,
              'timestampMs': 1700000001500,
              'callId': call1Request.callId,
              'source': 'systemUi',
            },
            <String, Object?>{
              'type': 'audioSessionActivationChanged',
              'sequenceNumber': 3,
              'timestampMs': 1700000001600,
              'isActive': true,
            },
          ];
        }
        return null;
      });

      final streamEvents = <CallEvent>[];
      final sub = platform.events.listen(streamEvents.add);

      final drained = await platform.initialize(const VoipEngineConfig());
      await Future<void>.delayed(Duration.zero);

      expect(drained, hasLength(3));
      expect(drained[0], isA<CallIncomingReceived>());
      expect(drained[0].fromColdStartBuffer, isTrue);
      expect(drained[1], isA<CallAnswered>());
      expect(drained[2], isA<CallAudioSessionActivationChanged>());
      expect(streamEvents, hasLength(3));

      await sub.cancel();
    });
  });
}
