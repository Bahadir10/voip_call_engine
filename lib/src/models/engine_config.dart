import 'package:meta/meta.dart';

/// iOS-specific configuration for `PKPushRegistry`, `CXProviderConfiguration`, and `AVAudioSession`.
@immutable
class IosCallConfig {
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

  final String appName;
  final String? iconTemplateImageName;
  final String? ringtoneSound;
  final bool supportsVideo;
  final int maximumCallGroups;
  final int maximumCallsPerCallGroup;
  final bool includesCallsInRecents;

  /// Automatically registers `PKPushRegistry` with `.voIP` push type on startup.
  final bool enablePushKit;

  /// Coordinates `provider(_:didActivate:)` with WebRTC manual audio mode to prevent silent calls.
  final bool useManualWebRtcAudioBarrier;

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
  const AndroidCallConfig({
    this.phoneAccountLabel = 'VoIP Call Service',
    this.notificationChannelId = 'voip_call_engine_channel',
    this.notificationChannelName = 'Incoming & Active Calls',
    this.preferJetpackCoreTelecom = true,
    this.enableFullScreenIntentFallback = true,
    this.autoHoldOnGsmInterruption = true,
  });

  final String phoneAccountLabel;
  final String notificationChannelId;
  final String notificationChannelName;
  final bool preferJetpackCoreTelecom;
  final bool enableFullScreenIntentFallback;
  final bool autoHoldOnGsmInterruption;

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
  const DesktopCallConfig({
    this.appName = 'VoIP Call Engine',
    this.enableSystemCallNotifications = true,
    this.autoSelectCommunicationAudioDevice = true,
  });

  final String appName;
  final bool enableSystemCallNotifications;
  final bool autoSelectCommunicationAudioDevice;

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
  const WebCallConfig({
    this.appName = 'VoIP Call Engine',
    this.enableWebNotifications = true,
    this.enableMediaSessionHardwareKeys = true,
  });

  final String appName;
  final bool enableWebNotifications;
  final bool enableMediaSessionHardwareKeys;

  Map<String, Object?> toMap() => <String, Object?>{
        'appName': appName,
        'enableWebNotifications': enableWebNotifications,
        'enableMediaSessionHardwareKeys': enableMediaSessionHardwareKeys,
      };
}

/// Top-level initialization configuration for `VoipCallEngine`.
@immutable
class VoipEngineConfig {
  const VoipEngineConfig({
    this.ios = const IosCallConfig(appName: 'VoIP App'),
    this.android = const AndroidCallConfig(),
    this.desktop = const DesktopCallConfig(),
    this.web = const WebCallConfig(),
    this.maxConcurrentCalls = 2,
  });

  final IosCallConfig ios;
  final AndroidCallConfig android;
  final DesktopCallConfig desktop;
  final WebCallConfig web;
  final int maxConcurrentCalls;

  Map<String, Object?> toMap() => <String, Object?>{
        'ios': ios.toMap(),
        'android': android.toMap(),
        'desktop': desktop.toMap(),
        'web': web.toMap(),
        'maxConcurrentCalls': maxConcurrentCalls,
      };
}
