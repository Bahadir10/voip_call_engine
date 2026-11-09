# voip_call_engine

[![pub package](https://img.shields.io/pub/v/voip_call_engine.svg?logo=dart)](https://pub.dev/packages/voip_call_engine)
[![likes](https://img.shields.io/pub/likes/voip_call_engine)](https://pub.dev/packages/voip_call_engine)
[![pub points](https://img.shields.io/pub/points/voip_call_engine)](https://pub.dev/packages/voip_call_engine/score)
[![license](https://img.shields.io/github/license/Bahadir10/voip_call_engine)](https://github.com/Bahadir10/voip_call_engine/blob/main/LICENSE)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20Android%20%7C%20Windows%20%7C%20macOS%20%7C%20Web-blue)](https://pub.dev/packages/voip_call_engine)

Production-grade, deterministic **VoIP Call Lifecycle, CallKit, ConnectionService, and Audio Routing Engine** for Flutter (`iOS`, `Android`, `Windows`, `macOS`, and `Web`).

Designed specifically to eliminate the most critical issues encountered when building real-time VoIP applications (e.g., WhatsApp, Discord, or Twilio-scale dialers) using WebRTC or SIP.

---

## 🌟 Key Highlights & Why `voip_call_engine`?

| Critical Problem in Existing Packages | How `voip_call_engine` Solves It |
| :--- | :--- |
| **iOS 13+ PushKit Fatal Termination (`0xbaadca11`)** | Apple terminates apps if `CXProvider.reportNewIncomingCall` is not called within the same runloop as `PKPushRegistry`. We handle this **100% natively in Swift** before the Dart VM even boots. |
| **Ghost / Canceled Call Crashes on iOS** | If a caller hangs up before delivery, Apple still mandates reporting to CallKit. We automatically report and dismiss canceled pushes within 120ms to keep your app in good standing. |
| **Lost Events on Cold-Start (App Terminated)** | Actions performed from lock screens (e.g., swipe to answer) while the Flutter Engine is starting are buffered in a thread-safe native FIFO `NativeEventRingBuffer` and replayed on `initialize()`. |
| **Silent WebRTC Calls (Audio Race Conditions)** | Starting WebRTC audio before CallKit's `AVAudioSession` is activated causes completely silent calls. Our **Audio Activation Barrier** blocks `CallState.active` until native audio is confirmed ready. |
| **Android Telecom & OEM Fragmentation** | Uses Android's native Self-Managed `ConnectionService` (and Jetpack Telecom). Integrates with Android Auto, Bluetooth headset buttons, WearOS, and automatic GSM call hold (`heldBySystem`). |
| **Dynamic Audio Routing Across 5 Platforms** | Seamlessly switches between Earpiece, Speakerphone, Bluetooth (SCO & BLE Audio), and Wired Headsets with fallback chains on Android 12+ (`setCommunicationDevice`), iOS, WASAPI, CoreAudio, and Web. |

---

## 🏗️ Call State Machine

All calls transition through a strict 5-invariant deterministic state machine:

```text
       [ reportIncomingCall() ]              [ startOutgoingCall() ]
                 │                                      │
                 ▼                                      ▼
         incomingRinging                         outgoingDialing
                 │                                      │
                 │ [ answerCall() ]                     ▼
                 │                               outgoingRinging
                 ▼                                      │
            connecting ◄────────────────────────────────┘
                 │
                 │ [ Media Connected + Native Audio Session Activated ]
                 ▼
              active ◄──────────┐
                 │              │ [ setHold(false) ]
                 │              │
                 ├────────► onHold (User or GSM Interruption)
                 │
                 ├────────► reconnecting (Network Drop Grace Window)
                 │
                 ▼ [ endCall() / Reject / Timeout / Cancel ]
               ended
```

---

## 📱 Platform Setup Guide

### 1. iOS Setup

In Xcode, open your `ios/Runner.xcworkspace`:

#### Capabilities & Entitlements
Under **Runner > Signing & Capabilities**, click **+ Capability**:
1. **Background Modes**:
   - Check `Audio, AirPlay, and Picture in Picture`
   - Check `Voice over IP`
2. **Push Notifications** (Required for Apple VoIP Push certificates)

#### Info.plist
Add the following keys to `ios/Runner/Info.plist`:

```xml
<!-- Microphone permission for VoIP calls -->
<key>NSMicrophoneUsageDescription</key>
<string>$(PRODUCT_NAME) requires microphone access for crystal-clear voice and video calls.</string>

<!-- Required background audio & VoIP modes -->
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
    <string>voip</string>
</array>
```

#### Apple VoIP Push (PushKit) Payload Format
When sending a VoIP Push via APNs (`apns-push-type: voip`), format the JSON payload as follows so the native Swift coordinator can parse and report it immediately:

```json
{
  "aps": {},
  "voip": {
    "callId": "11111111-2222-4333-8444-555566667777",
    "callerName": "Alice Yılmaz",
    "handleValue": "+905551112233",
    "handleType": "phoneNumber",
    "hasVideo": false,
    "action": "incoming"
  }
}
```
*(If the caller canceled before delivery, set `"action": "cancel"` or `"isCancelled": true` to activate Ghost Call mitigation).*

---

### 2. Android Setup

In `android/app/src/main/AndroidManifest.xml`, configure permissions inside `<manifest>`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- Required for Self-Managed Android Telecom Integration -->
    <uses-permission android:name="android.permission.MANAGE_OWN_CALLS" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_PHONE_CALL" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
    <uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT" />
    <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    <uses-permission android:name="android.permission.BLUETOOTH" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <uses-permission android:name="android.permission.VIBRATE" />

    <application ...>
        <!-- The VoipConnectionService is automatically provided by the plugin manifest -->
    </application>
</manifest>
```

---

## 🚀 Quick Start & Code Examples

### 1. Engine Initialization & Event Subscription

Initialize the engine early in `main()` or your initial authentication route:

```dart
import 'package:flutter/material.dart';
import 'package:voip_call_engine/voip_call_engine.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Listen to all lifecycle events using Dart 3 sealed class pattern matching
  VoipCallEngine.instance.events.listen((CallEvent event) {
    switch (event) {
      case CallIncomingReceived(:final request, :final reportedViaPushKit):
        print('Incoming call from ${request.callerName} (via PushKit: $reportedViaPushKit)');

      case CallAnswered(:final callId, :final source):
        print('Call $callId answered from source: ${source.name}');

      case CallStateTransitioned(:final session, :final previousState):
        print('State transition: ${previousState.name} -> ${session.state.name}');

      case CallHeldChanged(:final callId, :final isOnHold, :final heldBySystem):
        if (heldBySystem) {
          print('Call $callId was automatically placed on hold due to a cellular GSM call!');
        } else {
          print('Call $callId hold status: $isOnHold');
        }

      case CallAudioRouteChanged(:final routeState, :final reason):
        print('Audio routed to: ${routeState.activeRoute.name} ($reason)');

      case CallEnded(:final callId, :final reason, :final source):
        print('Call $callId ended. Reason: ${reason.name}, Source: ${source.name}');

      case VoipPushTokenUpdated(:final token, :final environment):
        print('VoIP Push token updated ($environment): $token');

      default:
        break;
    }
  });

  // 2. Initialize native subsystems and drain buffered cold-start events
  final bufferedEvents = await VoipCallEngine.instance.initialize(
    const VoipEngineConfig(
      ios: IosCallConfig(
        appName: 'Acme Telecom',
        supportsVideo: true,
        ringtoneSound: 'custom_ring.caf',
      ),
      android: AndroidCallConfig(
        phoneAccountLabel: 'Acme VoIP Service',
        preferJetpackCoreTelecom: true,
      ),
    ),
  );

  runApp(const MyApp());
}
```

---

### 2. Synchronizing WebRTC Audio (No More Silent Calls!)

Use `registerWebRtcHook` to enable or disable WebRTC audio when native telecom confirms activation:

```dart
// Hook WebRTC's audio engine directly to CallKit's AVAudioSession lifecycle
VoipCallEngine.instance.audio.registerWebRtcHook((bool isAudioEnabled) async {
  if (isAudioEnabled) {
    // 1. Tell WebRTC that AVAudioSession is active and ready for I/O
    // (e.g. using flutter_webrtc Helper)
    print('Native audio session activated! Enabling WebRTC audio playout & mic...');
    // await webrtcRoom.setMicrophoneEnabled(true);
  } else {
    print('Native audio session deactivated! Disabling WebRTC audio...');
    // await webrtcRoom.setMicrophoneEnabled(false);
  }
});
```

---

### 3. Handling Incoming & Outgoing Calls

```dart
// Report an incoming call (e.g., from an FCM data push or local trigger)
final session = await VoipCallEngine.instance.reportIncomingCall(
  const CallRequest(
    callId: '11111111-2222-4333-8444-555566667777',
    callerName: 'Dr. Emre Demir',
    handle: CallHandle(type: CallHandleType.phoneNumber, value: '+905321112233'),
    hasVideo: false,
    timeoutDuration: Duration(seconds: 45), // Automatic watchdog timer
  ),
);

// Answer the call (programmatically or from in-app UI)
await VoipCallEngine.instance.answerCall(session.callId);

// Once your WebRTC peer connection ICE/SDP completes, notify the engine:
await VoipCallEngine.instance.reportCallConnected(session.callId);
// -> The call now transitions to CallState.active once native audio is also verified!
```

---

### 4. Audio Routing (Earpiece, Speaker, Bluetooth)

Query and change the active audio endpoint:

```dart
// 1. Inspect current route and available endpoints
final routeState = await VoipCallEngine.instance.audio.getRouteState();
print('Current route: ${routeState.activeRoute}'); // e.g. AudioRoute.earpiece
print('Available routes: ${routeState.availableRoutes}'); // [earpiece, speaker, bluetooth]

// 2. Switch to Speakerphone
await VoipCallEngine.instance.audio.setRoute(AudioRoute.speaker);

// 3. Switch to Bluetooth Headset
await VoipCallEngine.instance.audio.setRoute(AudioRoute.bluetooth);

// 4. Switch back to built-in Earpiece (receiver)
await VoipCallEngine.instance.audio.setRoute(AudioRoute.earpiece);
```

---

### 5. Multi-Call Management (Hold, Swap & DTMF)

```dart
// Toggle Call Hold
await VoipCallEngine.instance.setHold(callId, isOnHold: true);

// Swap active and held calls (Call Waiting)
await VoipCallEngine.instance.swapCalls(
  activeCallId: callId1,
  heldCallId: callId2,
);

// Mute microphone
await VoipCallEngine.instance.setMuted(callId, isMuted: true);

// Send RFC 4733 sanitized DTMF tones (0-9, *, #, A-D)
await VoipCallEngine.instance.sendDtmf(callId, '1234#');

// End or reject the call
await VoipCallEngine.instance.endCall(callId, reason: CallEndReason.localHangup);
```

---

## 🛠️ Testing with the Go VoIP Test Harness (`tool/go_voip_harness`)

Included with this repository is a lightweight Go server that allows you to test all VoIP and audio routing edge cases locally without needing a second phone or a live backend:

```bash
# Navigate to the harness directory
cd tool/go_voip_harness

# Start the harness server (listens on http://127.0.0.1:8090)
go run ./cmd/server
```

### Supported Test Endpoints:
- `POST /api/calls/incoming` — Injects a simulated incoming call.
- `POST /api/calls/waiting` — Triggers a dual-call scenario to test Call Waiting and auto-hold.
- `POST /api/calls/ghost` — Simulates an early-cancel Ghost Call to verify suppression.
- `GET /api/audio/tone` — Streams a 440Hz PCM16 audio tone to verify audio output paths.
- `POST /api/audio/verify` — Analyzes loopback audio using the **Goertzel Algorithm** for frequency, clipping, and RMS dBFS integrity.

---

## 🧪 Comprehensive Quality & Test Suite

The engine is backed by a 7-tier test architecture:
- **10,000-Step Determinist Chaos & Fuzz Test**: Verifies all 5 telecom invariants under random combinations of multi-call, hold, network drops, and interruptions.
- **Enterprise Resilience Suite**: Tests out-of-order early-cancel tombstones, ringing watchdogs, and connection timeouts.
- **Defensive Deserialization**: Ensures corrupt or improperly typed payloads never crash the app.
- **Zero-Touch E2E Test**: Spawns the live Go test server as a sub-process and validates bidirectional WebSocket telemetry and Goertzel DSP acoustic verification.

To run tests locally:
```bash
# Dart & Flutter test suites
flutter test

# Go acoustic DSP & concurrent stress tests
cd tool/go_voip_harness && go test -v ./...
```

---

## 📄 License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
