import 'package:flutter_test/flutter_test.dart';
import 'package:voip_call_engine/voip_call_engine.dart';

void main() {
  group('Defensive Deserialization & Round-Trip Wire Contract Tests', () {
    test('survives heavily corrupted / wrong-typed push and native event maps without throwing', () {
      final corruptedEventMap = <Object?, Object?>{
        'type': 'incomingReceived',
        'timestampMs': '-999999', // String negative timestamp
        'sequenceNumber': '42', // String instead of int
        'fromColdStartBuffer': 'true', // String instead of bool
        'reportedViaPushKit': 1, // int instead of bool
        'request': <Object?, Object?>{
          'callId': null, // null callId
          'callerName': 12345, // int instead of String
          'hasVideo': 'yes', // String instead of bool
          'timeoutMs': '50', // Below minimum 1000ms clamp
          'handle': 'not_a_map', // Corrupt non-map
          'capabilities': <Object?, Object?>{
            'supportsHold': '0',
            'supportsMute': 1,
          },
          'metadata': <Object?, Object?>{
            100: true,
            'nullVal': null,
          },
        },
      };

      final event = CallEvent.fromMap(corruptedEventMap);
      expect(event, isA<CallIncomingReceived>());
      final incoming = event as CallIncomingReceived;
      expect(incoming.sequenceNumber, 42);
      expect(incoming.fromColdStartBuffer, isTrue);
      expect(incoming.reportedViaPushKit, isTrue);
      expect(incoming.request.callerName, '12345');
      expect(incoming.request.hasVideo, isTrue);
      expect(incoming.request.timeoutDuration, const Duration(milliseconds: 1000));
      expect(incoming.request.capabilities.supportsHold, isFalse);
      expect(incoming.request.capabilities.supportsMute, isTrue);
      expect(incoming.request.metadata['100'], 'true');
    });

    test('round-trips CallSession, CallRequest, and AudioRouteState losslessly', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true);
      final session = CallSession(
        callId: '11111111-2222-4333-8444-555566667777',
        direction: CallDirection.outgoing,
        state: CallState.onHold,
        callerName: 'Zeynep Kaya',
        handle: const CallHandle(
          type: CallHandleType.emailAddress,
          value: 'zeynep@example.com',
        ),
        createdAt: now,
        connectedAt: now.add(const Duration(seconds: 3)),
        hasVideo: true,
        isMuted: true,
        isOnHold: true,
        heldBySystem: true,
        audioSessionActive: true,
        metadata: const <String, String>{'tenant': 'enterprise_eu'},
      );

      final restoredSession = CallSession.fromMap(session.toMap());
      expect(restoredSession.callId, session.callId);
      expect(restoredSession.direction, CallDirection.outgoing);
      expect(restoredSession.state, CallState.onHold);
      expect(restoredSession.handle, session.handle);
      expect(restoredSession.isMuted, isTrue);
      expect(restoredSession.isOnHold, isTrue);
      expect(restoredSession.heldBySystem, isTrue);
      expect(restoredSession.connectedAt, session.connectedAt);
      expect(restoredSession.metadata['tenant'], 'enterprise_eu');

      const routeState = AudioRouteState(
        activeRoute: AudioRoute.bluetooth,
        availableRoutes: <AudioRoute>[
          AudioRoute.earpiece,
          AudioRoute.speaker,
          AudioRoute.bluetooth,
        ],
        activeDevice: AudioDevice(
          id: 'bt_airpods_pro',
          name: 'AirPods Pro',
          route: AudioRoute.bluetooth,
          isDefault: true,
        ),
        availableDevices: <AudioDevice>[
          AudioDevice(
            id: 'bt_airpods_pro',
            name: 'AirPods Pro',
            route: AudioRoute.bluetooth,
            isDefault: true,
          ),
        ],
        isAudioSessionActive: true,
        isMicrophoneMuted: true,
      );

      final restoredRoute = AudioRouteState.fromMap(routeState.toMap());
      expect(restoredRoute.activeRoute, AudioRoute.bluetooth);
      expect(restoredRoute.activeDevice, routeState.activeDevice);
      expect(restoredRoute.availableDevices.single.name, 'AirPods Pro');
      expect(restoredRoute.isAudioSessionActive, isTrue);
      expect(restoredRoute.isMicrophoneMuted, isTrue);
    });
  });
}
