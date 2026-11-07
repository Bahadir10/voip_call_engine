import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voip_call_engine/voip_call_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'Live WebSocket Signaling Loopback Integration — Incoming Call, Call Waiting & Remote Hangup',
    () async {
      const channel = MethodChannel('dev.flutter.telecom/voip_live_ws_test');
      final platform = MethodChannelVoipCallEngine(methodChannel: channel);

      final nativeInvocations = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        nativeInvocations.add(call.method);
        if (call.method == 'initializeAndDrainColdStartBuffer') {
          return <Map<String, Object?>>[];
        }
        return null;
      });

      final engine = VoipCallEngine.custom(
        platform: platform,
        requireAudioActivationBarrier: false,
      );
      await engine.initialize();

      // Spin up a real loopback WebSocket signaling server matching the Go Harness protocol
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSockets = <WebSocket>[];
      final serverSub = server.listen((HttpRequest req) async {
        if (req.uri.path == '/ws') {
          final socket = await WebSocketTransformer.upgrade(req);
          serverSockets.add(socket);
        }
      });

      final clientWs = await WebSocket.connect(
        'ws://127.0.0.1:${server.port}/ws',
      );
      final processedEvents = Completer<void>();
      var receivedSignalingCount = 0;

      final wsSub = clientWs.listen((dynamic raw) async {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        final type = msg['type'] as String;
        final callId = msg['callId'] as String;

        if (type == 'incoming_call') {
          await engine.reportIncomingCall(
            CallRequest(
              callId: callId,
              callerName: msg['callerName'] as String,
              handle: CallHandle(
                type: CallHandleType.phoneNumber,
                value: msg['handle'] as String,
              ),
            ),
          );
        } else if (type == 'answer_and_connect') {
          await engine.answerCall(callId);
          await engine.reportCallConnected(callId);
        } else if (type == 'remote_hangup') {
          await engine.endCall(callId, reason: CallEndReason.remoteHangup);
        }

        receivedSignalingCount++;
        if (receivedSignalingCount == 4 && !processedEvents.isCompleted) {
          processedEvents.complete();
        }
      });

      // Wait briefly for server to register the upgraded WebSocket
      while (serverSockets.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      const call1 = '11111111-1111-4111-8111-111111111111';
      const call2 = '22222222-2222-4222-8222-222222222222';

      // Broadcast 4 signaling frames from server -> client:
      // 1) Call 1 Incoming
      // 2) Call 1 Answered & Connected -> Active
      // 3) Call 2 Incoming (Call Waiting)
      // 4) Call 1 Remote Hangup
      serverSockets.single.add(
        jsonEncode(<String, Object?>{
          'type': 'incoming_call',
          'callId': call1,
          'callerName': 'Line 1 Peer',
          'handle': '+905320000001',
        }),
      );
      serverSockets.single.add(
        jsonEncode(<String, Object?>{
          'type': 'answer_and_connect',
          'callId': call1,
        }),
      );
      serverSockets.single.add(
        jsonEncode(<String, Object?>{
          'type': 'incoming_call',
          'callId': call2,
          'callerName': 'Line 2 Peer',
          'handle': '+905320000002',
        }),
      );
      serverSockets.single.add(
        jsonEncode(<String, Object?>{
          'type': 'remote_hangup',
          'callId': call1,
        }),
      );

      await processedEvents.future.timeout(const Duration(seconds: 3));

      expect(engine.getCall(call1)?.state, CallState.ended);
      expect(engine.getCall(call1)?.endReason, CallEndReason.remoteHangup);
      expect(engine.getCall(call2)?.state, CallState.incomingRinging);
      expect(
        nativeInvocations,
        containsAll(<String>[
          'initializeAndDrainColdStartBuffer',
          'reportIncomingCall',
          'answerCall',
          'reportCallConnected',
          'endCall',
        ]),
      );

      await wsSub.cancel();
      await clientWs.close();
      for (final s in serverSockets) {
        await s.close();
      }
      await serverSub.cancel();
      await server.close(force: true);
      await engine.dispose();
    },
  );
}
