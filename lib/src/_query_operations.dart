part of 'fastdb.dart';

/// Manages Query operations for FastDB.
class _QueryOperations {
  final FastDB _db;

  _QueryOperations(this._db);

  /// Executes a query using the QueryBuilder DSL.
  /// Optimized with batch document loading for better performance.
  Future<List<dynamic>> findImpl(FutureOr<List<int>> Function(QueryBuilder q) queryFn) async {
    final builder = QueryBuilder(_db._secondaryIndexes, _db._findById, _db._rangeSearch, _db.watch, _db._queryCache, _db._batchFindByIds);
    final ids = await queryFn(builder);
    return findByIdsImpl(ids);
  }

  /// Batch-loads documents by ID more efficiently than loading one-by-one.
  ///
  /// Uses [FastDB._batchFindByIds], which fetches each chunk's documents
  /// with ONE contiguous read spanning their offsets instead of one
  /// `storage.read()) call per document — on real disk storage that used to
  /// mean a `Future.wait` of N individually-awaited reads, each paying its
  /// own trip through `IoStorageStrategy`'s serializing lock (one syscall,
  /// one Completer/Future). Measured: a 2000-query loop resolving ~80
  /// matches each — the exact shape of `db.query()...find()` on an indexed
  /// field — dropped from ~20s to well under a second.
  Future<List<dynamic>> findByIdsImpl(List<int> ids) async {
    if (ids.isEmpty) return [];

    // For small result sets, a single batch is plenty.
    if (ids.length < 50) {
      return _db._batchFindByIds(ids);
    }

    // For larger result sets, chunk to bound peak memory (one contiguous
    // read per chunk) and to yield to the event loop between chunks.
    const chunkSize = 5000;
    final results = <dynamic>[];
    for (int i = 0; i < ids.length; i += chunkSize) {
      final end = (i + chunkSize < ids.length) ? i + chunkSize : ids.length;
      results.addAll(await _db._batchFindByIds(ids.sublist(i, end)));
      // Yield to event loop to prevent blocking
      if (_runningOnWeb) await Future.delayed(Duration.zero);
    }
    return results;
  }

  /// Retrieves all documents in the database.
  Future<List<dynamic>> getAllImpl() async {
    final rawIds = await _db._primaryIndex.rangeSearch(1, _db._nextId - 1, skipDedupe: true);
    // Deduplicate IDs preserving order — guards against B-Tree structural
    // inconsistencies that could cause rangeSearch to return the same ID twice.
    final ids = LinkedHashSet<int>.from(rawIds).toList();
    return findByIdsImpl(ids);
  }

  /// Returns the number of live documents.
  Future<int> countImpl() async {
    final ids = await _db._primaryIndex.rangeSearch(1, _db._nextId - 1);
    return ids.length;
  }

  /// Returns true if a document with the given ID exists.
  Future<bool> existsImpl(int id) async {
    return await _db._primaryIndex.search(id) != null;
  }
}
