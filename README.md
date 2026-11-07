# voip_call_engine

Production-grade, deterministic **VoIP Call Lifecycle, CallKit, ConnectionService, and Audio Routing Engine** for Flutter (`iOS`, `Android`, `Windows`, `macOS`, and `Web`).

## Why `voip_call_engine`?

1. **Zero-Crash iOS 13+ PushKit & CallKit (`0xbaadca11` Protection):** Reports incoming VoIP calls to `CXProvider` synchronously within the native PushKit callback before the Flutter Engine even warms up, with automatic 120ms Ghost Call mitigation.
2. **Cold-Start Native Event RingBuffer:** Stores `CXAnswerCallAction`, `CXEndCallAction`, and `AVAudioSession` events in a thread-safe native ring buffer while the app is terminated, replaying them in strict FIFO order on `VoipCallEngine.instance.initialize()`.
3. **WebRTC Audio Activation Barrier:** Prevents silent WebRTC calls on iOS/Android by gating `CallState.active` and invoking `registerWebRtcHook` only when `provider(_:didActivate:)` fires.
4. **Enterprise Hardening:**
   - **Out-of-Order Tombstone Registry:** Suppresses late incoming call pushes when a `Cancel` signaling message arrived earlier.
   - **Deterministic Watchdogs:** Automatically cleans up unanswered ringing, stuck ICE connecting, or dropped reconnecting calls.
   - **Multi-Call Hold/Swap & GSM Interruption Detection:** Automatically places active VoIP calls on hold when a second call is answered or when a cellular GSM call interrupts.

## Quick Start

```dart
import 'package:voip_call_engine/voip_call_engine.dart';

Future<void> main() async {
  // 1. Synchronize WebRTC audio with CallKit / ConnectionService activation
  VoipCallEngine.instance.audio.registerWebRtcHook((bool isEnabled) async {
    // Enable/disable WebRTC RTCAudioSession here
  });

  // 2. Listen to exhaustive Dart 3 sealed CallEvents
  VoipCallEngine.instance.events.listen((CallEvent event) {
    switch (event) {
      case CallStateTransitioned(:final session, :final previousState):
        print('${session.callerName}: ${previousState.name} -> ${session.state.name}');
      case CallAudioRouteChanged(:final routeState):
        print('Active route: ${routeState.activeRoute.name}');
      default:
        break;
    }
  });

  // 3. Initialize and drain any cold-start events
  await VoipCallEngine.instance.initialize(
    const VoipEngineConfig(
      ios: IosCallConfig(appName: 'Acme Telecom'),
      android: AndroidCallConfig(phoneAccountLabel: 'Acme Telecom'),
    ),
  );
}
```
