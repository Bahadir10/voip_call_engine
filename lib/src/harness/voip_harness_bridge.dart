import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/call_events.dart';
import '../models/call_models.dart';
import '../voip_call_engine_client.dart';

/// Bidirectional E2E test and signaling bridge connecting Flutter [VoipCallEngine] (FE)
/// with the Go `go_voip_harness` backend server (BE).
///
/// Automatically executes incoming backend signaling commands on [VoipCallEngine]
/// and streams `fe_ack` state-transition telemetry back to the Go backend.
class VoipHarnessBridge {
  VoipHarnessBridge({
    required this.engine,
    required this.httpBaseUrl,
  });

  final VoipCallEngine engine;
  final String httpBaseUrl;

  final HttpClient _httpClient = HttpClient();
  WebSocket? _ws;
  StreamSubscription<dynamic>? _wsSub;
  StreamSubscription<CallEvent>? _engineSub;

  String get wsUrl {
    final uri = Uri.parse(httpBaseUrl);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    return '$scheme://${uri.host}:${uri.port}/ws';
  }

  bool get isConnected => _ws != null && _ws!.readyState == WebSocket.open;

  /// Connects to the Go Harness WebSocket and begins bidirectional telemetry sync.
  Future<void> connect() async {
    await disconnect();
    // ignore: close_sinks
    final socket = await WebSocket.connect(wsUrl);
    _ws = socket;

    _engineSub = engine.events.listen((CallEvent event) {
      if (event is CallStateTransitioned) {
        final ack = <String, Object?>{
          'type': 'fe_ack',
          'callId': event.session.callId,
          'previousState': event.previousState.name,
          'currentState': event.session.state.name,
          'endReason': event.session.endReason?.name ?? '',
          'timestampMs': event.timestamp.millisecondsSinceEpoch,
        };
        if (_ws != null && _ws!.readyState == WebSocket.open) {
          _ws!.add(jsonEncode(ack));
        }
      }
    });

    _wsSub = socket.listen((dynamic raw) async {
      if (raw is! String) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final type = map['type'] as String? ?? '';
      final callId = map['callId'] as String? ?? '';

      switch (type) {
        case 'incoming_call':
          await engine.reportIncomingCall(
            CallRequest(
              callId: callId,
              callerName: map['callerName'] as String? ?? 'Go Peer',
              handle: CallHandle(
                type: CallHandleType.phoneNumber,
                value: map['handle'] as String? ?? '+905550000000',
              ),
            ),
          );
        case 'command_answer_and_connect':
          await engine.answerCall(callId);
          await engine.reportCallConnected(callId);
        case 'remote_hangup':
          final reasonStr = map['reason'] as String? ?? 'remoteHangup';
          final reason = CallEndReason.values.firstWhere(
            (r) => r.name == reasonStr,
            orElse: () => CallEndReason.remoteHangup,
          );
          await engine.endCall(callId, reason: reason);
      }
    });
  }

  /// Triggers a simulated incoming call from the Go backend.
  Future<Map<String, dynamic>> triggerIncomingCall({
    required String callId,
    required String callerName,
    required String handle,
  }) {
    return _postJson('/api/calls/incoming', <String, Object?>{
      'callId': callId,
      'callerName': callerName,
      'handle': handle,
    });
  }

  /// Instructs the Go backend to broadcast an answer-and-connect command to FE.
  Future<Map<String, dynamic>> triggerAnswerCommand({required String callId}) {
    return _postJson('/api/calls/answer', <String, Object?>{
      'callId': callId,
    });
  }

  /// Triggers the Ghost Call (Incoming + Immediate Remote Cancel) scenario from Go BE.
  Future<Map<String, dynamic>> triggerGhostCallScenario() {
    return _postJson('/api/calls/ghost', const <String, Object?>{});
  }

  /// Triggers the Dual Call Waiting scenario from Go BE.
  Future<Map<String, dynamic>> triggerCallWaitingScenario() {
    return _postJson('/api/calls/waiting', const <String, Object?>{});
  }

  /// Downloads the 440Hz PCM16 test audio stream from Go BE (`GET /api/audio/tone`),
  /// loops it back to Go BE's Goertzel DSP analyzer (`POST /api/audio/verify`),
  /// and returns the acoustic analysis report.
  Future<Map<String, dynamic>> performAcousticLoopbackCheck() async {
    final toneReq = await _httpClient.getUrl(
      Uri.parse('$httpBaseUrl/api/audio/tone'),
    );
    final toneResp = await toneReq.close();
    final builder = BytesBuilder(copy: false);
    await for (final chunk in toneResp) {
      builder.add(chunk);
    }
    final pcmBytes = builder.takeBytes();

    final verifyReq = await _httpClient.postUrl(
      Uri.parse('$httpBaseUrl/api/audio/verify'),
    );
    verifyReq.headers.contentType = ContentType.binary;
    verifyReq.add(pcmBytes);
    final verifyResp = await verifyReq.close();
    final body = await verifyResp.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// Fetches the Go backend's E2E verification report (`GET /api/e2e/report`) containing
  /// all recorded `fe_ack` state transitions and acoustic verification status.
  Future<Map<String, dynamic>> fetchBackendE2eReport() async {
    final req = await _httpClient.getUrl(
      Uri.parse('$httpBaseUrl/api/e2e/report'),
    );
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, Object?> payload,
  ) async {
    final req = await _httpClient.postUrl(Uri.parse('$httpBaseUrl$path'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(payload));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// Closes the WebSocket and HTTP client resources.
  Future<void> disconnect() async {
    await _engineSub?.cancel();
    _engineSub = null;
    await _wsSub?.cancel();
    _wsSub = null;
    await _ws?.close();
    _ws = null;
  }

  Future<void> dispose() async {
    await disconnect();
    _httpClient.close(force: true);
  }
}
