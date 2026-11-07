## 0.1.0

* Initial release of `voip_call_engine`.
* Federated architecture supporting iOS (`PushKit` + `CallKit` + `AVAudioSession`), Android (`ConnectionService` + `AudioManager`), Windows (`WASAPI`), macOS (`CallKit` + `CoreAudio`), and Web.
* Deterministic `CallStateMachine` with 5 invariant checks, Out-of-Order Tombstone cache, Watchdog timers, and `VoipHarnessBridge` E2E test runner.
