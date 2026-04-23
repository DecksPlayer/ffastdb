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
      JsonEncoder(_toEncodable).fuse(const Utf8Encoder()); // ignore: prefer_const_constructors

  /// Walks a decoded JSON value and restores all sentinel-encoded types.
  static dynamic revive(dynamic v) {
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
      return v.map((k, val) => MapEntry(k as String, revive(val)));
    }
    if (v is List) return v.map(revive).toList();
    return v;
  }

  /// Serializes a Map to a JSON-UTF8 binary byte array.
  /// Includes a 2-byte magic prefix [0x00, 0x01] and a 4-byte length header.
  static Uint8List serialize(Map<String, dynamic> doc) {
    final utf8Data = _encoder.convert(doc);
    final data = Uint8List(2 + 4 + utf8Data.length);

    // Magic prefix
    data[0] = 0x00;
    data[1] = 0x01;

    final len = utf8Data.length;
    data[2] = len & 0xFF;
    data[3] = (len >> 8) & 0xFF;
    data[4] = (len >> 16) & 0xFF;
    data[5] = (len >> 24) & 0xFF;

    data.setRange(6, 6 + len, utf8Data);
    return data;
  }

  static Map<String, dynamic> deserialize(Uint8List data) {
    if (data.length < 6) throw ArgumentError('Data too short');

    if (data[0] != 0x00 || data[1] != 0x01) {
      throw ArgumentError('Invalid magic prefix');
    }

    final length = (data[2] & 0xFF) |
        ((data[3] & 0xFF) << 8) |
        ((data[4] & 0xFF) << 16) |
        ((data[5] & 0xFF) << 24);

    if (data.length < 6 + length) {
      throw ArgumentError(
          'Data is truncated: expected offset ${6 + length}, but got ${data.length}');
    }

    final jsonStr = utf8.decode(data.sublist(6, 6 + length));
    final raw = jsonDecode(jsonStr) as Map<String, dynamic>;
    return revive(raw) as Map<String, dynamic>;
  }
}

