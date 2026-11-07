import 'dart:async';

import 'package:flutter/material.dart';
import 'package:voip_call_engine/voip_call_engine.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VoipCallEngineExampleApp());
}

class VoipCallEngineExampleApp extends StatelessWidget {
  const VoipCallEngineExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'voip_call_engine Example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF0D9488),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const VoipExamplePage(),
    );
  }
}

class VoipExamplePage extends StatefulWidget {
  const VoipExamplePage({super.key});

  @override
  State<VoipExamplePage> createState() => _VoipExamplePageState();
}

class _VoipExamplePageState extends State<VoipExamplePage> {
  final VoipCallEngine _engine = VoipCallEngine.instance;
  late final VoipHarnessBridge _harnessBridge = VoipHarnessBridge(
    engine: _engine,
    httpBaseUrl: 'http://127.0.0.1:8090',
  );

  final List<String> _logs = <String>[];
  StreamSubscription<CallEvent>? _eventSub;
  AudioRouteState _routeState = const AudioRouteState(
    activeRoute: AudioRoute.earpiece,
    availableRoutes: <AudioRoute>[
      AudioRoute.earpiece,
      AudioRoute.speaker,
      AudioRoute.bluetooth,
      AudioRoute.wiredHeadset,
    ],
  );
  bool _webrtcAudioReady = false;

  static const String _callId1 = '11111111-2222-4333-8444-555566667777';
  static const String _callId2 = '99999999-8888-4777-8666-555544443333';

  @override
  void initState() {
    super.initState();
    _setupEngine();
  }

  Future<void> _setupEngine() async {
    _engine.audio.registerWebRtcHook((enabled) {
      if (!mounted) return;
      setState(() => _webrtcAudioReady = enabled);
      _log('WebRTC Audio Hook -> enabled=$enabled');
    });

    _eventSub = _engine.events.listen((event) {
      if (!mounted) return;
      setState(() {});
      switch (event) {
        case CallStateTransitioned(:final session, :final previousState):
          _log('${session.callerName}: ${previousState.name} -> ${session.state.name}');
        case CallAudioRouteChanged(:final routeState, :final reason):
          setState(() => _routeState = routeState);
          _log('Route -> ${routeState.activeRoute.name} ($reason)');
        case CallEnded(:final callId, :final reason):
          _log('Ended [$callId] (${reason.name})');
        default:
          break;
      }
    });

    await _engine.initialize(
      const VoipEngineConfig(
        ios: IosCallConfig(appName: 'VoIP Engine Example'),
        android: AndroidCallConfig(phoneAccountLabel: 'VoIP Engine Example'),
      ),
    );
  }

  void _log(String msg) {
    setState(() {
      _logs.insert(0, msg);
      if (_logs.length > 50) _logs.removeLast();
    });
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _harnessBridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeCalls = _engine.activeCalls.values.toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('voip_call_engine Example'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Chip(
              label: Text(
                _webrtcAudioReady ? 'Audio Ready' : 'Audio Barrier Locked',
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton(
                onPressed: () => _engine.reportIncomingCall(
                  const CallRequest(
                    callId: _callId1,
                    callerName: 'Alice Yılmaz (Line 1)',
                    handle: CallHandle(
                      type: CallHandleType.phoneNumber,
                      value: '+905321112233',
                    ),
                  ),
                ),
                child: const Text('Simulate Incoming #1'),
              ),
              FilledButton.tonal(
                onPressed: () => _engine.reportIncomingCall(
                  const CallRequest(
                    callId: _callId2,
                    callerName: 'Bob Kaya (Line 2)',
                    handle: CallHandle(
                      type: CallHandleType.phoneNumber,
                      value: '+905324445566',
                    ),
                  ),
                ),
                child: const Text('Simulate Incoming #2'),
              ),
              OutlinedButton(
                onPressed: () async {
                  try {
                    await _harnessBridge.connect();
                    _log('Connected to Go Harness (${_harnessBridge.wsUrl})');
                  } catch (e) {
                    _log('Go Harness offline: $e');
                  }
                },
                child: const Text('Connect Go E2E Harness'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: AudioRoute.values.map((route) {
              return ChoiceChip(
                label: Text(route.name),
                selected: _routeState.activeRoute == route,
                onSelected: (_) => _engine.audio.setRoute(route),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          if (activeCalls.isEmpty)
            const Text('No active calls.')
          else
            ...activeCalls.map(
              (c) => Card(
                child: ListTile(
                  title: Text('${c.callerName} (${c.state.name})'),
                  subtitle: Text('Hold: ${c.isOnHold} | Muted: ${c.isMuted}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (c.state == CallState.incomingRinging)
                        IconButton(
                          tooltip: 'Answer Call',
                          onPressed: () async {
                            await _engine.answerCall(c.callId);
                            await _engine.reportCallConnected(c.callId);
                          },
                          icon: const Icon(Icons.call),
                        ),
                      IconButton(
                        tooltip: 'Hangup Call',
                        onPressed: () => _engine.endCall(c.callId),
                        icon: const Icon(Icons.call_end),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const Divider(height: 24),
          ..._logs.take(10).map(Text.new),
        ],
      ),
    );
  }
}
