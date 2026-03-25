import 'dart:convert';
import 'dart:typed_data';

/// Handles fast binary serialization for documents.
///
/// Supports native Dart types plus Firebase Firestore types via duck-typing
/// (no `cloud_firestore` import required):
///   - `Timestamp`        → stored as DateTime ISO-8601
///   - `GeoPoint`         → stored as `{latitude, longitude}` map
///   - `DocumentReference`→ stored as its path string
///   - `Blob`             → stored as Base64 string, revived as `Uint8List`
///   - `Uint8List`        → stored as Base64 string, revived as `Uint8List`
class FastSerializer {
  // Sentinel prefixes — \u0000 can't appear in normal user strings.
  static const _dtPrefix = '\u0000dt:'; // DateTime / Timestamp
  static const _gpPrefix = '\u0000gp:'; // GeoPoint  → "lat,lng"
  static const _drPrefix = '\u0000dr:'; // DocumentReference → path
  static const _blPrefix = '\u0000bl:'; // Blob / Uint8List  → base64

  static Object? _toEncodable(Object? value) {
    // ── Dart native ──────────────────────────────────────────────────────────
    if (value is DateTime) {
      return '$_dtPrefix${value.toUtc().toIso8601String()}';
    }
    if (value is Uint8List) {
      return '$_blPrefix${base64Encode(value)}';
    }

    // ── Firebase: Timestamp (has .toDate() → DateTime) ───────────────────────
    try {
      final dt = (value as dynamic).toDate() as DateTime;
      return '$_dtPrefix${dt.toUtc().toIso8601String()}';
    } catch (_) {}

    // ── Firebase: GeoPoint (has .latitude & .longitude) ──────────────────────
    try {
      final lat = ((value as dynamic).latitude as num).toDouble();
      final lng = ((value as dynamic).longitude as num).toDouble();
      return '$_gpPrefix$lat,$lng';
    } catch (_) {}

    // ── Firebase: DocumentReference (has .path → String) ─────────────────────
    try {
      final path = (value as dynamic).path as String;
      return '$_drPrefix$path';
    } catch (_) {}

    // ── Firebase: Blob (has .bytes → Uint8List) ───────────────────────────────
    try {
      final bytes = (value as dynamic).bytes as Uint8List;
      return '$_blPrefix${base64Encode(bytes)}';
    } catch (_) {}

    // ── Last resort: stringify so the document never crashes ──────────────────
    return value.toString();
  }

  // JsonEncoder must NOT be const when a toEncodable function is provided.
  static final _encoder =
      JsonEncoder(_toEncodable).fuse(const Utf8Encoder());

  /// Walks a decoded JSON value and restores all sentinel-encoded types.
  static dynamic _revive(dynamic v) {
    if (v is String) {
      if (v.startsWith(_dtPrefix)) {
        return DateTime.parse(v.substring(_dtPrefix.length));
      }
      if (v.startsWith(_gpPrefix)) {
        final parts = v.substring(_gpPrefix.length).split(',');
        return {
          'latitude': double.parse(parts[0]),
          'longitude': double.parse(parts[1]),
        };
      }
      if (v.startsWith(_drPrefix)) {
        // Return the path string — callers can rebuild DocumentReference if needed.
        return v.substring(_drPrefix.length);
      }
      if (v.startsWith(_blPrefix)) {
        return base64Decode(v.substring(_blPrefix.length));
      }
    }
    if (v is Map) {
      return v.map((k, val) => MapEntry(k as String, _revive(val)));
    }
    if (v is List) return v.map(_revive).toList();
    return v;
  }

  /// Serializes a Map to a JSON-UTF8 binary byte array.
  /// Includes a 4-byte little-endian length header.
  static Uint8List serialize(Map<String, dynamic> doc) {
    final utf8Data = _encoder.convert(doc);
    final data = Uint8List(4 + utf8Data.length);

    data[0] = utf8Data.length & 0xFF;
    data[1] = (utf8Data.length >> 8) & 0xFF;
    data[2] = (utf8Data.length >> 16) & 0xFF;
    data[3] = (utf8Data.length >> 24) & 0xFF;

    data.setRange(4, 4 + utf8Data.length, utf8Data);
    return data;
  }

  static Map<String, dynamic> deserialize(Uint8List data) {
    if (data.length < 4) throw ArgumentError('Data too short');

    final length = (data[0] & 0xFF) |
        ((data[1] & 0xFF) << 8) |
        ((data[2] & 0xFF) << 16) |
        ((data[3] & 0xFF) << 24);

    if (data.length < 4 + length) {
      throw ArgumentError(
          'Data is truncated: expected offset ${4 + length}, but got ${data.length}');
    }

    final jsonStr = utf8.decode(data.sublist(4, 4 + length));
    final raw = jsonDecode(jsonStr) as Map<String, dynamic>;
    return _revive(raw) as Map<String, dynamic>;
  }
}

