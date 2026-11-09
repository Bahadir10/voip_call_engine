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
