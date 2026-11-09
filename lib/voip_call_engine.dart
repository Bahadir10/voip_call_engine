/// Production-grade, deterministic VoIP call lifecycle, CallKit, ConnectionService,
/// and multi-platform audio routing engine for Flutter.
///
/// Designed to eliminate PushKit terminations (`0xbaadca11`), ghost calls, cold-start
/// lost events, and silent WebRTC audio race conditions.
///
/// Supported platforms:
/// - iOS (CallKit + PushKit + AVAudioSession)
/// - Android (Self-Managed ConnectionService / Jetpack Core-Telecom + AudioManager)
/// - Windows (WASAPI Communication Device + Toast Notifications)
/// - macOS (CoreAudio + UserNotifications)
/// - Web (Web Audio Sink + MediaSession + Web Notifications)
///
/// For end-to-end integration testing and Go harness bridge utilities,
/// import `package:voip_call_engine/testing.dart`.
library;

export 'src/models/audio_models.dart';
export 'src/models/call_events.dart';
export 'src/models/call_models.dart';
export 'src/models/engine_config.dart';
export 'src/platform_interface/method_channel_voip_call_engine.dart';
export 'src/platform_interface/voip_call_engine_platform.dart';
export 'src/state_machine/call_state_machine.dart';
export 'src/utils/coercion_utils.dart';
export 'src/voip_call_engine_client.dart';
