import 'package:meta/meta.dart';

import '../utils/coercion_utils.dart';

/// Standardized audio routing endpoints across iOS, Android, Windows, macOS, and Web.
enum AudioRoute {
  /// Built-in receiver earpiece (iOS `.builtInReceiver`, Android `TYPE_BUILTIN_EARPIECE`).
  earpiece,

  /// Built-in speakerphone (iOS `.builtInSpeaker`, Android `TYPE_BUILTIN_SPEAKER`).
  speaker,

  /// Bluetooth Hands-Free Profile / SCO / BLE Audio headset.
  bluetooth,

  /// Wired 3.5mm or USB-C/Lightning headset.
  wiredHeadset,

  /// CarPlay or Android Auto audio system.
  carAudio,

  /// Default system output (commonly used on Desktop/Web when specific type is generic).
  systemDefault,
}

/// Represents a specific physical or virtual audio endpoint discovered on the host OS.
@immutable
class AudioDevice {
  /// Creates an [AudioDevice] representing an audio input or output endpoint.
  const AudioDevice({
    required this.id,
    required this.name,
    required this.route,
    this.isDefault = false,
    this.isInput = false,
  });

  /// Deserializes an [AudioDevice] from a platform channel map.
  factory AudioDevice.fromMap(Map<Object?, Object?> map) {
    final routeName =
        CoercionUtils.asString(map['route'], fallback: 'systemDefault');
    return AudioDevice(
      id: CoercionUtils.asString(map['id'], fallback: 'default'),
      name: CoercionUtils.asString(
        map['name'],
        fallback: 'Default Audio Device',
      ),
      route: AudioRoute.values.firstWhere(
        (e) => e.name == routeName,
        orElse: () => AudioRoute.systemDefault,
      ),
      isDefault: CoercionUtils.asBool(map['isDefault']),
      isInput: CoercionUtils.asBool(map['isInput']),
    );
  }

  /// Unique platform identifier for the physical or virtual device.
  final String id;

  /// User-friendly device name (e.g., `"AirPods Pro"`, `"Built-in Speaker"`).
  final String name;

  /// Standard category classification of the endpoint.
  final AudioRoute route;

  /// Whether this is the operating system's default communication device.
  final bool isDefault;

  /// Whether this endpoint functions as an audio input (microphone).
  final bool isInput;

  /// Serializes the audio device to a transport map.
  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'name': name,
        'route': route.name,
        'isDefault': isDefault,
        'isInput': isInput,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioDevice &&
          other.id == id &&
          other.name == name &&
          other.route == route &&
          other.isInput == isInput;

  @override
  int get hashCode => Object.hash(id, name, route, isInput);

  @override
  String toString() => 'AudioDevice($name [${route.name}], id: $id)';
}

/// Snapshot of the current audio routing state.
@immutable
class AudioRouteState {
  /// Creates an [AudioRouteState] snapshot.
  const AudioRouteState({
    required this.activeRoute,
    required this.availableRoutes,
    this.activeDevice,
    this.availableDevices = const <AudioDevice>[],
    this.isAudioSessionActive = false,
    this.isMicrophoneMuted = false,
  });

  /// Deserializes an [AudioRouteState] from a platform channel map.
  factory AudioRouteState.fromMap(Map<Object?, Object?> map) {
    final activeRouteName =
        CoercionUtils.asString(map['activeRoute'], fallback: 'earpiece');
    final rawRoutes = map['availableRoutes'] is List
        ? (map['availableRoutes'] as List<Object?>)
        : const <Object?>[];
    final rawDevices = map['availableDevices'] is List
        ? (map['availableDevices'] as List<Object?>)
        : const <Object?>[];
    final rawActiveDevice = map['activeDevice'] is Map<Object?, Object?>
        ? (map['activeDevice'] as Map<Object?, Object?>)
        : null;

    return AudioRouteState(
      activeRoute: AudioRoute.values.firstWhere(
        (e) => e.name == activeRouteName,
        orElse: () => AudioRoute.earpiece,
      ),
      availableRoutes: rawRoutes
          .map(
            (r) => AudioRoute.values.firstWhere(
              (e) => e.name == r?.toString(),
              orElse: () => AudioRoute.systemDefault,
            ),
          )
          .toList(growable: false),
      activeDevice:
          rawActiveDevice != null ? AudioDevice.fromMap(rawActiveDevice) : null,
      availableDevices: rawDevices
          .whereType<Map<Object?, Object?>>()
          .map(AudioDevice.fromMap)
          .toList(growable: false),
      isAudioSessionActive: CoercionUtils.asBool(map['isAudioSessionActive']),
      isMicrophoneMuted: CoercionUtils.asBool(map['isMicrophoneMuted']),
    );
  }

  /// The currently active general audio route.
  final AudioRoute activeRoute;

  /// All selectable general audio route categories on the current platform.
  final List<AudioRoute> availableRoutes;

  /// The specific hardware audio device currently routing audio, if known.
  final AudioDevice? activeDevice;

  /// All physical and virtual audio devices detected by the host system.
  final List<AudioDevice> availableDevices;

  /// Whether the native telecom voice session (`AVAudioSession` / `AudioManager`) is active.
  final bool isAudioSessionActive;

  /// Whether the system microphone is currently muted.
  final bool isMicrophoneMuted;

  /// Serializes the audio route state into a transport map.
  Map<String, Object?> toMap() => <String, Object?>{
        'activeRoute': activeRoute.name,
        'availableRoutes': availableRoutes.map((e) => e.name).toList(),
        'activeDevice': activeDevice?.toMap(),
        'availableDevices': availableDevices.map((e) => e.toMap()).toList(),
        'isAudioSessionActive': isAudioSessionActive,
        'isMicrophoneMuted': isMicrophoneMuted,
      };
}
