import 'dart:convert';
import 'dart:typed_data';
import 'secondary_index.dart';

/// Composite (multi-field) index for efficient multi-condition queries.
///
/// Indexes multiple field combinations to speed up complex AND queries.
/// For example, indexing ['city', 'age'] creates an index that quickly
/// resolves queries like:
///   db.query().where('city').equals('London').where('age').between(25, 45)
///
/// Performance:
///   - Simple field queries: ~O(log n) on individual indexes
///   - Composite queries: ~O(log n) direct lookup (vs O(n + m) intersection)
///   - Storage: Additional memory for composite keys
///
/// Example:
/// ```dart
/// // Create a composite index on ['city', 'status']
/// final db = await openDatabase('myapp');
/// db.indexes.addCompositeIndex(['city', 'status']);
///
/// // Now this query is O(log n) instead of O(n + m):
/// final results = await db.query()
///   .where('city').equals('London')
///   .where('status').equals('active')
///   .find();
/// ```
class CompositeIndex extends SecondaryIndex {
  /// Field names that compose this index (in order).
  final List<String> fieldNames;

  /// Maps composite keys to document IDs.
  /// Key format: "field1_value|field2_value|..."
  final Map<String, List<int>> _entries = {};

  CompositeIndex(this.fieldNames) : super();

  @override
  String get fieldName => fieldNames.join('+');

  /// Creates a composite key from field values.
  static String _compositeKey(List<dynamic> values) {
    return values
        .map((v) => v == null ? 'null' : v.toString())
        .join('|');
  }

  @override
  void add(int docId, dynamic value) {
    // 'value' should be a List of values corresponding to fieldNames
    if (value is! List) return;
    if (value.length != fieldNames.length) return;

    final key = _compositeKey(value);
    _entries.putIfAbsent(key, () => []).add(docId);
  }

  @override
  Iterable<int> search(String operator, dynamic value) {
    if (operator == 'equals') return lookup(value);
    return [];
  }

  @override
  List<int> lookup(dynamic value) {
    if (value is! List) return [];
    if (value.length != fieldNames.length) return [];

    final key = _compositeKey(value);
    final matches = _entries[key];
    return matches != null ? List<int>.from(matches) : [];
  }

  @override
  List<int> all() {
    final results = <int>{};
    for (final ids in _entries.values) {
      results.addAll(ids);
    }
    return results.toList();
  }

  @override
  int get size {
    final results = <int>{};
    for (final ids in _entries.values) {
      results.addAll(ids);
    }
    return results.length;
  }

  @override
  void clear() {
    _entries.clear();
  }

  @override
  List<MapEntry<dynamic, List<int>>> sorted({bool descending = false}) {
    // For composite indexes, sorting by composite key is complex
    // Return entries in key order (lexicographic)
    final sortedKeys = _entries.keys.toList()..sort();
    if (descending) {
      sortedKeys.sort((a, b) => b.compareTo(a));
    }
    
    return [
      for (final key in sortedKeys) MapEntry(key, _entries[key]!),
    ];
  }

  @override
  List<int> range(dynamic min, dynamic max) {
    // Range queries on composite indexes are complex
    // For now, return empty list. Can be implemented with prefix matching.
    return [];
  }

  @override
  void remove(int docId, dynamic value) {
    if (value is! List) return;
    if (value.length != fieldNames.length) return;

    final key = _compositeKey(value);
    final ids = _entries[key];
    if (ids != null) {
      ids.remove(docId);
      if (ids.isEmpty) {
        _entries.remove(key);
      }
    }
  }

  @override
  void removeById(int docId) {
    // Remove from all entries
    for (final ids in _entries.values) {
      ids.remove(docId);
    }
    // Clean up empty entries
    _entries.removeWhere((key, ids) => ids.isEmpty);
  }

  // ─── Persistence ──────────────────────────────────────────────────────────

  Uint8List serialize() {
    final buf = BytesBuilder();
    _writeInt32(buf, fieldNames.length);
    for (final f in fieldNames) {
      final fBytes = Uint8List.fromList(utf8.encode(f));
      _writeInt32(buf, fBytes.length);
      buf.add(fBytes);
    }
    
    _writeInt32(buf, _entries.length);
    for (final entry in _entries.entries) {
      final keyBytes = Uint8List.fromList(utf8.encode(entry.key));
      _writeInt32(buf, keyBytes.length);
      buf.add(keyBytes);
      
      _writeInt32(buf, entry.value.length);
      for (final id in entry.value) {
        _writeInt32(buf, id);
      }
    }
    return buf.toBytes();
  }

  static CompositeIndex deserialize(Uint8List bytes) {
    int off = 0;
    int readInt32() {
      final v = (bytes[off] & 0xFF) | ((bytes[off + 1] & 0xFF) << 8) |
          ((bytes[off + 2] & 0xFF) << 16) | ((bytes[off + 3] & 0xFF) << 24);
      off += 4;
      return v;
    }

    final fieldCount = readInt32();
    final fieldNames = <String>[];
    for (int i = 0; i < fieldCount; i++) {
      final fLen = readInt32();
      fieldNames.add(utf8.decode(bytes.sublist(off, off + fLen)));
      off += fLen;
    }

    final index = CompositeIndex(fieldNames);
    final entryCount = readInt32();
    for (int i = 0; i < entryCount; i++) {
      final keyLen = readInt32();
      final key = utf8.decode(bytes.sublist(off, off + keyLen));
      off += keyLen;
      
      final idCount = readInt32();
      final ids = <int>[];
      for (int j = 0; j < idCount; j++) {
        ids.add(readInt32());
      }
      index._entries[key] = ids;
    }
    return index;
  }

  void _writeInt32(BytesBuilder buf, int v) {
    buf.addByte(v & 0xFF);
    buf.addByte((v >> 8) & 0xFF);
    buf.addByte((v >> 16) & 0xFF);
    buf.addByte((v >> 24) & 0xFF);
  }
}
