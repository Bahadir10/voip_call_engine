/// Defensive type-coercion, UUID normalization, and RFC 4733 DTMF sanitization utilities
/// to protect the engine against malformed native or push payloads.
abstract final class CoercionUtils {
  static final RegExp _uuidRegex = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static final RegExp _validDtmfRegex = RegExp(r'[^0-9*#A-Da-d,]');

  /// Safely coerces dynamic map values (`bool`, `int`, `String`) into a [bool].
  static bool asBool(Object? value, {bool fallback = false}) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final lower = value.trim().toLowerCase();
      if (lower == 'true' || lower == '1' || lower == 'yes') return true;
      if (lower == 'false' || lower == '0' || lower == 'no') return false;
    }
    return fallback;
  }

  /// Safely coerces dynamic map values (`int`, `double`, `String`) into an [int].
  static int asInt(Object? value, {int fallback = 0, int? min, int? max}) {
    int? parsed;
    if (value is int) {
      parsed = value;
    } else if (value is num) {
      parsed = value.toInt();
    } else if (value is String) {
      parsed = int.tryParse(value.trim()) ?? double.tryParse(value.trim())?.toInt();
    }
    var result = parsed ?? fallback;
    if (min != null && result < min) result = min;
    if (max != null && result > max) result = max;
    return result;
  }

  /// Safely coerces dynamic map values into a non-null [String].
  static String asString(Object? value, {String fallback = ''}) {
    if (value == null) return fallback;
    if (value is String) return value.isEmpty ? fallback : value;
    final str = value.toString();
    return str.isEmpty ? fallback : str;
  }

  /// Safely coerces dynamic map values into a nullable [String].
  static String? asNullableString(Object? value) {
    if (value == null) return null;
    if (value is String) return value;
    return value.toString();
  }

  /// Safely extracts a nested `Map<Object?, Object?>`.
  static Map<Object?, Object?> asObjectMap(Object? value) {
    if (value is Map<Object?, Object?>) return value;
    return const <Object?, Object?>{};
  }

  /// Safely extracts a `Map<String, String>` from any dynamic map.
  static Map<String, String> asStringMap(Object? value) {
    if (value is Map) {
      final result = <String, String>{};
      value.forEach((Object? k, Object? v) {
        if (k != null && v != null) {
          result[k.toString()] = v.toString();
        }
      });
      return result;
    }
    return const <String, String>{};
  }

  /// Validates Whether [input] is a canonical UUID string.
  static bool isValidUuid(String input) => _uuidRegex.hasMatch(input.trim());

  /// Sanitizes a DTMF string according to RFC 4733 (`0-9`, `*`, `#`, `A-D`, `,`).
  static String sanitizeDtmfDigits(String raw) {
    return raw.toUpperCase().replaceAll(_validDtmfRegex, '');
  }
}
