import 'dart:convert';
import 'dart:typed_data';
import 'secondary_index.dart';

// Value type tags for binary serialization
const int _tInt = 1;
const int _tDouble = 2;
const int _tString = 3;
const int _tBool = 4;

/// In-memory hash-based secondary index with persistence support.
/// Fast O(1) lookups. Serialized to a compact binary sidecar on close.
class HashIndex implements SecondaryIndex {
  @override
  final String fieldName;

  final Map<dynamic, List<int>> _map = {};
  /// Reverse map: docId → fieldValue for O(1) removeById.
  final Map<int, dynamic> _reverse = {};
  int _size = 0;

  HashIndex(this.fieldName);

  // ─── Index Operations ─────────────────────────────────────────────────────

  /// Indexes [docId] under [fieldValue].
  /// Null values are silently skipped — this is intentional so that documents
  /// with missing fields are simply excluded from index lookups rather than
  /// forcing every query to handle a null bucket.
  @override
  void add(int docId, dynamic fieldValue) {
    if (fieldValue == null) return;
    _map.putIfAbsent(fieldValue, () => <int>[]).add(docId);
    _reverse[docId] = fieldValue;
    _size++;
  }

  @override
  void remove(int docId, [dynamic fieldValue]) {
    if (fieldValue == null) return;
    final list = _map[fieldValue];
    if (list != null && list.remove(docId)) {
      _size--;
      _reverse.remove(docId);
      if (list.isEmpty) _map.remove(fieldValue);
    }
  }

  @override
  void removeById(int docId) {
    final value = _reverse[docId];  // O(1) — no bucket scan needed
    if (value != null) remove(docId, value);
  }

  @override
  void clear() {
    _map.clear();
    _reverse.clear();
    _size = 0;
  }

  @override
  List<int> lookup(dynamic value) => _map[value] ?? [];

  @override
  List<int> range(dynamic low, dynamic high) {
    final result = <int>[];
    for (final entry in _map.entries) {
      try {
        final v = entry.key as Comparable;
        if (v.compareTo(low) >= 0 && v.compareTo(high) <= 0) {
          result.addAll(entry.value);
        }
      } catch (_) {}
    }
    return result;
  }

  @override
  List<MapEntry<dynamic, List<int>>> sorted({bool descending = false}) {
    final entries = _map.entries.toList();
    try {
      entries.sort((a, b) {
        final ca = a.key as Comparable;
        final cb = b.key as Comparable;
        return descending ? cb.compareTo(ca) : ca.compareTo(cb);
      });
    } catch (_) {}
    return entries;
  }

  @override
  List<int> all() {
    final result = <int>[];
    for (final list in _map.values) {
      result.addAll(list);
    }
    return result;
  }

  int get size => _size;

  @override
  String toString() => 'HashIndex($fieldName, $_size entries)';

  // ─── Persistence ──────────────────────────────────────────────────────────

  /// Serializes the index to a compact binary format.
  ///
  /// Format:
  ///   [4 bytes] fieldName length
  ///   [N bytes] fieldName (UTF-8)
  ///   [4 bytes] entry count
  ///   per entry:
  ///     [1 byte]  value type tag (1=int, 2=double, 3=string, 4=bool)
  ///     [N bytes] encoded value
  ///     [4 bytes] docId count
  ///     [4*N bytes] docIds
  Uint8List serialize() {
    final buf = BytesBuilder();
    final nameBytes = utf8.encode(fieldName);
    _writeInt32(buf, nameBytes.length);
    buf.add(nameBytes);
    _writeInt32(buf, _map.length);

    for (final entry in _map.entries) {
      _writeValue(buf, entry.key);
      final ids = entry.value.toList();
      _writeInt32(buf, ids.length);
      for (final id in ids) {
        _writeInt32(buf, id);
      }
    }
    return buf.toBytes();
  }

  /// Restores an index from its serialized binary form.
  static HashIndex deserialize(Uint8List bytes) {
    int off = 0;

    int readInt32() {
      final v = (bytes[off] & 0xFF) | ((bytes[off + 1] & 0xFF) << 8) |
          ((bytes[off + 2] & 0xFF) << 16) | ((bytes[off + 3] & 0xFF) << 24);
      off += 4;
      return v;
    }

    final nameLen = readInt32();
    final fieldName = utf8.decode(bytes.sublist(off, off + nameLen));
    off += nameLen;

    final index = HashIndex(fieldName);
    final entryCount = readInt32();

    for (int i = 0; i < entryCount; i++) {
      final tag = bytes[off++];
      dynamic value;

      switch (tag) {
        case _tInt:
          value = readInt32();
          break;
        case _tDouble:
          final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes + off, 8);
          value = bd.getFloat64(0, Endian.little);
          off += 8;
          break;
        case _tString:
          final sLen = readInt32();
          value = utf8.decode(bytes.sublist(off, off + sLen));
          off += sLen;
          break;
        case _tBool:
          value = bytes[off++] == 1;
          break;
        default:
          break;
      }

      final idCount = readInt32();
      for (int j = 0; j < idCount; j++) {
        final docId = readInt32();
        if (value != null) index.add(docId, value);
      }
    }
    return index;
  }

  // ─── Write Helpers ────────────────────────────────────────────────────────

  void _writeValue(BytesBuilder buf, dynamic v) {
    if (v is int) {
      buf.addByte(_tInt);
      _writeInt32(buf, v);
    } else if (v is double) {
      buf.addByte(_tDouble);
      final bd = ByteData(8);
      bd.setFloat64(0, v, Endian.little);
      buf.add(bd.buffer.asUint8List());
    } else if (v is String) {
      buf.addByte(_tString);
      final s = utf8.encode(v);
      _writeInt32(buf, s.length);
      buf.add(s);
    } else if (v is bool) {
      buf.addByte(_tBool);
      buf.addByte(v ? 1 : 0);
    }
  }

  void _writeInt32(BytesBuilder buf, int v) {
    buf.addByte(v & 0xFF);
    buf.addByte((v >> 8) & 0xFF);
    buf.addByte((v >> 16) & 0xFF);
    buf.addByte((v >> 24) & 0xFF);
  }
}
