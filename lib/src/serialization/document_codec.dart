import 'dart:convert';
import 'dart:typed_data';

import 'fast_serializer.dart';

/// Binary encoding of Map documents (record format v2, magic `0x00 0x02`).
///
/// Replaces JSON ([FastSerializer], magic `0x00 0x01`) as the on-disk format:
/// no intermediate JSON string, no pre-encode/revive tree copies, and native
/// DateTime / Uint8List / NaN support without sentinel strings. Records
/// written in the JSON format remain readable — see [decodeDocumentPayload].
/// JSON interoperability lives at the API boundary (`FastDB.exportJson`).
///
/// Value encoding (all multi-byte numbers little-endian):
///   0 null | 1 false | 2 true
///   3 int8 | 4 int32 | 5 int64 as (uint32 lo, int32 hi) — dart2js has no
///   ByteData.setInt64 | 6 float64
///   7 string (varint byteLength, UTF-8) | 8 list (varint count, values)
///   9 map (varint count, (varint keyLength, UTF-8 key, value)*)
///   10 DateTime (int64 UTC microseconds, as tag 5) | 11 bytes (varint length)
///
/// Values the JSON format could not represent keep its fallbacks: Firebase
/// types are duck-typed (Timestamp → DateTime, GeoPoint → {latitude,
/// longitude}, DocumentReference → path, Blob → bytes) and any other object
/// is stored as its `toString()`. Nested map keys are stored as strings.
class DocumentCodec {
  static const int magic0 = 0x00;
  static const int magic1 = 0x02;

  static const int _tNull = 0;
  static const int _tFalse = 1;
  static const int _tTrue = 2;
  static const int _tInt8 = 3;
  static const int _tInt32 = 4;
  static const int _tInt64 = 5;
  static const int _tFloat64 = 6;
  static const int _tString = 7;
  static const int _tList = 8;
  static const int _tMap = 9;
  static const int _tDateTime = 10;
  static const int _tBytes = 11;

  static const _utf8Decoder = Utf8Decoder();

  /// Encodes [doc] as a complete storage record:
  /// `[4-byte payload length][payload][4-byte CRC32 placeholder]`.
  ///
  /// The payload starts with the magic prefix. When [id] is given it is
  /// stored as the `ffdbID` field (replacing any existing one) without
  /// copying [doc]. The caller fills in the CRC (it owns the CRC routine).
  /// Root keys must be Strings.
  static Uint8List encodeRecord(Map doc, {int? id}) {
    final w = _Writer(256);
    w.skip(4); // payload length, patched below
    w.byte(magic0);
    w.byte(magic1);
    w.byte(_tMap);
    final replaceId = id != null;
    final count = replaceId && !doc.containsKey('ffdbID') ? doc.length + 1 : doc.length;
    w.varint(count);
    for (final entry in doc.entries) {
      final key = entry.key;
      if (key is! String) {
        throw ArgumentError.value(key, 'doc', 'Document keys must be Strings');
      }
      if (replaceId && key == 'ffdbID') continue;
      w.string(key);
      w.value(entry.value);
    }
    if (replaceId) {
      w.string('ffdbID');
      w.value(id);
    }
    w.skip(4); // CRC32, filled by the caller
    final out = w.takeBytes();
    final payloadLength = out.length - 8;
    out[0] = payloadLength & 0xFF;
    out[1] = (payloadLength >> 8) & 0xFF;
    out[2] = (payloadLength >> 16) & 0xFF;
    out[3] = (payloadLength >> 24) & 0xFF;
    return out;
  }

  /// Decodes a v2 payload (starting with the magic prefix).
  static Map<String, dynamic> decode(Uint8List payload) {
    if (payload.length < 3 || payload[0] != magic0 || payload[1] != magic1) {
      throw ArgumentError('Invalid document magic prefix');
    }
    final r = _Reader(payload, 2);
    final root = r.value();
    if (root is! Map<String, dynamic>) {
      throw const FormatException('Document root is not a map');
    }
    return root;
  }

  /// True if [payload] carries the v2 magic prefix.
  static bool isBinary(Uint8List payload) =>
      payload.length >= 2 && payload[0] == magic0 && payload[1] == magic1;
}

/// Decodes a Map document payload in either record format — v2 binary
/// ([DocumentCodec]) or legacy JSON ([FastSerializer], magic `0x00 0x01`).
/// Returns null for anything else (e.g. TypeAdapter payloads).
Map<String, dynamic>? decodeDocumentPayload(Uint8List payload) {
  if (payload.length < 2 || payload[0] != 0x00) return null;
  if (payload[1] == DocumentCodec.magic1) return DocumentCodec.decode(payload);
  if (payload[1] == 0x01) return FastSerializer.deserialize(payload);
  return null;
}

/// True when compiled to JavaScript (int and double share a representation).
const bool _isWeb = identical(0, 0.0);

/// 2^53 - 1, the largest integer a JS number holds exactly.
const int _maxSafe = 9007199254740991;

class _Writer {
  Uint8List _buf;
  late ByteData _bd;
  int _pos = 0;

  _Writer(int initialCapacity) : _buf = Uint8List(initialCapacity) {
    _bd = ByteData.sublistView(_buf);
  }

  void _ensure(int extra) {
    final needed = _pos + extra;
    if (needed <= _buf.length) return;
    var cap = _buf.length * 2;
    while (cap < needed) {
      cap *= 2;
    }
    final next = Uint8List(cap)..setRange(0, _pos, _buf);
    _buf = next;
    _bd = ByteData.sublistView(_buf);
  }

  Uint8List takeBytes() => Uint8List.sublistView(_buf, 0, _pos);

  void skip(int n) {
    _ensure(n);
    _pos += n;
  }

  void byte(int b) {
    _ensure(1);
    _buf[_pos++] = b;
  }

  /// Unsigned LEB128 for non-negative values < 2^31 (lengths and counts —
  /// 32-bit shifts are exact on the web too).
  void varint(int v) {
    _ensure(5);
    while (v >= 0x80) {
      _buf[_pos++] = (v & 0x7F) | 0x80;
      v >>= 7;
    }
    _buf[_pos++] = v;
  }

  void string(String s) {
    final n = s.length;
    // ASCII fast path: byte length == code unit count, copy directly.
    final start = _pos;
    varint(n);
    _ensure(n);
    for (int i = 0; i < n; i++) {
      final c = s.codeUnitAt(i);
      if (c >= 0x80) {
        _pos = start; // not ASCII — rewind and encode properly
        final bytes = utf8.encode(s);
        varint(bytes.length);
        _ensure(bytes.length);
        _buf.setRange(_pos, _pos + bytes.length, bytes);
        _pos += bytes.length;
        return;
      }
      _buf[_pos++] = c;
    }
  }

  void int64(int v) {
    _ensure(8);
    // Web-safe split: `&` yields the unsigned low 32 bits on every platform;
    // (v - lo) is an exact multiple of 2^32, so ~/ is exact as well.
    final lo = v & 0xFFFFFFFF;
    final hi = (v - lo) ~/ 0x100000000;
    _bd.setUint32(_pos, lo, Endian.little);
    _bd.setInt32(_pos + 4, hi, Endian.little);
    _pos += 8;
  }

  void value(dynamic v) {
    if (v == null) {
      byte(DocumentCodec._tNull);
    } else if (v is String) {
      byte(DocumentCodec._tString);
      string(v);
    } else if (v is bool) {
      byte(v ? DocumentCodec._tTrue : DocumentCodec._tFalse);
    } else if (v is num) {
      // `is int` first: on the web every number is also a `double`. There,
      // NaN/±Infinity and any integral double (e.g. 1e300) also pass `is int`
      // — only safe integers take the int path; the rest stay float64, which
      // preserves the JS value exactly.
      if (v is int && v.isFinite && (!_isWeb || (v <= _maxSafe && v >= -_maxSafe))) {
        if (v >= -128 && v <= 127) {
          byte(DocumentCodec._tInt8);
          byte(v & 0xFF);
        } else if (v >= -0x80000000 && v <= 0x7FFFFFFF) {
          byte(DocumentCodec._tInt32);
          _ensure(4);
          _bd.setInt32(_pos, v, Endian.little);
          _pos += 4;
        } else {
          byte(DocumentCodec._tInt64);
          int64(v);
        }
      } else {
        byte(DocumentCodec._tFloat64);
        _ensure(8);
        _bd.setFloat64(_pos, v.toDouble(), Endian.little);
        _pos += 8;
      }
    } else if (v is Map) {
      byte(DocumentCodec._tMap);
      varint(v.length);
      for (final entry in v.entries) {
        final key = entry.key;
        string(key is String ? key : key.toString());
        value(entry.value);
      }
    } else if (v is Uint8List) {
      byte(DocumentCodec._tBytes);
      varint(v.length);
      _ensure(v.length);
      _buf.setRange(_pos, _pos + v.length, v);
      _pos += v.length;
    } else if (v is List) {
      byte(DocumentCodec._tList);
      varint(v.length);
      for (final item in v) {
        value(item);
      }
    } else if (v is DateTime) {
      byte(DocumentCodec._tDateTime);
      int64(v.microsecondsSinceEpoch);
    } else {
      _special(v);
    }
  }

  /// Firebase duck-typing (no cloud_firestore import) and the toString()
  /// fallback — same rules as the JSON format. Type names are checked first
  /// to avoid try/catch on ordinary objects.
  void _special(Object v) {
    final type = v.runtimeType.toString();
    try {
      if (type.endsWith('Timestamp')) {
        return value((v as dynamic).toDate() as DateTime);
      } else if (type.endsWith('GeoPoint')) {
        return value(<String, dynamic>{
          'latitude': ((v as dynamic).latitude as num).toDouble(),
          'longitude': ((v as dynamic).longitude as num).toDouble(),
        });
      } else if (type.endsWith('DocumentReference')) {
        return value((v as dynamic).path as String);
      } else if (type.endsWith('Blob')) {
        return value((v as dynamic).bytes as Uint8List);
      }
    } catch (_) {}
    value(v.toString());
  }
}

class _Reader {
  final Uint8List _buf;
  final ByteData _bd;
  int _pos;

  _Reader(this._buf, this._pos) : _bd = ByteData.sublistView(_buf);

  int varint() {
    int result = 0;
    int shift = 0;
    while (true) {
      final b = _buf[_pos++];
      result |= (b & 0x7F) << shift;
      if (b < 0x80) return result;
      shift += 7;
      if (shift > 28) throw const FormatException('Corrupt varint');
    }
  }

  String string() {
    final len = varint();
    final end = _pos + len;
    if (end > _buf.length) throw const FormatException('Truncated string');
    final s = DocumentCodec._utf8Decoder.convert(_buf, _pos, end);
    _pos = end;
    return s;
  }

  int int64() {
    final lo = _bd.getUint32(_pos, Endian.little);
    final hi = _bd.getInt32(_pos + 4, Endian.little);
    _pos += 8;
    return hi * 0x100000000 + lo;
  }

  dynamic value() {
    final tag = _buf[_pos++];
    switch (tag) {
      case DocumentCodec._tNull:
        return null;
      case DocumentCodec._tFalse:
        return false;
      case DocumentCodec._tTrue:
        return true;
      case DocumentCodec._tInt8:
        final b = _buf[_pos++];
        return b >= 0x80 ? b - 0x100 : b;
      case DocumentCodec._tInt32:
        final v = _bd.getInt32(_pos, Endian.little);
        _pos += 4;
        return v;
      case DocumentCodec._tInt64:
        return int64();
      case DocumentCodec._tFloat64:
        final v = _bd.getFloat64(_pos, Endian.little);
        _pos += 8;
        return v;
      case DocumentCodec._tString:
        return string();
      case DocumentCodec._tList:
        final n = varint();
        final list = List<dynamic>.filled(n, null, growable: true);
        for (int i = 0; i < n; i++) {
          list[i] = value();
        }
        return list;
      case DocumentCodec._tMap:
        final n = varint();
        final map = <String, dynamic>{};
        for (int i = 0; i < n; i++) {
          final key = string();
          map[key] = value();
        }
        return map;
      case DocumentCodec._tDateTime:
        return DateTime.fromMicrosecondsSinceEpoch(int64(), isUtc: true);
      case DocumentCodec._tBytes:
        final n = varint();
        final end = _pos + n;
        if (end > _buf.length) throw const FormatException('Truncated bytes');
        final bytes = Uint8List.fromList(Uint8List.sublistView(_buf, _pos, end));
        _pos = end;
        return bytes;
      default:
        throw FormatException('Unknown value tag $tag at offset ${_pos - 1}');
    }
  }
}
