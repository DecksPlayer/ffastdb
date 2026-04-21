import 'dart:async';
import 'dart:typed_data';
import 'package:meta/meta.dart';
import 'storage/storage_strategy.dart';
import 'storage/page_manager.dart';
import 'storage/wal_storage_strategy.dart';
import 'index/btree.dart';
import 'index/hash_index.dart';
import 'index/sorted_index.dart';
import 'index/bitmask_index.dart';
import 'index/composite_index.dart';
import 'index/fts_index.dart';
import 'query/fast_query.dart';
import 'serialization/fast_serializer.dart';
import 'serialization/type_adapter.dart';
import 'serialization/type_registry.dart';
import 'index/secondary_index.dart';
import 'serialization/binary_io.dart';

part '_crud_operations.dart';
part '_query_operations.dart';
part '_batch_operations.dart';
part '_index_manager.dart';
part '_storage_manager.dart';

/// True on JavaScript/web (integer and double share representation),
/// false on native Dart VM. Used to gate UI-yield calls that are only
/// needed on web to prevent browser tab jank.
const bool _runningOnWeb = identical(0, 0.0);

/// FastDB — A high-performance, pure-Dart NoSQL database.
///
/// Supports JSON documents, custom objects via TypeAdapters,
/// B-Tree primary index, hash-based secondary indexes,
/// fluent queries, and reactive watchers.
///
/// ## Structure
/// This class is organized into clear sections (search for `// ───` comments):
/// - **Singleton** — Global instance management (init, instance, disposeInstance)
/// - **Initialization** — Constructor, open, close, checkpoint
/// - **Setup** — registerAdapter, addIndex, addSortedIndex, reindex
/// - **CRUD Operations** — insert, put, update, delete, insertAll, updateWhere, deleteWhere
/// - **Batch & Transactions** — beginBatch, commitBatch, transaction
/// - **Query Operations** — find, findWhere, getAll, stream, count, exists, rangeSearch
/// - **Batch Reads** — findById, findByIdBatch (parallel reads)
/// - **Aggregations** — sumWhere, avgWhere, minWhere, maxWhere, countWhere
/// - **Watchers** — watch, _notifyWatchers (reactive streams)
/// - **Internal Helpers** — Serialization, persistence, caching, indexing
class FastDB {
  final StorageStrategy storage;
  final StorageStrategy? dataStorage;
  late PageManager _pageManager;
  late final BTree _primaryIndex;
  final TypeRegistry _registry = TypeRegistry();
  final Map<String, SecondaryIndex> _secondaryIndexes = {};

  // Reactive watchers: field → StreamController
  final Map<String, StreamController<List<int>>> _watchers = {};

  bool _batchMode = false;
  bool _inTransaction = false;
  int _nextId = 1;
  
  /// Whether this database instance has been closed.
  /// Used to prevent operations on a closed database, especially important
  /// for the singleton pattern where users might retain references after dispose.
  bool _isClosed = false;

  /// Whether this database instance is currently open and usable.
  ///
  /// Returns `false` after [close] has been called. Check this before
  /// performing operations when you may hold a reference across lifecycle events.
  bool get isOpen => !_isClosed;

  Future<void> _writeLock = Future.value();

  Future<T> _exclusive<T>(Future<T> Function() fn) {
    if (_isClosed) {
      throw StateError(
        'Bad state: Cannot perform operations on a closed database. '
        'This can happen if:\n'
        '  1. close() or disposeInstance() was called before this operation.\n'
        '  2. A second openDatabase() call replaced the active instance.\n'
        '  3. An async operation completed after the DB was disposed.\n'
        'Call ffastdb.init() or openDatabase() again to reopen the database.',
      );
    }
    if (_inTransaction) return fn();
    final next = _writeLock.then((_) => fn());
    _writeLock = next.then((_) {}, onError: (_) {});
    return next;
  }

  final List<MapEntry<int, int>> _batchEntries = [];
  int _dataOffset = 0;

  int _schemaVersion = 1;
  double _autoCompactThreshold = 0;

  // Helper classes for modularized operations
  late final _CrudOperations _crudOps;
  late final _QueryOperations _queryOps;
  late final _BatchOperations _batchOps;
  late final _IndexManager _indexMgr;
  late final _StorageManager _storageMgr;

  WalStorageStrategy? get _wal =>
      storage is WalStorageStrategy ? storage as WalStorageStrategy : null;

  /// Internal constructor used by factory constructors and singleton.
  FastDB._internal(this.storage, {
    this.dataStorage,
    int cacheCapacity = 2048,
    double autoCompactThreshold = double.minPositive,
  }) {
    _autoCompactThreshold = autoCompactThreshold;
    _pageManager = PageManager(storage, cacheCapacity: cacheCapacity);
    _primaryIndex = BTree(_pageManager);
    
    // Initialize helper classes for modularized operations
    _crudOps = _CrudOperations(this);
    _queryOps = _QueryOperations(this);
    _batchOps = _BatchOperations(this);
    _indexMgr = _IndexManager(this);
    _storageMgr = _StorageManager(this);
  }
  
  /// Creates a FastDB instance directly.
  /// 
  /// **For most applications**, use [FfastDb.init()] with the singleton pattern instead.
  /// Use this constructor when you need multiple isolated database instances 
  /// (e.g., benchmarks, advanced use cases, or non-singleton scenarios).
  ///
  /// Provide [dataStorage] to separate documents from B-Tree pages for max performance.
  /// Set [autoCompactThreshold] (0–1) to trigger automatic compaction whenever the
  /// ratio of deleted documents exceeds that fraction. E.g. `0.3` = compact when
  /// more than 30% of slots are deleted. Disabled by default (0).
  factory FastDB(StorageStrategy storage, {
    StorageStrategy? dataStorage,
    int cacheCapacity = 2048,
    double autoCompactThreshold = double.minPositive,
  }) {
    return FastDB._internal(
      storage,
      dataStorage: dataStorage,
      cacheCapacity: cacheCapacity,
      autoCompactThreshold: autoCompactThreshold,
    );
  }
  
  /// Constructor for testing purposes - directly creates a FastDB instance.
  /// **WARNING**: In production code, use [FfastDb.init()] instead.
  @visibleForTesting
  factory FastDB.forTesting(StorageStrategy storage, {
    StorageStrategy? dataStorage,
    int cacheCapacity = 2048,
    double autoCompactThreshold = double.minPositive,
  }) {
    return FastDB._internal(
      storage,
      dataStorage: dataStorage,
      cacheCapacity: cacheCapacity,
      autoCompactThreshold: autoCompactThreshold,
    );
  }

  // ─── Singleton ────────────────────────────────────────────────────────────

  static FastDB? _instance;

  /// The global singleton instance. Throws if [init()] has not been called yet.
  static FastDB get instance {
    if (_instance == null) {
      throw StateError(
          'FfastDb not initialized. Call `await FfastDb.init(storage)` first.');
    }
    if (_instance!._isClosed) {
      throw StateError(
          'FfastDb instance has been closed. Call `await FfastDb.init(storage)` again.');
    }
    return _instance!;
  }

  /// Initializes the global singleton, opens the database, and returns it.
  ///
  /// Example:
  /// ```dart
  /// final db = await FfastDb.init(
  ///   WalStorageStrategy(
  ///     main: IoStorageStrategy('/data/myapp.db'),
  ///     wal: IoStorageStrategy('/data/myapp.db.wal'),
  ///   ),
  /// );
  /// // Later anywhere:
  /// final doc = await FfastDb.instance.findById(1);
  /// ```
  static Future<FastDB> init(
    StorageStrategy storage, {
    StorageStrategy? dataStorage,
    int cacheCapacity = 256,
    double autoCompactThreshold = double.minPositive,
    int version = 1,
    Map<int, dynamic Function(dynamic)>? migrations,
    List<String> indexes = const [],
    List<String> sortedIndexes = const [],
  }) async {
    final db = FastDB._internal(
      storage,
      dataStorage: dataStorage,
      cacheCapacity: cacheCapacity,
      autoCompactThreshold: autoCompactThreshold,
    );
    // Register indexes BEFORE open() so that _loadIndexes() can match blobs
    // to their correct type, and the singleton is never exposed without indexes.
    for (final field in indexes) db.addIndex(field);
    for (final field in sortedIndexes) db.addSortedIndex(field);
    await db.open(version: version, migrations: migrations);
    _instance = db; // expose singleton only after open() completes
    return db;
  }

  /// Closes and releases the singleton instance.
  static Future<void> disposeInstance() async {
    await _instance?.close();
    _instance = null;
  }

  void _enableWriteBehind() => _pageManager.setWriteBehind(true);
  void _disableWriteBehind() {
    if (storage.needsExplicitFlush) _pageManager.setWriteBehind(false);
  }

  /// Returns LRU cache statistics (hit rate, size, capacity).
  String get cacheStats => _pageManager.cacheStats;

  /// WAL checkpoint: truncates the WAL file after all changes are committed.
  Future<void> checkpoint() => _wal?.checkpoint() ?? Future.value();

  // ─── Setup ────────────────────────────────────────────────────────────────

  /// Registers a custom type adapter (Hive-style).
  void registerAdapter<T>(TypeAdapter<T> adapter) => _indexMgr.registerAdapter(adapter);

  /// Creates an O(1) hash-based secondary index on [fieldName].
  void addIndex(String fieldName) => _indexMgr.addIndex(fieldName);

  /// Creates an O(log n) sorted secondary index on [fieldName].
  void addSortedIndex(String fieldName) => _indexMgr.addSortedIndex(fieldName);

  /// Creates a bitmask index on [fieldName].
  void addBitmaskIndex(String fieldName, {int maxDocId = 1 << 16}) =>
      _indexMgr.addBitmaskIndex(fieldName, maxDocId: maxDocId);

  /// Creates a composite (multi-field) index for efficient AND queries.
  ///
  /// Composite indexes dramatically speed up queries on multiple fields:
  /// ```dart
  /// db.addCompositeIndex(['city', 'status']);
  /// // Now this query is O(log n) instead of O(n + m):
  /// final results = await db.query()
  ///   .where('city').equals('London')
  ///   .where('status').equals('active')
  ///   .find();
  /// ```
  ///
  /// Performance: 10-100x speedup on multi-field AND queries.
  void addCompositeIndex(List<String> fieldNames) =>
      _indexMgr.addCompositeIndex(fieldNames);

  /// Creates a Full-Text Search (FTS) index on [fieldName].
  ///
  /// FTS indexes enable fast text searching with tokenization and inverted indexing.
  /// Supports exact word search, prefix matching, and multi-word AND queries.
  ///
  /// Performance: 100-1000x faster than `contains()` on large text fields.
  ///
  /// Example:
  /// ```dart
  /// db.addFtsIndex('description');
  /// final results = await db.query()
  ///   .where('description').fts('london')
  ///   .find();
  /// ```
  void addFtsIndex(String fieldName) => _indexMgr.addFtsIndex(fieldName);

  /// Rebuilds secondary indexes from live documents.
  ///
  /// Pass [field] to rebuild only that index; omit to rebuild all.
  Future<void> reindex([String? field]) => _indexMgr.reindex(field);

  // ─── Open / Close ─────────────────────────────────────────────────────────

  Future<void> open({
    int version = 1,
    Map<int, dynamic Function(dynamic)>? migrations,
  }) async {
    // Clear the global query cache when opening a new database.
    // This prevents query results from one database/test from contaminating another.
    QueryBuilder.clearCache();
    
    _schemaVersion = version;
    await storage.open();

    if (!storage.needsExplicitFlush) _pageManager.writeBehind = true;

    final size = await storage.size;
    int currentVersion = 1;

    if (size < PageManager.pageSize) {
      final header = Uint8List(PageManager.pageSize);
      header[0] = 70; header[1] = 68; header[2] = 66; header[3] = 50; // "FDB2"
      _nextId = 1;
      _writeInt32(header, 12, _schemaVersion);
      await storage.write(0, header);
      await _primaryIndex.insert(0, 0);
      await _saveHeader();
    } else {
      final header = await storage.read(0, 25);
      if (header.length >= 4 && header[3] == 49) {
        throw StateError(
            'FastDB: Database format v1 (FDB1, no checksums) is not compatible '
            'with the current version (FDB2, CRC32 per document). '
            'Delete the database files to create a new database.');
      }
      _nextId = _readInt32(header, 8);
      _primaryIndex.rootPage = _readInt32(header, 4);
      currentVersion = _readInt32(header, 12);
      if (currentVersion == 0) currentVersion = 1;

      final lostIds = await _primaryIndex.rangeSearch(_nextId, 0x7FFFFFFF);
      if (lostIds.isNotEmpty) _nextId = lostIds.last + 1;

      final isClean = header.length >= 25 && header[24] == 0x43;
      if (isClean) {
        await _loadIndexes();
      } else {
        await _indexMgr.rebuildSecondaryIndexes();
      }

      if (storage.needsExplicitFlush) {
        await storage.write(24, Uint8List(1));
      }
    }

    if (dataStorage != null) {
      await dataStorage!.open();
      _dataOffset = await dataStorage!.size;
    } else {
      _dataOffset = await storage.size;
    }

    if (currentVersion < _schemaVersion) {
      await _runMigrations(currentVersion, _schemaVersion, migrations);
      await _saveHeader();
    }
  }

  /// Closes the database and releases all resources.
  Future<void> close() async {
    if (_isClosed) return; // Already closed
    _isClosed = true;
    
    await _saveIndexes();
    if (storage.needsExplicitFlush) {
      await storage.write(24, Uint8List(1)..[0] = 0x43);
    }
    await _saveHeader();
    await _pageManager.flushDirty();
    await storage.flush();
    await storage.close();
    await dataStorage?.flush();
    await dataStorage?.close();
    final watchersCopy = _watchers.values.toList();
    _watchers.clear();
    for (final c in watchersCopy) {
      await c.close();
    }
  }

  /// Flushes the header and all pending page writes to disk.
  Future<void> flush() async {
    await _saveHeader();
    await storage.flush();
    await dataStorage?.flush();
  }

  // ─── CRUD Operations ──────────────────────────────────────────────────────
  // Single-document create, read, update, delete operations.

  Future<int> insert(dynamic doc) => _exclusive(() => _crudOps.insertImpl(doc));

  /// Hive-style put with manual key.
  Future<void> put(int id, dynamic value) => _exclusive(() => _putImpl(id, value));

  Future<void> _putImpl(int id, dynamic value) => _crudOps.putImpl(id, value);

  // ─── Batch & Transaction Operations ────────────────────────────────────────
  // Bulk inserts, batch modes, and atomic transactions.

  Future<List<int>> insertAll(List<dynamic> docs) => _exclusive(() => _batchOps.insertAllImpl(docs));

  Future<void> beginBatch() async {
    _batchMode = true;
    _enableWriteBehind(); // Enable write-behind mode for faster B-Tree operations
  }

  Future<void> commitBatch() async {
    if (!_batchMode) return;

    final wal = _wal;
    final manageWal = !_inTransaction && wal != null;
    if (manageWal) await wal.beginTransaction();

    if (_batchEntries.isNotEmpty) {
      await _primaryIndex.bulkLoad(_batchEntries);
      _batchEntries.clear();
    }

    _batchMode = false;
    _disableWriteBehind(); // Disable write-behind mode
    await _pageManager.flushDirty();
    await dataStorage?.flush();
    await storage.flush();
    await _saveHeader();

    if (manageWal) await wal.commit();

    if (dataStorage == null) {
      _dataOffset = await storage.size;
    }

    for (final field in _watchers.keys) {
      final stream = _watchers[field];
      final idx = _secondaryIndexes[field];
      if (stream != null && idx != null) stream.add(idx.all());
    }
  }

  /// Updates specific fields of an existing document by ID.
  Future<bool> update(int id, Map<String, dynamic> fields) =>
      _exclusive(() => _crudOps.updateImpl(id, fields));

  /// Updates all documents matching [queryFn] with [fields] in a single atomic transaction.
  Future<int> updateWhere(
    List<int> Function(QueryBuilder q) queryFn,
    Map<String, dynamic> fields,
  ) => _exclusive(() async {
    final ids = List<int>.from(queryFn(QueryBuilder(_secondaryIndexes)));
    if (ids.isEmpty) return 0;
    final wal = _wal;
    _inTransaction = true;
    if (wal != null) await wal.beginTransaction();
    try {
      int updated = 0;
      for (final id in ids) {
        if (await _crudOps.updateImpl(id, fields)) updated++;
      }
      if (wal != null) await wal.commit();
      await _saveHeader();
      return updated;
    } catch (e) {
      if (wal != null) await wal.rollback();
      rethrow;
    } finally {
      _inTransaction = false;
    }
  });

  /// Executes [fn] as an atomic transaction.
  Future<T> transaction<T>(Future<T> Function() fn) {
    if (_inTransaction) {
      // BUG FIX: nested calls would corrupt savepoints and rollback state.
      // Callers should flatten all operations into a single transaction().
      throw StateError(
          'FastDB: Nested transactions are not supported. '
          'Flatten concurrent operations into a single transaction() call.');
    }
    return _exclusive(() async {
      _inTransaction = true;
      final wal = _wal;
      final savedNextId = _nextId;
      final savedDataOffset = _dataOffset;
      final savedRootPage = _primaryIndex.rootPage;
      try {
        if (wal != null) {
          await wal.beginTransaction();
          await beginBatch();
          final result = await fn();
          await commitBatch();
          await wal.commit();
          return result;
        } else {
          await beginBatch();
          final result = await fn();
          await commitBatch();
          return result;
        }
      } catch (e) {
        if (wal != null) await wal.rollback();
        _batchMode = false;
        _disableWriteBehind(); // BUG FIX: Ensure write-behind is disabled on rollback
        _batchEntries.clear(); // BUG FIX: Clear any pending batch entries
        _nextId = savedNextId;
        _dataOffset = savedDataOffset;
        _primaryIndex.rootPage = savedRootPage;
        _pageManager.clearLruCache();
        _pageManager.clearDirtyPages(); // BUG FIX: Clear dirty pages on rollback
        _primaryIndex.clearNodeCache();
        if (_secondaryIndexes.isNotEmpty) await _indexMgr.rebuildSecondaryIndexes();
        rethrow;
      } finally {
        _inTransaction = false;
      }
    });
  }

  // ─── Read Operations ──────────────────────────────────────────────────────

  /// Get by primary key — O(log n).
  Future<dynamic> findById(int id) async {
    if (_isClosed) {
      throw StateError(
        'Bad state: Cannot perform operations on a closed database. '
        'The database was closed before findById($id) could complete. '
        'Call ffastdb.init() or openDatabase() again to reopen.',
      );
    }
    
    // OPTIMIZATION: Try sync path first - nearly always succeeds with hot cache
    final syncOffset = _primaryIndex.searchSync(id);
    if (syncOffset != null) {
      if (dataStorage == null && syncOffset < PageManager.pageSize) return null;
      final syncDoc = _readAtSync(syncOffset);
      if (syncDoc != null) return syncDoc;
    }
    
    // Fallback to async path
    final offset = await _primaryIndex.search(id);
    if (offset == null) return null;
    if (dataStorage == null && offset < PageManager.pageSize) return null;
    
    // Try sync read for small offsets (recently written data likely in OS cache)
    if (offset < 100000) {
      final doc = _readAtSync(offset);
      if (doc != null) return doc;
    }
    
    return _readAt(offset);
  }

  /// Returns document IDs where primary key is in [low..high] range.
  Future<List<int>> rangeSearch(int low, int high) => _primaryIndex.rangeSearch(low, high);

  /// Hive-style get.
  Future<dynamic> get(int id) => findById(id);

  /// Find all documents matching a query.
  Future<List<dynamic>> find(List<int> Function(QueryBuilder q) queryFn) =>
      _queryOps.findImpl(queryFn);

  /// Returns a fluent [QueryBuilder] for chaining conditions.
  ///
  /// The returned builder has access to [QueryBuilder.find] and
  /// [QueryBuilder.findFirst] which resolve full documents without
  /// requiring a manual `findById` loop.
  QueryBuilder query() => QueryBuilder(_secondaryIndexes, findById);

  Future<List<dynamic>> findWhere(List<int> Function(QueryBuilder q) fn) => find(fn);

  /// Returns all documents in the database.
  Future<List<dynamic>> getAll() => _queryOps.getAllImpl();

  /// Returns the number of live documents.
  Future<int> count() => _queryOps.countImpl();

  /// Returns true if a document with the given [id] exists.
  Future<bool> exists(int id) => _queryOps.existsImpl(id);

  // ─── Aggregations ─────────────────────────────────────────────────────────

  Future<int> countWhere(List<int> Function(QueryBuilder q) queryFn) {
    return Future.value(queryFn(QueryBuilder(_secondaryIndexes)).length);
  }

  Future<num> sumWhere(
    List<int> Function(QueryBuilder q) queryFn,
    String field,
  ) async {
    final ids = queryFn(QueryBuilder(_secondaryIndexes));
    num total = 0;
    for (final id in ids) {
      final doc = await findById(id);
      if (doc is Map<String, dynamic>) {
        final v = doc[field];
        if (v is num) total += v;
      }
    }
    return total;
  }

  Future<double?> avgWhere(
    List<int> Function(QueryBuilder q) queryFn,
    String field,
  ) async {
    final ids = queryFn(QueryBuilder(_secondaryIndexes));
    if (ids.isEmpty) return null;
    num total = 0;
    int count = 0;
    for (final id in ids) {
      final doc = await findById(id);
      if (doc is Map<String, dynamic>) {
        final v = doc[field];
        if (v is num) { total += v; count++; }
      }
    }
    return count == 0 ? null : total / count;
  }

  Future<dynamic> minWhere(
    List<int> Function(QueryBuilder q) queryFn,
    String field,
  ) async {
    final ids = queryFn(QueryBuilder(_secondaryIndexes));
    dynamic min;
    for (final id in ids) {
      final doc = await findById(id);
      if (doc is Map<String, dynamic>) {
        final v = doc[field];
        if (v != null && (min == null || (v as Comparable).compareTo(min) < 0)) min = v;
      }
    }
    return min;
  }

  Future<dynamic> maxWhere(
    List<int> Function(QueryBuilder q) queryFn,
    String field,
  ) async {
    final ids = queryFn(QueryBuilder(_secondaryIndexes));
    dynamic max;
    for (final id in ids) {
      final doc = await findById(id);
      if (doc is Map<String, dynamic>) {
        final v = doc[field];
        if (v != null && (max == null || (v as Comparable).compareTo(max) > 0)) max = v;
      }
    }
    return max;
  }

  /// Lazy stream of documents matching [queryFn] — yields one at a time.
  Stream<dynamic> findStream(List<int> Function(QueryBuilder q) queryFn) async* {
    final ids = queryFn(QueryBuilder(_secondaryIndexes));
    for (final id in ids) {
      final doc = await findById(id);
      if (doc != null) yield doc;
    }
  }

  // ─── Reactive Watchers ────────────────────────────────────────────────────

  Stream<List<int>> watch(String field) {
    if (!_watchers.containsKey(field)) {
      // BUG FIX: use onCancel to remove the controller from _watchers once
      // all listeners unsubscribe, preventing StreamControllers from
      // accumulating indefinitely in long-running applications.
      late StreamController<List<int>> ctrl;
      ctrl = StreamController<List<int>>.broadcast(
        onCancel: () {
          if (!ctrl.hasListener) {
            ctrl.close();
            _watchers.remove(field);
          }
        },
      );
      _watchers[field] = ctrl;
    }
    return _watchers[field]!.stream;
  }

  void _notifyWatchers(dynamic doc) {
    if (doc is! Map<String, dynamic>) return;
    for (final field in _watchers.keys) {
      final stream = _watchers[field];
      if (stream == null) continue;
      final idx = _secondaryIndexes[field];
      if (idx != null) {
        stream.add(idx.all());
      } else {
        _primaryIndex.rangeSearch(1, _nextId - 1).then((ids) {
          if (!stream.isClosed) stream.add(ids);
        });
      }
    }
  }

  // ─── Internal Helpers ─────────────────────────────────────────────────────

  // Indexing & Document Management
  
  void _indexDocument(int id, Map<String, dynamic> doc) =>
      _indexMgr.indexDocument(id, doc);

  // Data Reading (Sync & Async Paths)
  
  dynamic _readAtSync(int offset) {
    if (offset < 0) return null;
    final targetStorage = dataStorage ?? storage;
    const int readAheadSize = 512;
    final chunk = targetStorage.readSync(offset, readAheadSize);
    if (chunk == null || chunk.length < 4) return null;
    final length = _readInt32(chunk, 0);
    if (length <= 0 || length > 10 * 1024 * 1024) return null;
    final int totalSize = 4 + length + 4;
    final Uint8List fullData;
    if (totalSize <= chunk.length) {
      fullData = chunk;
    } else {
      final full = targetStorage.readSync(offset, totalSize);
      if (full == null) return null;
      fullData = full;
    }
    if (fullData.length >= totalSize) {
      final storedCrc = _readInt32(fullData, 4 + length);
      if (storedCrc != _crc32(fullData.sublist(4, 4 + length))) return null;
    }
    final body = fullData.sublist(4, 4 + length);
    if (body.isNotEmpty && (body[0] == 123 || body[0] == 91)) {
      final doc = FastSerializer.deserialize(fullData);
      // Restore original 'id' field if it was preserved (e.g., from Firebase)
      if (doc.containsKey('_originalId')) {
        doc['id'] = doc.remove('_originalId');
      }
      return doc;
    }
    final reader = FastBinaryReader(body);
    final doc = _registry.read(reader);
    // Restore original 'id' field if it was preserved (e.g., from Firebase)
    if (doc is Map && doc.containsKey('_originalId')) {
      doc['id'] = doc.remove('_originalId');
    }
    return doc;
  }

  Future<dynamic> _readAt(int offset) async {
    if (offset < 0) return null;
    if (dataStorage == null && offset < PageManager.pageSize) return null;
    final targetStorage = dataStorage ?? storage;
    const int readAheadSize = 512;
    final chunk = await targetStorage.read(offset, readAheadSize);
    if (chunk.length < 4) return null;
    final length = _readInt32(chunk, 0);
    if (length <= 0) return null;
    if (length > 10 * 1024 * 1024) {
      throw StateError(
          'FastDB: Document at offset $offset has length $length bytes '
          '(exceeds 10 MB). This likely indicates file corruption.');
    }
    // BUG FIX: read 4 extra bytes for the trailing CRC32 checksum.
    final int totalSize = 4 + length + 4;
    final Uint8List fullData;
    if (totalSize <= chunk.length) {
      fullData = chunk;
    } else {
      fullData = await targetStorage.read(offset, totalSize);
    }
    // Verify CRC — same check as the sync path (_readAtSync).
    if (fullData.length >= totalSize) {
      final storedCrc = _readInt32(fullData, 4 + length);
      if (storedCrc != _crc32(fullData.sublist(4, 4 + length))) return null;
    }
    final body = fullData.sublist(4, 4 + length);
    if (body.isNotEmpty && (body[0] == 123 || body[0] == 91)) {
      final doc = FastSerializer.deserialize(fullData);
      // Restore original 'id' field if it was preserved (e.g., from Firebase)
      if (doc.containsKey('_originalId')) {
        doc['id'] = doc.remove('_originalId');
      }
      return doc;
    }
    final reader = FastBinaryReader(body);
    final doc = _registry.read(reader);
    // Restore original 'id' field if it was preserved (e.g., from Firebase)
    if (doc is Map && doc.containsKey('_originalId')) {
      doc['id'] = doc.remove('_originalId');
    }
    return doc;
  }

  // Serialization & Encoding
  
  Uint8List _serialize(dynamic doc, {int? id}) {
    final Uint8List payload;
    if (doc is Map) {
      Map<String, dynamic> map;
      final docMap = doc as Map<String, dynamic>;
      
      // OPTIMIZATION: Avoid Map.from() copy if we don't need to modify
      if (id != null && docMap['id'] != id) {
        map = Map<String, dynamic>.from(docMap);
        // Preserve original 'id' field (e.g., from Firebase) before overwriting
        if (docMap.containsKey('id')) {
          map['_originalId'] = docMap['id'];
        }
        map['id'] = id;
      } else {
        map = docMap;
      }
      
      payload = FastSerializer.serialize(map);
    } else if (_registry.getTypeId(doc.runtimeType) != null) {
      // Registered TypeAdapter path — fast binary format.
      final writer = FastBinaryWriter();
      _registry.write(writer, doc);
      final body = writer.result;
      final tmp = Uint8List(4 + body.length);
      tmp[0] = body.length & 0xFF;
      tmp[1] = (body.length >> 8) & 0xFF;
      tmp[2] = (body.length >> 16) & 0xFF;
      tmp[3] = (body.length >> 24) & 0xFF;
      tmp.setRange(4, 4 + body.length, body);
      payload = tmp;
    } else {
      // No TypeAdapter registered — fall back to JSON so the data is always
      // recoverable. Try toJson() first (model classes), then toString().
      Map<String, dynamic> map;
      try {
        final json = (doc as dynamic).toJson();
        map = Map<String, dynamic>.from(json as Map);
      } catch (_) {
        map = {'value': doc.toString(), 'runtimeType': doc.runtimeType.toString()};
      }
      // Preserve original 'id' field (e.g., from Firebase) before overwriting
      if (id != null) {
        if (map.containsKey('id') && map['id'] != id) {
          map['_originalId'] = map['id'];
        }
        map['id'] = id;
      }
      payload = FastSerializer.serialize(map);
    }
    final bodySlice = payload.sublist(4);
    final crc = _crc32(bodySlice);
    final result = Uint8List(payload.length + 4);
    result.setRange(0, payload.length, payload);
    result[payload.length]     = crc & 0xFF;
    result[payload.length + 1] = (crc >> 8) & 0xFF;
    result[payload.length + 2] = (crc >> 16) & 0xFF;
    result[payload.length + 3] = (crc >> 24) & 0xFF;
    return result;
  }

  // Storage Management (Headers, Indexes, Persistence)
  
  Future<void> _saveHeader() => _storageMgr.saveHeader();

  // ─── Index Persistence ─────────────────────────────────────────────────────

  Future<void> _saveIndexes() => _storageMgr.saveIndexes();

  Future<void> _loadIndexes() => _storageMgr.loadIndexes();

  // ─── Delete ────────────────────────────────────────────────────────────────

  Future<bool> delete(int id) => _exclusive(() => _crudOps.deleteImpl(id));

  /// Count of documents deleted or overwritten since last compact().
  /// Used by auto-compact threshold logic. A `Set<int>` was previously used here
  /// but caused unbounded memory growth under heavy delete/update loads.
  int _deletedCount = 0;

  /// Deletes all documents matching [queryFn] in a single atomic transaction.
  Future<int> deleteWhere(List<int> Function(QueryBuilder q) queryFn) =>
      _exclusive(() async {
        final ids = List<int>.from(queryFn(QueryBuilder(_secondaryIndexes)));
        if (ids.isEmpty) return 0;
        final wal = _wal;
        _inTransaction = true;
        if (wal != null) await wal.beginTransaction();
        try {
          int count = 0;
          for (final id in ids) {
            if (await _crudOps.deleteImpl(id)) count++;
          }
          if (wal != null) await wal.commit();
          await _saveHeader();
          return count;
        } catch (e) {
          if (wal != null) await wal.rollback();
          rethrow;
        } finally {
          _inTransaction = false;
        }
      });

  Future<void> _maybeAutoCompact() => _storageMgr.maybeAutoCompact();

  // ─── Compact (Vacuum) ──────────────────────────────────────────────────────

  Future<void> compact() => _exclusive(() => _storageMgr.compactImpl());

  // ─── Migrations ────────────────────────────────────────────────────────────

  Future<void> _runMigrations(
      int currentVersion, int targetVersion, Map<int, dynamic Function(dynamic)>? migrations) =>
      _storageMgr.runMigrations(currentVersion, targetVersion, migrations);

  // ─── Header Utils ──────────────────────────────────────────────────────────

  int _readInt32(Uint8List b, int off) =>
      (b[off] & 0xFF) | ((b[off + 1] & 0xFF) << 8) |
      ((b[off + 2] & 0xFF) << 16) | ((b[off + 3] & 0xFF) << 24);

  void _writeInt32(Uint8List b, int off, int v) {
    b[off] = v & 0xFF;
    b[off + 1] = (v >> 8) & 0xFF;
    b[off + 2] = (v >> 16) & 0xFF;
    b[off + 3] = (v >> 24) & 0xFF;
  }

  static int _crc32(Uint8List data) {
    int crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc ^= byte;
      for (int i = 0; i < 8; i++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
      }
    }
    return crc ^ 0xFFFFFFFF;
  }
}

/// Canonical public alias for [FastDB].
typedef FfastDb = FastDB;
