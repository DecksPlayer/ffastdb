import 'dart:convert';
import 'dart:typed_data';
import 'secondary_index.dart';

/// O(log n) sorted secondary index using flat parallel arrays.
///
/// Fast range queries, sorting, and prefix scans. Uses [Uint32List] and
/// pure binary search to avoid Garbage Collection (GC) overhead and 
/// perform operations near C-like speed.
///
/// Use this index when you frequently:
///   - `between(a, b)` — range scans
///   - `greaterThan / lessThan`
///   - `sortBy(field)`
class SortedIndex implements SecondaryIndex {
  @override
  final String fieldName;

  // Parallel flat arrays for pure binary search operations:
  // _docIds is a contiguous Uint32List.
  int _capacity = 16;
  int _length = 0;
  late Uint32List _docIds;
  late List<dynamic> _keys;
  /// Reverse map: docId → key value for O(1) removeById.
  final Map<int, dynamic> _reverse = {};

  SortedIndex(this.fieldName) {
    _docIds = Uint32List(_capacity);
    _keys = List<dynamic>.filled(_capacity, null);
  }

  void _ensureCapacity() {
    if (_length == _capacity) {
      _capacity *= 2;
      final newDocIds = Uint32List(_capacity);
      newDocIds.setRange(0, _length, _docIds);
      _docIds = newDocIds;

      final newKeys = List<dynamic>.filled(_capacity, null);
      newKeys.setRange(0, _length, _keys);
      _keys = newKeys;
    }
  }

  static int _compare(dynamic a, dynamic b) {
    if (a is Comparable && b is Comparable) return a.compareTo(b);
    return a.toString().compareTo(b.toString());
  }

  /// Binary search for the first occurrence of `key` (lower bound).
  int _lowerBound(dynamic key) {
    int low = 0;
    int high = _length;
    while (low < high) {
      int mid = (low + high) >> 1;
      if (_compare(_keys[mid], key) < 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  /// Binary search for the first element strictly > `key` (upper bound).
  int _upperBound(dynamic key) {
    int low = 0;
    int high = _length;
    while (low < high) {
      int mid = (low + high) >> 1;
      if (_compare(_keys[mid], key) <= 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  // ─── Index Operations ─────────────────────────────────────────────────────

  /// Indexes [docId] under [fieldValue].
  /// Null values are silently skipped — documents with missing fields are
  /// excluded from range/sorted queries rather than causing comparison errors.
  @override
  void add(int docId, dynamic fieldValue) {
    if (fieldValue == null) return;

    // Check if docId is already indexed for this value to avoid duplicates
    int start = _lowerBound(fieldValue);
    int end = _upperBound(fieldValue);
    for (int i = start; i < end; i++) {
      if (_docIds[i] == docId) return;
    }
    
    int index = end; // Insert at the end of the matching range
    _ensureCapacity();
    if (index < _length) {
      _docIds.setRange(index + 1, _length + 1, _docIds, index);
      _keys.setRange(index + 1, _length + 1, _keys, index);
    }
    _docIds[index] = docId;
    _keys[index] = fieldValue;
    _length++;
    _reverse[docId] = fieldValue;
  }

  @override
  void remove(int docId, [dynamic fieldValue]) {
    if (fieldValue == null) return;
    
    int start = _lowerBound(fieldValue);
    int end = _upperBound(fieldValue);
    for (int i = start; i < end; i++) {
        if (_docIds[i] == docId) {
            _docIds.setRange(i, _length - 1, _docIds, i + 1);
            _keys.setRange(i, _length - 1, _keys, i + 1);
            _length--;
            _keys[_length] = null; // Free reference for GC
            _reverse.remove(docId);
            break;
        }
    }
  }

  @override
  void removeById(int docId) {
    final value = _reverse.remove(docId);  // O(1)
    if (value == null) return;
    // Binary-search into the value range — O(log n)
    final start = _lowerBound(value);
    final end   = _upperBound(value);
    for (int i = start; i < end; i++) {
      if (_docIds[i] == docId) {
        _docIds.setRange(i, _length - 1, _docIds, i + 1);
        _keys.setRange(i, _length - 1, _keys, i + 1);
        _length--;
        _keys[_length] = null;
        break;
      }
    }
  }

  @override
  void clear() {
    _length = 0;
    _reverse.clear();
  }

  @override
  List<int> lookup(dynamic value) {
    int start = _lowerBound(value);
    int end = _upperBound(value);
    return Uint32List.sublistView(_docIds, start, end);
  }

  @override
  Iterable<int> search(String operator, dynamic value) {
    // 1. Precise match operators (O(log n))
    if (operator == 'equals') return lookup(value);
    
    if (operator == 'notEquals') {
      final matching = lookup(value).toSet();
      return all().where((id) => !matching.contains(id));
    }

    // 2. Range operators (O(log n))
    switch (operator) {
      case 'greaterThan': return greaterThan(value, inclusive: false);
      case 'greaterOrEqualTo': 
      case 'greaterThanOrEqualTo':
        return greaterThan(value, inclusive: true);
      case 'lessThan': return lessThan(value, inclusive: false);
      case 'lessThanOrEqualTo':
      case 'lessOrEqualTo':
        return lessThan(value, inclusive: true);
      case 'between':
        if (value is List && value.length >= 2) {
          return range(value[0], value[1]);
        }
        return [];
    }

    // 3. String operators
    if (operator == 'startsWith') {
      if (value is! String || value.isEmpty) return all();
      // O(log n) binary prefix scan.
      // All strings starting with `prefix` lie in the sorted range
      // [prefix, nextPrefix), where nextPrefix increments the last code unit.
      final start = _lowerBound(value);
      final lastCode = value.codeUnitAt(value.length - 1);
      // Compute exclusive upper bound; guard against overflow at max code unit.
      final upperBound = lastCode < 0xFFFF
          ? value.substring(0, value.length - 1) + String.fromCharCode(lastCode + 1)
          : value.substring(0, value.length - 1);
      final end = upperBound.isEmpty ? _length : _lowerBound(upperBound);
      if (start >= end) return [];
      return List<int>.from(Uint32List.sublistView(_docIds, start, end));
    }

    if (operator == 'contains') {
      if (value is! String || value.isEmpty) return [];
      // Substring match cannot use binary search — O(n) scan is unavoidable.
      final results = <int>{};
      for (final entry in _reverse.entries) {
        final val = entry.value;
        if (val is String && val.contains(value)) results.add(entry.key);
      }
      return results;
    }

    return [];
  }

  /// O(log n) pure range query. Returns a new list to prevent index corruption.
  @override
  List<int> range(dynamic low, dynamic high) {
    int start = _lowerBound(low);
    int end = _upperBound(high);
    if (start >= end) return [];
    // CRITICAL: Must return a copy (List.from) to prevent callers 
    // from mutating the internal index buffer via .sort()
    return List<int>.from(Uint32List.sublistView(_docIds, start, end));
  }

  /// O(log n) forward scan from [low]. Return a zero-allocation view.
  List<int> greaterThan(dynamic low, {bool inclusive = false}) {
    int start = inclusive ? _lowerBound(low) : _upperBound(low);
    return List<int>.from(Uint32List.sublistView(_docIds, start, _length));
  }

  /// O(log n) backward scan up to [high]. Return a zero-allocation view.
  List<int> lessThan(dynamic high, {bool inclusive = false}) {
    int end = inclusive ? _upperBound(high) : _lowerBound(high);
    return List<int>.from(Uint32List.sublistView(_docIds, 0, end));
  }

  /// Returns all IDs in sorted order perfectly contiguously.
  List<int> sortedIds({bool descending = false}) {
    if (_length == 0) return [];
    if (!descending) return List<int>.from(Uint32List.sublistView(_docIds, 0, _length));
    // descending requires an allocation to reverse
    return Uint32List.sublistView(_docIds, 0, _length).reversed.toList();
  }

  @override
  List<MapEntry<dynamic, List<int>>> sorted({bool descending = false}) {
    final result = <MapEntry<dynamic, List<int>>>[];
    if (_length == 0) return result;
    
    dynamic currentKey = _keys[0];
    int start = 0;
    
    void addGroup(int end) {
       final ids = Uint32List.sublistView(_docIds, start, end).toList();
       result.add(MapEntry(currentKey, ids));
    }
    
    for (int i = 1; i < _length; i++) {
       if (_compare(_keys[i], currentKey) != 0) {
           addGroup(i);
           currentKey = _keys[i];
           start = i;
       }
    }
    addGroup(_length);
    
    if (descending) {
       return result.reversed.toList();
    }
    return result;
  }

  @override
  List<int> all() {
    if (_length == 0) return [];
    return Uint32List.sublistView(_docIds, 0, _length).toList();
  }

  @override
  int get size => _length;

  /// Cardinality — number of distinct values. Faster dynamic calculation.
  int get cardinality {
    if (_length == 0) return 0;
    int count = 1;
    dynamic currentKey = _keys[0];
    for (int i = 1; i < _length; i++) {
       if (_compare(_keys[i], currentKey) != 0) {
          count++;
          currentKey = _keys[i];
       }
    }
    return count;
  }

  @override
  String toString() =>
      'SortedIndex($fieldName, $_length entries, $cardinality distinct values)';

  // ─── Persistence ──────────────────────────────────────────────────────────

  Uint8List serialize() {
    final buf = BytesBuilder();
    final nameBytes = utf8.encode(fieldName);
    _writeInt32(buf, nameBytes.length);
    buf.add(nameBytes);
    // NOTE: type tag is written by the caller (_saveIndexes), not here.

    final entries = sorted(); // uses the grouped function
    _writeInt32(buf, entries.length);

    for (final entry in entries) {
      _writeValue(buf, entry.key);
      final ids = entry.value;
      _writeInt32(buf, ids.length);
      for (final id in ids) {
        _writeInt32(buf, id);
      }
    }
    return buf.toBytes();
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
      final s = utf8.encode(v);
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

  /// Restores a SortedIndex from its serialized binary form.
  static SortedIndex deserialize(Uint8List bytes) {
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
        case 1: return readInt32();
        case 2:
          final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes + off, 8);
          off += 8;
          return bd.getFloat64(0, Endian.little);
        case 3:
          final sLen = readInt32();
          final s = utf8.decode(bytes.sublist(off, off + sLen));
          off += sLen;
          return s;
        case 4: return bytes[off++] == 1;
        default: return null;
      }
    }

    final nameLen = readInt32();
    final fieldName = utf8.decode(bytes.sublist(off, off + nameLen));
    off += nameLen;

    final index = SortedIndex(fieldName);
    final entryCount = readInt32();
    for (int i = 0; i < entryCount; i++) {
      final value = readValue();
      final idCount = readInt32();
      for (int j = 0; j < idCount; j++) {
        final docId = readInt32();
        if (value != null) index.add(docId, value);
      }
    }
    return index;
  }
}
