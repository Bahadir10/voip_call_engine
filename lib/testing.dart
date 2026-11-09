/// Test harness bridge utilities for end-to-end integration testing of [VoipCallEngine].
///
/// Connects Flutter's client-side engine with the lightweight Go backend harness
/// (`tool/go_voip_harness`) to verify bidirectional signaling and acoustic DSP.
library;

export 'src/harness/voip_harness_bridge.dart';
