part of 'fastdb.dart';

/// JSON interoperability at the API boundary. Documents are stored in the
/// binary format ([DocumentCodec]); these helpers convert to/from plain JSON
/// for syncing with or migrating to/from other document databases.
class _JsonOperations {
  final FastDB _db;

  _JsonOperations(this._db);

  Future<String> exportJsonImpl() async {
    final docs = await _db._queryOps.getAllImpl();
    return jsonEncode([for (final doc in docs) _toPlainJson(_asMap(doc))]);
  }

  Future<List<int>> importJsonImpl(String json) async {
    final decoded = jsonDecode(json);
    final items = decoded is List ? decoded : [decoded];
    final docs = <Map<String, dynamic>>[];
    for (final item in items) {
      if (item is! Map<String, dynamic>) {
        throw FormatException(
            'importJson: expected a JSON object or an array of objects, '
            'found ${item.runtimeType}');
      }
      // ids are assigned by this database; an exported ffdbID would collide.
      docs.add(item..remove('ffdbID'));
    }
    return _db._batchOps.insertAllImpl(docs);
  }

  static Map _asMap(dynamic doc) {
    if (doc is Map) return doc;
    try {
      return (doc as dynamic).toJson() as Map;
    } catch (_) {
      throw UnsupportedError(
          'exportJson: document of type ${doc.runtimeType} is not a Map and '
          'has no toJson() method.');
    }
  }

  /// Maps stored values onto plain JSON: DateTime → ISO-8601 UTC string,
  /// Uint8List → base64 string, NaN/±Infinity → null (JSON has no such
  /// numbers), map keys → strings.
  static dynamic _toPlainJson(dynamic v) {
    if (v is Map) {
      return <String, dynamic>{
        for (final e in v.entries) e.key.toString(): _toPlainJson(e.value),
      };
    }
    if (v is Uint8List) return base64Encode(v);
    if (v is List) return [for (final item in v) _toPlainJson(item)];
    if (v is DateTime) return v.toUtc().toIso8601String();
    if (v is double && !v.isFinite) return null;
    return v;
  }
}
