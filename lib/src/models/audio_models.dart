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
  const AudioDevice({
    required this.id,
    required this.name,
    required this.route,
    this.isDefault = false,
    this.isInput = false,
  });

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

  final String id;
  final String name;
  final AudioRoute route;
  final bool isDefault;
  final bool isInput;

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
  const AudioRouteState({
    required this.activeRoute,
    required this.availableRoutes,
    this.activeDevice,
    this.availableDevices = const <AudioDevice>[],
    this.isAudioSessionActive = false,
    this.isMicrophoneMuted = false,
  });

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

  final AudioRoute activeRoute;
  final List<AudioRoute> availableRoutes;
  final AudioDevice? activeDevice;
  final List<AudioDevice> availableDevices;
  final bool isAudioSessionActive;
  final bool isMicrophoneMuted;

  Map<String, Object?> toMap() => <String, Object?>{
        'activeRoute': activeRoute.name,
        'availableRoutes': availableRoutes.map((e) => e.name).toList(),
        'activeDevice': activeDevice?.toMap(),
        'availableDevices': availableDevices.map((e) => e.toMap()).toList(),
        'isAudioSessionActive': isAudioSessionActive,
        'isMicrophoneMuted': isMicrophoneMuted,
      };
}
