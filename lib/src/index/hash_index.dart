import 'dart:convert';
import 'dart:typed_data';
import 'secondary_index.dart';
import 'bloom_filter.dart';

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

  /// Bloom Filter for fast "definitely not contains" checks on negative queries.
  /// Dramatically speeds up queries like: .where('status').not().equals('inactive')
  late BloomFilter<String> _bloomFilter;

  HashIndex(this.fieldName) {
    _buckets = List.generate(_bucketCount, (_) => <_HashEntry>[]);
    // Create Bloom Filter with ~1% false positive rate
    // Assumes up to 100k unique values per field
    _bloomFilter = BloomFilter<String>(expectedSize: 100000, falsePositiveRate: 0.01);
  }

  // ─── FNV-1a Hash Function ─────────────────────────────────────────────────
  
  /// Fast FNV-1a hash with better distribution than Dart's default hashCode
  int _hash(dynamic value) {
    if (value == null) return 0;
    
    // FNV-1a constants
    const int fnvPrime = 16777619;
    int hash = 2166136261;
    
    if (value is int) {
      hash ^= value & 0xFF;
      hash *= fnvPrime;
      hash ^= (value >> 8) & 0xFF;
      hash *= fnvPrime;
      hash ^= (value >> 16) & 0xFF;
      hash *= fnvPrime;
      hash ^= (value >> 24) & 0xFF;
      hash *= fnvPrime;
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
    
    final hashCode = _hash(fieldValue);
    final bucketIdx = hashCode & (_bucketCount - 1); // Fast modulo for power of 2
    final bucket = _buckets[bucketIdx];
    
    // Add to Bloom Filter for fast negative query optimization
    _bloomFilter.add(fieldValue.toString());
    
    // Check if value already exists in bucket
    for (final entry in bucket) {
      if (_equals(entry.value, fieldValue)) {
        if (!entry.docIds.contains(docId)) {
          entry.docIds.add(docId);
          _reverse[docId] = fieldValue;
          _size++;
        }
        return;
      }
    }
    
    // Add new entry
    bucket.add(_HashEntry(fieldValue, [docId]));
    _reverse[docId] = fieldValue;
    _size++;
    
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
    _bloomFilter.clear();
    _size = 0;
  }

  /// Checks if a value might be in the index using Bloom Filter.
  /// Returns false if value is definitely NOT in index.
  /// Returns true if value might be in index (or false positive).
  /// 
  /// Used to optimize negated queries: .where('status').not().equals('inactive')
  /// If mightContainValue returns false, we can skip the negation logic.
  bool mightContainValue(dynamic value) {
    if (value == null) return false;
    return _bloomFilter.mightContain(value.toString());
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

  /// Fast equality check
  bool _equals(dynamic a, dynamic b) {
    if (identical(a, b)) return true;
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

  @override
  List<int> all() {
    final result = <int>[];
    for (final bucket in _buckets) {
      for (final entry in bucket) {
        result.addAll(entry.docIds);
      }
    }
    return result;
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
