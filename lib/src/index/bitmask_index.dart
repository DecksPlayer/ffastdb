import 'dart:convert';
import 'dart:typed_data';
import 'secondary_index.dart';

/// Ultra-fast bitmask index for low-cardinality fields (booleans, enums, status).
///
/// Each distinct value maps to a [Uint32List] used as a dense bitset.
/// Intersection of two indexes (AND) becomes a bitwise `&` operation,
/// which is 10-100x faster than intersecting two `Set<int>`.
///
/// Ideal for:
///   - Boolean fields: `isActive`, `isPremium`
///   - Enum fields: `status` ('pending', 'active', 'closed')
///   - Category fields with few distinct values (< 1000 distinct values)
///
/// Constraint: This index is only valid for datasets up to [maxDocId] (default: 1M).
///   Adjust on creation for larger datasets.
class BitmaskIndex implements SecondaryIndex {
  @override
  final String fieldName;

  int _maxDocId;
  static const int _bitsPerWord = 32;

  // value → bitset (each bit = one docId)
  final Map<dynamic, Uint32List> _bitsets = {};
  /// Reverse map: docId → fieldValue for O(1) removeById.
  final Map<int, dynamic> _reverse = {};
  int _size = 0;

  /// Tracks the highest docId ever inserted — used to limit [_bitsToList]
  /// iteration to the populated prefix of the bitset, avoiding scanning
  /// thousands of trailing zero words in large pre-allocated bitsets.
  int _highestDocId = -1;

  /// Per-value cache of the [_bitsToList] result.  Invalidated whenever
  /// the bitset for that particular value changes (add/remove).
  final Map<dynamic, List<int>> _lookupCache = {};

  BitmaskIndex(this.fieldName, {int maxDocId = 1 << 20}) // 1M docs default
      : _maxDocId = maxDocId;

  int get _wordCount => (_maxDocId + _bitsPerWord - 1) ~/ _bitsPerWord;

  // ─── Index Operations ─────────────────────────────────────────────────────

  /// Indexes [docId] under [fieldValue].
  /// Null values and negative docIds are silently skipped — documents with
  /// missing fields are excluded from bitmask lookups rather than occupying
  /// a null bucket in the bitset.
  @override
  void add(int docId, dynamic fieldValue) {
    if (fieldValue == null || docId < 0) return;

    if (docId >= _maxDocId) _grow(docId + 1);

    _bitsets.putIfAbsent(fieldValue, () => Uint32List(_wordCount));
    final bits = _bitsets[fieldValue]!;
    if (!_isBitSet(bits, docId)) {
      _setBit(bits, docId);
      _size++;
      _reverse[docId] = fieldValue;
      _lookupCache.remove(fieldValue); // invalidate cached list
    }
  }

  /// Grows [_maxDocId] to accommodate at least [minDocId] documents,
  /// and expands all existing bitsets to the new word count.
  void _grow(int minDocId) {
    while (_maxDocId < minDocId) {
      _maxDocId *= 2;
    }
    final newWordCount = _wordCount;
    for (final key in _bitsets.keys.toList()) {
      final old = _bitsets[key]!;
      if (old.length < newWordCount) {
        final grown = Uint32List(newWordCount);
        grown.setRange(0, old.length, old);
        _bitsets[key] = grown;
      }
    }
  }

  @override
  void remove(int docId, [dynamic fieldValue]) {
    if (fieldValue == null) return;
    
    final bitset = _bitsets[fieldValue];
    if (bitset != null && docId >= 0 && docId < _maxDocId) {
      if (_isBitSet(bitset, docId)) {
        _clearBit(bitset, docId);
        _size--;
        _reverse.remove(docId);
        _lookupCache.remove(fieldValue); // invalidate cached list
      }
    }
  }

  @override
  void removeById(int docId) {
    final value = _reverse.remove(docId);  // O(1)
    if (value == null) return;
    final bitset = _bitsets[value];
    if (bitset != null && docId >= 0 && docId < _maxDocId && _isBitSet(bitset, docId)) {
      _clearBit(bitset, docId);
      _size--;
      _lookupCache.remove(value); // invalidate cached list
    }
  }

  @override
  void clear() {
    _bitsets.clear();
    _reverse.clear();
    _size = 0;
    _highestDocId = -1;
    _lookupCache.clear();
  }

  @override
  List<int> lookup(dynamic value) {
    final bitset = _bitsets[value];
    if (bitset == null) return const [];
    // Return cached list when available — avoids rebuilding on every repeated query.
    return _lookupCache[value] ??= _bitsToList(bitset, _highestDocId);
  }

  @override
  List<int> range(dynamic low, dynamic high) {
    // Bitmask index does not support ranges natively —
    // collect all matching bitsets and OR them together.
    final result = Uint32List(_wordCount);
    for (final entry in _bitsets.entries) {
      try {
        final v = entry.key as Comparable;
        if (v.compareTo(low) >= 0 && v.compareTo(high) <= 0) {
          for (int i = 0; i < _wordCount; i++) {
            result[i] |= entry.value[i];
          }
        }
      } catch (_) {}
    }
    return _bitsToList(result, _highestDocId);
  }

  /// Bitwise AND with another bitmask — ultra-fast intersection.
  ///
  /// Example:
  /// ```dart
  /// final isActive = bitmaskIndex.rawBitset(true);
  /// final isPremium = premiumIndex.rawBitset(true);
  /// final ids = BitmaskIndex.intersect(isActive, isPremium);
  /// ```
  static List<int> intersect(Uint32List a, Uint32List b) {
    final len = a.length < b.length ? a.length : b.length;
    final result = Uint32List(len);
    for (int i = 0; i < len; i++) {
      result[i] = a[i] & b[i];
    }
    // Use the full word length as upper bound since we don't track highestDocId
    // for externally-supplied bitsets.
    return _bitsToList(result, result.length * 32 - 1);
  }

  /// Returns the raw bitset for a given value (for manual intersections).
  Uint32List? rawBitset(dynamic value) => _bitsets[value];

  @override
  List<MapEntry<dynamic, List<int>>> sorted({bool descending = false}) {
    final entries = _bitsets.entries
        .map((e) => MapEntry<dynamic, List<int>>(e.key, _bitsToList(e.value, _highestDocId)))
        .toList();
    try {
      entries.sort((a, b) {
        if (a.key is Comparable && b.key is Comparable) {
          return descending
              ? (b.key as Comparable).compareTo(a.key)
              : (a.key as Comparable).compareTo(b.key);
        }
        return 0;
      });
    } catch (_) {}
    return entries;
  }

  @override
  List<int> all() {
    final result = Uint32List(_wordCount);
    for (final bits in _bitsets.values) {
      for (int i = 0; i < _wordCount; i++) {
        result[i] |= bits[i];
      }
    }
    return _bitsToList(result, _highestDocId);
  }

  int get size => _size;

  /// Number of distinct values. Should be low (< 1000) for this index type.
  int get cardinality => _bitsets.length;

  @override
  String toString() =>
      'BitmaskIndex($fieldName, $_size entries, $cardinality distinct values)';

  // ─── Bitset Helpers ───────────────────────────────────────────────────────

  bool _isBitSet(Uint32List bits, int docId) {
    return (bits[docId ~/ _bitsPerWord] & (1 << (docId % _bitsPerWord))) != 0;
  }

  void _setBit(Uint32List bits, int docId) {
    bits[docId ~/ _bitsPerWord] |= (1 << (docId % _bitsPerWord));
    if (docId > _highestDocId) _highestDocId = docId;
  }

  void _clearBit(Uint32List bits, int docId) {
    bits[docId ~/ _bitsPerWord] &= ~(1 << (docId % _bitsPerWord));
  }

  /// Converts a bitset to a list, scanning only up to [highestDocId] (inclusive).
  /// Passing a tight upper bound avoids iterating thousands of trailing zero
  /// words in a pre-allocated bitset whose capacity far exceeds the live prefix.
  static List<int> _bitsToList(Uint32List bits, int highestDocId) {
    if (highestDocId < 0) return const [];
    final wordLimit = (highestDocId >> 5) + 1; // ⌈(highestDocId+1) / 32⌉
    final limit = wordLimit < bits.length ? wordLimit : bits.length;
    final result = <int>[];
    for (int i = 0; i < limit; i++) {
      int word = bits[i];
      while (word != 0) {
        final bit = word & (-word); // isolate lowest set bit
        final pos = i * 32 + _trailingZeros(bit);
        result.add(pos);
        word &= word - 1; // clear lowest set bit
      }
    }
    return result;
  }

  static int _trailingZeros(int v) {
    if (v == 0) return 32;
    int n = 0;
    if ((v & 0x0000FFFF) == 0) { n += 16; v >>= 16; }
    if ((v & 0x000000FF) == 0) { n += 8; v >>= 8; }
    if ((v & 0x0000000F) == 0) { n += 4; v >>= 4; }
    if ((v & 0x00000003) == 0) { n += 2; v >>= 2; }
    if ((v & 0x00000001) == 0) n += 1;
    return n;
  }

  // ─── Persistence ──────────────────────────────────────────────────────────

  Uint8List serialize() {
    final buf = BytesBuilder();
    final nameBytes = Uint8List.fromList(utf8.encode(fieldName));
    _writeInt32(buf, nameBytes.length);
    buf.add(nameBytes);
    _writeInt32(buf, _maxDocId);
    _writeInt32(buf, _bitsets.length);
    for (final entry in _bitsets.entries) {
      _writeValue(buf, entry.key);
      final ids = _bitsToList(entry.value, _highestDocId);
      _writeInt32(buf, ids.length);
      for (final id in ids) {
        _writeInt32(buf, id);
      }
    }
    return buf.toBytes();
  }

  static BitmaskIndex deserialize(Uint8List bytes) {
    int off = 0;

    int readInt32() {
      final v = (bytes[off] & 0xFF) | ((bytes[off + 1] & 0xFF) << 8) |
          ((bytes[off + 2] & 0xFF) << 16) | ((bytes[off + 3] & 0xFF) << 24);
      off += 4;
      return v;
    }

    dynamic readValue() {
      final tag = bytes[off++];
      switch (tag) {
        case 1:
          return readInt32();
        case 2:
          final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes + off, 8);
          off += 8;
          return bd.getFloat64(0, Endian.little);
        case 3:
          final sLen = readInt32();
          final s = utf8.decode(bytes.sublist(off, off + sLen));
          off += sLen;
          return s;
        case 4:
          return bytes[off++] == 1;
        default:
          return null;
      }
    }

    final nameLen = readInt32();
    final fieldName = utf8.decode(bytes.sublist(off, off + nameLen));
    off += nameLen;
    final maxDocId = readInt32();
    final index = BitmaskIndex(fieldName, maxDocId: maxDocId);
    final valueCount = readInt32();
    for (int i = 0; i < valueCount; i++) {
      final value = readValue();
      final idCount = readInt32();
      for (int j = 0; j < idCount; j++) {
        final docId = readInt32();
        if (value != null) index.add(docId, value);
      }
    }
    return index;
  }

  void _writeValue(BytesBuilder buf, dynamic v) {
    if (v is int) {
      buf.addByte(1);
      _writeInt32(buf, v);
    } else if (v is double) {
      buf.addByte(2);
      final bd = ByteData(8);
      bd.setFloat64(0, v, Endian.little);
      buf.add(bd.buffer.asUint8List());
    } else if (v is String) {
      buf.addByte(3);
      final s = Uint8List.fromList(utf8.encode(v));
      _writeInt32(buf, s.length);
      buf.add(s);
    } else if (v is bool) {
      buf.addByte(4);
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
