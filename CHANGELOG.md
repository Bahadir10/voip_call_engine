## 0.1.2

* **100% Comprehensive API Dartdoc Coverage**:
  * Added detailed dartdoc comments to every single public class, constructor, parameter, property, method, and enum value across all library modules.
  * Added library-level documentation for `package:voip_call_engine` with architectural guidelines.
* **WASM & Web Architecture Isolation**:
  * Moved the Go harness bridge to a dedicated test module (`package:voip_call_engine/testing.dart`), decoupling `dart:io` from the root entrypoint and enabling full WebAssembly (WASM) compatibility.
* **Deterministic E2E Test Hardening**:
  * Hardened asynchronous WebSocket state-transition assertions in `fe_be_zero_touch_e2e_test.dart`.

## 0.1.1

* **Comprehensive Documentation & Setup Guides**:
  * Added detailed iOS setup guide (`Info.plist`, VoIP & Audio Background Modes, PushKit payload formatting).
  * Added detailed Android setup guide (Permissions, Android 14+ foreground service types, self-managed Telecom).
  * Added end-to-end WebRTC synchronization code sample with `registerWebRtcHook`.
  * Added state machine transition diagrams and audio routing examples across 5 platforms.
  * Added documentation for local testing with the Go VoIP Test Harness (`tool/go_voip_harness`).
* **API Documentation**:
  * Fixed unresolved dartdoc references for 100% clean API reference generation on pub.dev.

## 0.1.0

* Initial release of `voip_call_engine`.
* Federated architecture supporting iOS (`PushKit` + `CallKit` + `AVAudioSession`), Android (`ConnectionService` + `AudioManager`), Windows (`WASAPI`), macOS (`CallKit` + `CoreAudio`), and Web.
* Deterministic `CallStateMachine` with 5 invariant checks, Out-of-Order Tombstone cache, Watchdog timers, and `VoipHarnessBridge` E2E test runner.
