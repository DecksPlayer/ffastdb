import 'dart:convert';
import 'dart:typed_data';
import 'secondary_index.dart';

// Value type tags for binary serialization
const int _tInt = 1;    // legacy: 32-bit int — kept for reading old index blobs
const int _tDouble = 2;
const int _tString = 3;
const int _tBool = 4;
const int _tInt64 = 5;  // 64-bit int — used for all new writes

/// In-memory hash-based secondary index with persistence support.
/// Fast O(1) lookups using optimized hash buckets for Isar-level performance.
/// Uses FNV-1a hash for better distribution and reduced collisions.
class HashIndex implements SecondaryIndex {
  @override
  final String fieldName;

  // Optimized bucket-based storage with better distribution
  static const int _initialBuckets = 256; // Power of 2 for fast modulo
  late List<List<_HashEntry>> _buckets;
  int _bucketCount = _initialBuckets;

  /// Reverse map: docId → fieldValue for O(1) removeById.
  final Map<int, dynamic> _reverse = {};
  int _size = 0;
  List<int>? _allCache;

  HashIndex(this.fieldName) {
    _buckets = List.generate(_bucketCount, (_) => <_HashEntry>[]);
  }

  // ─── FNV-1a Hash Function ─────────────────────────────────────────────────
  
  /// Fast FNV-1a hash with better distribution than Dart's default hashCode
  int _hash(dynamic value) {
    if (value == null) return 0;

    // FNV-1a constants
    const int fnvPrime = 16777619;
    int hash = 2166136261;

    if (value is num) {
      // Numeric values hash by mathematical value: in Dart, equal nums have
      // equal hashCodes (1.hashCode == (1.0).hashCode), and int.hashCode is
      // the int itself. Mixing all 8 bytes also fixes the old 32-bit-only
      // mixing that collided every 64-bit timestamp into the same buckets.
      int h = value.hashCode;
      for (int i = 0; i < 8; i++) {
        hash ^= h & 0xFF;
        hash *= fnvPrime;
        h >>= 8;
      }
    } else if (value is String) {
      for (int i = 0; i < value.length; i++) {
        hash ^= value.codeUnitAt(i);
        hash *= fnvPrime;
      }
    } else {
      // Fallback to default hashCode for other types
      final code = value.hashCode;
      hash ^= code & 0xFF;
      hash *= fnvPrime;
      hash ^= (code >> 8) & 0xFF;
      hash *= fnvPrime;
    }

    return hash & 0x7FFFFFFF; // Keep positive
  }

  // ─── Index Operations ─────────────────────────────────────────────────────

  /// Indexes [docId] under [fieldValue].
  /// Null values are silently skipped — this is intentional so that documents
  /// with missing fields are simply excluded from index lookups rather than
  /// forcing every query to handle a null bucket.
  @override
  void add(int docId, dynamic fieldValue) {
    if (fieldValue == null) return;

    // Idempotency: if this docId is already indexed under a DIFFERENT value,
    // remove the stale entry first — add() is safe without a prior remove().
    final existing = _reverse[docId];
    if (existing != null && !_equals(existing, fieldValue)) {
      remove(docId, existing);
    }

    final hashCode = _hash(fieldValue);
    final bucketIdx = hashCode & (_bucketCount - 1); // Fast modulo for power of 2
    final bucket = _buckets[bucketIdx];

    // Check if value already exists in bucket
    for (final entry in bucket) {
      if (_equals(entry.value, fieldValue)) {
        if (!entry.docIds.contains(docId)) {
          entry.docIds.add(docId);
          _reverse[docId] = fieldValue;
          _size++;
          _allCache = null;
        }
        return;
      }
    }
    
    // Add new entry
    bucket.add(_HashEntry(fieldValue, [docId]));
    _reverse[docId] = fieldValue;
    _size++;
    _allCache = null;
    
    // Auto-resize if load factor > 0.75
    if (_size > _bucketCount * 0.75) {
      _resize();
    }
  }

  @override
  void remove(int docId, [dynamic fieldValue]) {
    if (fieldValue == null) return;
    
    final hashCode = _hash(fieldValue);
    final bucketIdx = hashCode & (_bucketCount - 1);
    final bucket = _buckets[bucketIdx];
    
    for (int i = 0; i < bucket.length; i++) {
      final entry = bucket[i];
      if (_equals(entry.value, fieldValue)) {
        if (entry.docIds.remove(docId)) {
          _size--;
          _reverse.remove(docId);
          _allCache = null;
          if (entry.docIds.isEmpty) {
            bucket.removeAt(i);
          }
        }
        return;
      }
    }
  }

  @override
  void removeById(int docId) {
    final value = _reverse[docId];  // O(1) — no bucket scan needed
    if (value != null) remove(docId, value);
  }

  @override
  void clear() {
    _buckets = List.generate(_bucketCount, (_) => <_HashEntry>[]);
    _reverse.clear();
    _size = 0;
    _allCache = null;
  }

  @override
  Iterable<int> search(String operator, dynamic value) {
    if (operator == 'equals') return lookup(value);
    if (operator == 'notEquals') {
      final matching = lookup(value).toSet();
      return all().where((id) => !matching.contains(id));
    }
    // HashIndex has no ordering — prefix/substring scans are O(n).
    // Prefer SortedIndex (addSortedIndex) for startsWith to get O(log n).
    if (operator == 'startsWith') {
      if (value is! String || value.isEmpty) return all();
      final results = <int>[];
      for (final entry in _reverse.entries) {
        if (entry.value is String && (entry.value as String).startsWith(value)) {
          results.add(entry.key);
        }
      }
      return results;
    }
    if (operator == 'contains') {
      if (value is! String || value.isEmpty) return [];
      final results = <int>[];
      for (final entry in _reverse.entries) {
        if (entry.value is String && (entry.value as String).contains(value)) {
          results.add(entry.key);
        }
      }
      return results;
    }
    return [];
  }

  @override
  List<int> lookup(dynamic value) {
    if (value == null) return [];
    
    final hashCode = _hash(value);
    final bucketIdx = hashCode & (_bucketCount - 1);
    final bucket = _buckets[bucketIdx];
    
    for (final entry in bucket) {
      if (_equals(entry.value, value)) {
        // CRITICAL: Return a copy to prevent query engine from mutating the index
        return List<int>.from(entry.docIds);
      }
    }
    return [];
  }

  @override
  int lookupCount(dynamic value) {
    if (value == null) return 0;
    
    final hashCode = _hash(value);
    final bucketIdx = hashCode & (_bucketCount - 1);
    final bucket = _buckets[bucketIdx];
    
    for (final entry in bucket) {
      if (_equals(entry.value, value)) {
        return entry.docIds.length;
      }
    }
    return 0;
  }

  @override
  dynamic valueOf(int docId) => _reverse[docId];

  /// Resize hash table when load factor is too high
  void _resize() {
    final oldBuckets = _buckets;
    _bucketCount *= 2;
    _buckets = List.generate(_bucketCount, (_) => <_HashEntry>[]);
    
    for (final bucket in oldBuckets) {
      for (final entry in bucket) {
        final hashCode = _hash(entry.value);
        final newBucketIdx = hashCode & (_bucketCount - 1);
        _buckets[newBucketIdx].add(entry);
      }
    }
  }

  /// Fast equality check.
  /// Unified numeric equality: 1 and 1.0 match (mirrors Dart `==` and the
  /// SortedIndex comparator) — other types require the same runtime type.
  bool _equals(dynamic a, dynamic b) {
    if (identical(a, b)) return true;
    if (a is num && b is num) return a == b;
    if (a.runtimeType != b.runtimeType) return false;
    return a == b;
  }

  @override
  List<int> range(dynamic low, dynamic high) {
    final result = <int>[];
    for (final bucket in _buckets) {
      for (final entry in bucket) {
        try {
          final v = entry.value as Comparable;
          if (v.compareTo(low) >= 0 && v.compareTo(high) <= 0) {
            result.addAll(entry.docIds);
          }
        } catch (_) {}
      }
    }
    return result;
  }

  @override
  List<MapEntry<dynamic, List<int>>> sorted({bool descending = false}) {
    final entries = <MapEntry<dynamic, List<int>>>[];
    for (final bucket in _buckets) {
      for (final entry in bucket) {
        entries.add(MapEntry(entry.value, entry.docIds));
      }
    }
    try {
      entries.sort((a, b) {
        final ca = a.key as Comparable;
        final cb = b.key as Comparable;
        return descending ? cb.compareTo(ca) : ca.compareTo(cb);
      });
    } catch (_) {}
    return entries;
  }

  /// Returns all docIds whose key satisfies [predicate].
  /// More efficient than sorted() for prefix/substring filters because it
  /// does not allocate or sort a full copy of the index.
  List<int> filterKeys(bool Function(dynamic key) predicate) {
    final result = <int>[];
    for (final bucket in _buckets) {
      for (final entry in bucket) {
        if (predicate(entry.value)) result.addAll(entry.docIds);
      }
    }
    return result;
  }

  List<int> _buildAll() {
    final result = <int>[];
    for (final bucket in _buckets) {
      for (final entry in bucket) {
        result.addAll(entry.docIds);
      }
    }
    return result;
  }

  @override
  List<int> all() {
    _allCache ??= _buildAll();
    return List<int>.from(_allCache!);
  }

  @override
  int get size => _size;

  @override
  String toString() => 'HashIndex($fieldName, $_size entries, $_bucketCount buckets)';

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
    
    // Count total entries
    int totalEntries = 0;
    for (final bucket in _buckets) {
      totalEntries += bucket.length;
    }
    _writeInt32(buf, totalEntries);

    for (final bucket in _buckets) {
      for (final entry in bucket) {
        _writeValue(buf, entry.value);
        final ids = entry.docIds.toList();
        _writeInt32(buf, ids.length);
        for (final id in ids) {
          _writeInt32(buf, id);
        }
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

    // Pre-size the table for the known entry count — avoids repeated
    // rehashing via _resize() during the restore.
    while (entryCount > index._bucketCount * 0.75) {
      index._bucketCount *= 2;
    }
    if (index._bucketCount != index._buckets.length) {
      index._buckets = List.generate(index._bucketCount, (_) => <_HashEntry>[]);
    }

    for (int i = 0; i < entryCount; i++) {
      final tag = bytes[off++];
      dynamic value;

      switch (tag) {
        case _tInt:
          // Legacy 32-bit format — read 4 bytes for backward compatibility
          value = readInt32();
          break;
        case _tInt64:
          // Current 64-bit format
          final lo = readInt32();
          final hi = readInt32();
          value = lo | (hi << 32);
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
      // Bulk restore: each value appears once in the blob and ids are
      // duplicate-free by construction — insert the bucket entry directly
      // (the old add()-per-document restore paid O(k) contains() per doc,
      // O(n·k) total on hot buckets).
      final ids = <int>[for (int j = 0; j < idCount; j++) readInt32()];
      if (value != null) {
        final hashCode = index._hash(value);
        final bucketIdx = hashCode & (index._bucketCount - 1);
        index._buckets[bucketIdx].add(_HashEntry(value, ids));
        for (final id in ids) {
          index._reverse[id] = value;
        }
        index._size += idCount;
      }
    }
    return index;
  }

  // ─── Write Helpers ────────────────────────────────────────────────────────

  void _writeValue(BytesBuilder buf, dynamic v) {
    if (v is int) {
      buf.addByte(_tInt64);
      _writeInt64(buf, v);
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
    } else {
      // Fail fast: writing nothing (not even the tag) desynchronizes the
      // reader and corrupts the whole index blob silently.
      throw ArgumentError(
          'HashIndex: unsupported value type for serialization: ${v.runtimeType}');
    }
  }

  void _writeInt32(BytesBuilder buf, int v) {
    buf.addByte(v & 0xFF);
    buf.addByte((v >> 8) & 0xFF);
    buf.addByte((v >> 16) & 0xFF);
    buf.addByte((v >> 24) & 0xFF);
  }

  void _writeInt64(BytesBuilder buf, int v) {
    buf.addByte(v & 0xFF);
    buf.addByte((v >> 8) & 0xFF);
    buf.addByte((v >> 16) & 0xFF);
    buf.addByte((v >> 24) & 0xFF);
    buf.addByte((v >> 32) & 0xFF);
    buf.addByte((v >> 40) & 0xFF);
    buf.addByte((v >> 48) & 0xFF);
    buf.addByte((v >> 56) & 0xFF);
  }
}

/// Internal bucket entry for optimized hash storage
class _HashEntry {
  final dynamic value;
  final List<int> docIds;
  
  _HashEntry(this.value, this.docIds);
}
