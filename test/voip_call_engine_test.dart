import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voip_call_engine/voip_call_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const callReq = CallRequest(
    callId: 'aaaa1111-2222-4333-8444-555566667777',
    callerName: 'Dr. Emre Demir',
    handle: CallHandle(type: CallHandleType.phoneNumber, value: '+905320001122'),
  );

  test(
    'VoipCallEngine synchronizes cold-start PushKit/CallKit events and triggers WebRtcAudioActivationHook',
    () async {
      const channel = MethodChannel('dev.flutter.telecom/voip_engine_unit');
      final platform = MethodChannelVoipCallEngine(methodChannel: channel);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        switch (call.method) {
          case 'initializeAndDrainColdStartBuffer':
            return <Map<String, Object?>>[
              <String, Object?>{
                'type': 'incomingReceived',
                'sequenceNumber': 1,
                'timestampMs': 1700000010000,
                'reportedViaPushKit': true,
                'request': callReq.toMap(),
              },
              <String, Object?>{
                'type': 'answered',
                'sequenceNumber': 2,
                'timestampMs': 1700000011000,
                'callId': callReq.callId,
                'source': 'systemUi',
              },
              <String, Object?>{
                'type': 'audioSessionActivationChanged',
                'sequenceNumber': 3,
                'timestampMs': 1700000011200,
                'isActive': true,
              },
            ];
          case 'reportCallConnected':
            return null;
          case 'getAudioRouteState':
            return <String, Object?>{
              'activeRoute': 'bluetooth',
              'availableRoutes': <String>['earpiece', 'speaker', 'bluetooth'],
              'isAudioSessionActive': true,
              'isMicrophoneMuted': false,
            };
          default:
            return null;
        }
      });

      final engine = VoipCallEngine.custom(platform: platform);
      final webrtcStates = <bool>[];
      engine.audio.registerWebRtcHook(webrtcStates.add);

      final drained = await engine.initialize();
      await Future<void>.delayed(Duration.zero);

      expect(drained, hasLength(3));
      expect(engine.getCall(callReq.callId)?.state, CallState.connecting);
      expect(webrtcStates, contains(true));

      // Now WebRTC ICE completes and reports connected
      final activeSession = await engine.reportCallConnected(callReq.callId);
      expect(activeSession?.state, CallState.active);
      expect(activeSession?.audioSessionActive, isTrue);

      final routeState = await engine.audio.getRouteState();
      expect(routeState.activeRoute, AudioRoute.bluetooth);

      await engine.dispose();
    },
  );
}
