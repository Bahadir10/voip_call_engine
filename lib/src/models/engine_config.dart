import 'package:meta/meta.dart';

/// iOS-specific configuration for `PKPushRegistry`, `CXProviderConfiguration`, and `AVAudioSession`.
@immutable
class IosCallConfig {
  /// Creates an [IosCallConfig] specifying native CallKit and PushKit parameters.
  const IosCallConfig({
    required this.appName,
    this.iconTemplateImageName,
    this.ringtoneSound,
    this.supportsVideo = true,
    this.maximumCallGroups = 2,
    this.maximumCallsPerCallGroup = 1,
    this.includesCallsInRecents = false,
    this.enablePushKit = true,
    this.useManualWebRtcAudioBarrier = true,
  });

  /// Name of the app displayed in the iOS CallKit lock screen and in-call UI.
  final String appName;

  /// Name of the template icon image in Xcode Assets catalog used as CallKit avatar.
  final String? iconTemplateImageName;

  /// Custom ringtone audio file bundled in the main iOS app bundle (e.g. `ring.caf`).
  final String? ringtoneSound;

  /// Whether CallKit displays the native video call button.
  final bool supportsVideo;

  /// Maximum number of call groups permitted by CallKit (default: `2`).
  final int maximumCallGroups;

  /// Maximum number of calls in each group (default: `1`).
  final int maximumCallsPerCallGroup;

  /// Whether finished calls should be recorded in the iOS Phone app Recents history.
  final bool includesCallsInRecents;

  /// Automatically registers `PKPushRegistry` with `.voIP` push type on startup.
  final bool enablePushKit;

  /// Coordinates `provider(_:didActivate:)` with WebRTC manual audio mode to prevent silent calls.
  final bool useManualWebRtcAudioBarrier;

  /// Serializes the iOS configuration to a dictionary for platform channel transport.
  Map<String, Object?> toMap() => <String, Object?>{
        'appName': appName,
        'iconTemplateImageName': iconTemplateImageName,
        'ringtoneSound': ringtoneSound,
        'supportsVideo': supportsVideo,
        'maximumCallGroups': maximumCallGroups,
        'maximumCallsPerCallGroup': maximumCallsPerCallGroup,
        'includesCallsInRecents': includesCallsInRecents,
        'enablePushKit': enablePushKit,
        'useManualWebRtcAudioBarrier': useManualWebRtcAudioBarrier,
      };
}

/// Android-specific configuration for `ConnectionService`, `Core-Telecom`, and `ForegroundService`.
@immutable
class AndroidCallConfig {
  /// Creates an [AndroidCallConfig] specifying Android Telecom parameters.
  const AndroidCallConfig({
    this.phoneAccountLabel = 'VoIP Call Service',
    this.notificationChannelId = 'voip_call_engine_channel',
    this.notificationChannelName = 'Incoming & Active Calls',
    this.preferJetpackCoreTelecom = true,
    this.enableFullScreenIntentFallback = true,
    this.autoHoldOnGsmInterruption = true,
  });

  /// Label for the self-managed Telecom PhoneAccount registered in Android `TelecomManager`.
  final String phoneAccountLabel;

  /// Notification channel ID used for active and incoming call foreground services.
  final String notificationChannelId;

  /// Human-readable notification channel name displayed in Android System Settings.
  final String notificationChannelName;

  /// Prefers Android 14+ Jetpack Core-Telecom API when available, falling back to `ConnectionService`.
  final bool preferJetpackCoreTelecom;

  /// Enables full-screen incoming call activity when heads-up notification is not tapped.
  final bool enableFullScreenIntentFallback;

  /// Automatically places VoIP call on hold when an incoming cellular GSM call interrupts.
  final bool autoHoldOnGsmInterruption;

  /// Serializes the Android configuration to a dictionary for platform channel transport.
  Map<String, Object?> toMap() => <String, Object?>{
        'phoneAccountLabel': phoneAccountLabel,
        'notificationChannelId': notificationChannelId,
        'notificationChannelName': notificationChannelName,
        'preferJetpackCoreTelecom': preferJetpackCoreTelecom,
        'enableFullScreenIntentFallback': enableFullScreenIntentFallback,
        'autoHoldOnGsmInterruption': autoHoldOnGsmInterruption,
      };
}

/// Desktop-specific (Windows & macOS) configuration.
@immutable
class DesktopCallConfig {
  /// Creates a [DesktopCallConfig] for Windows and macOS platforms.
  const DesktopCallConfig({
    this.appName = 'VoIP Call Engine',
    this.enableSystemCallNotifications = true,
    this.autoSelectCommunicationAudioDevice = true,
  });

  /// Application name displayed in Windows Toast / macOS notifications.
  final String appName;

  /// Whether system notifications/toasts are triggered on incoming calls.
  final bool enableSystemCallNotifications;

  /// Automatically selects default communication endpoint in WASAPI / CoreAudio.
  final bool autoSelectCommunicationAudioDevice;

  /// Serializes the desktop configuration to a dictionary for platform channel transport.
  Map<String, Object?> toMap() => <String, Object?>{
        'appName': appName,
        'enableSystemCallNotifications': enableSystemCallNotifications,
        'autoSelectCommunicationAudioDevice':
            autoSelectCommunicationAudioDevice,
      };
}

/// Web-specific configuration (`MediaSession`, `Notifications`, `setSinkId`).
@immutable
class WebCallConfig {
  /// Creates a [WebCallConfig] for browser execution environments.
  const WebCallConfig({
    this.appName = 'VoIP Call Engine',
    this.enableWebNotifications = true,
    this.enableMediaSessionHardwareKeys = true,
  });

  /// Application name displayed in browser notifications and MediaSession metadata.
  final String appName;

  /// Whether Web Notification API is used for incoming call alerts.
  final bool enableWebNotifications;

  /// Registers MediaSession action handlers (call, hangup, microphone mute).
  final bool enableMediaSessionHardwareKeys;

  /// Serializes the Web configuration to a dictionary for platform channel transport.
  Map<String, Object?> toMap() => <String, Object?>{
        'appName': appName,
        'enableWebNotifications': enableWebNotifications,
        'enableMediaSessionHardwareKeys': enableMediaSessionHardwareKeys,
      };
}

/// Top-level initialization configuration for `VoipCallEngine`.
@immutable
class VoipEngineConfig {
  /// Creates a unified [VoipEngineConfig] applied during engine initialization.
  const VoipEngineConfig({
    this.ios = const IosCallConfig(appName: 'VoIP App'),
    this.android = const AndroidCallConfig(),
    this.desktop = const DesktopCallConfig(),
    this.web = const WebCallConfig(),
    this.maxConcurrentCalls = 2,
  });

  /// iOS CallKit and PushKit configuration.
  final IosCallConfig ios;

  /// Android Telecom and ConnectionService configuration.
  final AndroidCallConfig android;

  /// Windows and macOS configuration.
  final DesktopCallConfig desktop;

  /// Web browser configuration.
  final WebCallConfig web;

  /// Maximum number of concurrent calls managed by the state machine (default: `2`).
  final int maxConcurrentCalls;

  /// Serializes the configuration to a dictionary for platform channel transport.
  Map<String, Object?> toMap() => <String, Object?>{
        'ios': ios.toMap(),
        'android': android.toMap(),
        'desktop': desktop.toMap(),
        'web': web.toMap(),
        'maxConcurrentCalls': maxConcurrentCalls,
      };
}
