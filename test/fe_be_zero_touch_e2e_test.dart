import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voip_call_engine/voip_call_engine.dart';

String _resolveGoHarnessDir() {
  final candidates = <String>[
    'tools/go_voip_harness',
    '../../../tools/go_voip_harness',
  ];
  for (final rel in candidates) {
    final dir = Directory(rel);
    if (dir.existsSync()) {
      return dir.absolute.path;
    }
  }
  throw StateError('Could not locate tools/go_voip_harness directory.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Restore real OS socket/HTTP transport so Flutter FE communicates with the live Go BE process
  HttpOverrides.global = null;

  test(
    'Zero-Touch Mutual BE (Go Process) <-> FE (Flutter VoipCallEngine) E2E Verification',
    () async {
      final goDir = _resolveGoHarnessDir();

      // 1. Spawn the real Go VoIP Harness process on an ephemeral port (127.0.0.1:0)
      final goProcess = await Process.start(
        'go',
        <String>['run', './cmd/server', '-addr', '127.0.0.1:0'],
        workingDirectory: goDir,
      );
      addTearDown(() {
        goProcess.kill();
      });

      final baseUrlCompleter = Completer<String>();
      goProcess.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((String line) {
        if (line.startsWith('HARNESS_LISTENING=')) {
          final url = line.substring('HARNESS_LISTENING='.length).trim();
          if (!baseUrlCompleter.isCompleted) {
            baseUrlCompleter.complete(url);
          }
        }
      });

      final httpBaseUrl = await baseUrlCompleter.future.timeout(
        const Duration(seconds: 15),
      );

      // 2. Initialize Flutter VoipCallEngine & mock native channel
      const channel = MethodChannel('dev.flutter.telecom/voip_zero_touch_e2e');
      final platform = MethodChannelVoipCallEngine(methodChannel: channel);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'initializeAndDrainColdStartBuffer') {
          return <Map<String, Object?>>[];
        }
        return null;
      });

      final engine = VoipCallEngine.custom(
        platform: platform,
        requireAudioActivationBarrier: false,
      );
      await engine.initialize(
        const VoipEngineConfig(
          ios: IosCallConfig(
            appName: 'E2E Test',
            useManualWebRtcAudioBarrier: false,
          ),
        ),
      );

      // 3. Connect VoipHarnessBridge (FE <-> Go BE WebSocket + HTTP)
      final bridge = VoipHarnessBridge(
        engine: engine,
        httpBaseUrl: httpBaseUrl,
      );
      await bridge.connect();
      addTearDown(() async {
        await bridge.dispose();
        await engine.dispose();
      });

      const call1Id = '11111111-1111-4111-8111-111111111111';
      const call2Id = '22222222-2222-4222-8222-222222222222';
      const ghostCallId = '77777777-8888-4999-8000-111122223333';

      // Scenario A: Go BE triggers Call #1 Incoming -> Answer & Connect -> Active
      await bridge.triggerIncomingCall(
        callId: call1Id,
        callerName: 'Alice (Go BE)',
        handle: '+905321112233',
      );
      await bridge.triggerAnswerCommand(callId: call1Id);

      // Scenario B: Go BE triggers Call #2 Incoming -> Answer & Connect -> Call #1 Auto-Holds!
      await bridge.triggerIncomingCall(
        callId: call2Id,
        callerName: 'Bob (Call Waiting)',
        handle: '+905324445566',
      );
      await bridge.triggerAnswerCommand(callId: call2Id);

      // Wait until FE processes both calls and Call #1 is onHold while Call #2 is active
      await _waitForCondition(
        () =>
            engine.getCall(call1Id)?.state == CallState.onHold &&
            engine.getCall(call2Id)?.state == CallState.active,
      );

      expect(engine.getCall(call1Id)?.state, CallState.onHold);
      expect(engine.getCall(call2Id)?.state, CallState.active);

      // Scenario C: End Call #1 so a slot is free, then trigger Ghost Call from Go BE
      await engine.endCall(call1Id, reason: CallEndReason.localHangup);
      await bridge.triggerGhostCallScenario();

      await _waitForCondition(
        () => engine.getCall(ghostCallId)?.state == CallState.ended,
      );
      expect(
        engine.getCall(ghostCallId)?.endReason,
        CallEndReason.remoteCancelled,
      );

      // Scenario D: Acoustic 440Hz Loopback DSP Verification (FE downloads PCM from BE -> BE Goertzel DSP verifies)
      final audioReport = await bridge.performAcousticLoopbackCheck();
      expect(audioReport['targetTonePresent'], isTrue);
      expect(audioReport['isSilent'], isFalse);
      expect(audioReport['hasClipping'], isFalse);

      // Scenario E: Query Go BE's /api/e2e/report to prove Go BE received & verified FE's state transition ACKs!
      await _waitForCondition(() async {
        final rep = await bridge.fetchBackendE2eReport();
        return (rep['ackCount'] as int? ?? 0) >= 6;
      });

      final backendReport = await bridge.fetchBackendE2eReport();
      expect(backendReport['audioVerified'], isTrue);
      final acks = (backendReport['acks'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final statesObservedByGoBe =
          acks.map((a) => a['currentState'] as String).toSet();

      expect(
        statesObservedByGoBe,
        containsAll(<String>[
          'incomingRinging',
          'active',
          'onHold',
          'ended',
        ]),
      );
    },
  );
}

Future<void> _waitForCondition(
  FutureOr<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw TimeoutException('Condition not satisfied within $timeout');
}
