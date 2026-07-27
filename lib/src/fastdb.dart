import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:typed_data';
import 'package:meta/meta.dart';
import 'storage/storage_strategy.dart';
import 'storage/page_manager.dart';
import 'storage/wal_storage_strategy.dart';
import 'storage/encrypted_storage_strategy.dart';
import 'index/btree.dart';
import 'index/hash_index.dart';
import 'index/sorted_index.dart';
import 'index/bitmask_index.dart';
import 'index/composite_index.dart';
import 'index/fts_index.dart';
import 'query/fast_query.dart';
import 'query/query_cache.dart';
import 'serialization/fast_serializer.dart';
import 'serialization/type_adapter.dart';
import 'serialization/type_registry.dart';
import 'index/secondary_index.dart';
import 'serialization/binary_io.dart';
import 'crc32.dart' as crc;
import 'storage/operation_log.dart'
    if (dart.library.js_interop) 'storage/operation_log_web.dart';
import 'storage/io/io_storage_strategy.dart';

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
  final String? name;
  static bool debugQueryPlan = false;
  late PageManager _pageManager;
  late final BTree _primaryIndex;
  final TypeRegistry _registry = TypeRegistry();
  final Map<String, SecondaryIndex> _secondaryIndexes = {};

  /// Per-instance query cache. Injected into every [QueryBuilder] this
  /// database creates, and cleared on every write. Being per-instance (not
  /// static) prevents cached results from leaking between FastDB instances
  /// that run textually identical queries.
  final QueryCache _queryCache = QueryCache(maxSize: 256);

  // Reactive watchers: field → StreamController
  final Map<String, StreamController<List<int>>> _watchers = {};

  late final OperationLog _opLog;

  bool _batchMode = false;
  bool _inTransaction = false;
  int _nextId = 1;

  /// True while replaying the operation log at open() — replayed operations
  /// must not be logged again (nor checkpoint the log they are reading).
  bool _isReplayingOpLog = false;

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
        'Bad state: Cannot perform operations on a closed database'
        '${name != null ? " \"$name\"" : ""}.',
      );
    }
    if (_inTransaction) return fn();
    final next = _writeLock.then((_) async {
      if (_isClosed) {
        throw StateError(
          'Bad state: Cannot perform operations on a closed database'
          '${name != null ? " \"$name\"" : ""}.',
        );
      }
      // Synchronize data offset before every exclusive operation to ensure
      // B-Tree page allocations and document writes don't overlap.
      if (dataStorage == null) {
        _dataOffset = storage.sizeSync ?? await storage.size;
      }
      return await fn();
    });
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
  late final IndexManager _indexMgr;
  late final _StorageManager _storageMgr;

  /// Returns the [WalStorageStrategy] in the storage stack, if any.
  ///
  /// The stack may be wrapped (e.g. `EncryptedStorageStrategy(WalStorageStrategy(...))`),
  /// so we unwrap layers — same traversal as the `_opLog` path resolution in the
  /// constructor. Without this, an encrypted WAL was silently not detected:
  /// every internal write opened its own auto-transaction (no atomicity, ~2.5x fsyncs).
  WalStorageStrategy? get _wal {
    StorageStrategy? current = storage;
    while (current != null) {
      if (current is WalStorageStrategy) return current;
      if (current is EncryptedStorageStrategy) {
        current = current.storage;
      } else {
        break;
      }
    }
    return null;
  }

  /// Access to index management and statistics.
  IndexManager get indexes => _indexMgr;

  /// Internal constructor used by factory constructors and singleton.
  FastDB._internal(
    this.storage, {
    this.dataStorage,
    int cacheCapacity = 2048,
    double autoCompactThreshold = 0,
    this.name,
  }) {
    _autoCompactThreshold = autoCompactThreshold;
    _pageManager = PageManager(storage, cacheCapacity: cacheCapacity);
    _primaryIndex = BTree(_pageManager);

    // Initialize sequential operation log.
    // Ensure the log is in the same directory as the main DB file.
    String? logPath;
    StorageStrategy? current = storage;
    while (current != null) {
      if (current is IoStorageStrategy) {
        logPath = '${current.path}.log';
        break;
      } else if (current is WalStorageStrategy) {
        current = current.main;
      } else if (current is EncryptedStorageStrategy) {
        current = current.storage;
      } else {
        break;
      }
    }
    _opLog = logPath == null ? OperationLog.disabled() : OperationLog(logPath);

    // Initialize helper classes for modularized operations
    _crudOps = _CrudOperations(this);
    _queryOps = _QueryOperations(this);
    _batchOps = _BatchOperations(this);
    _indexMgr = IndexManager(this);
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
  factory FastDB(
    StorageStrategy storage, {
    StorageStrategy? dataStorage,
    int cacheCapacity = 2048,
    double autoCompactThreshold = 0,
    String? name,
  }) {
    return FastDB._internal(
      storage,
      dataStorage: dataStorage,
      cacheCapacity: cacheCapacity,
      autoCompactThreshold: autoCompactThreshold,
      name: name,
    );
  }

  /// Constructor for testing purposes - directly creates a FastDB instance.
  /// **WARNING**: In production code, use [FfastDb.init()] instead.
  @visibleForTesting
  factory FastDB.forTesting(
    StorageStrategy storage, {
    StorageStrategy? dataStorage,
    int cacheCapacity = 2048,
    double autoCompactThreshold = 0,
    String? name,
  }) {
    return FastDB._internal(
      storage,
      dataStorage: dataStorage,
      cacheCapacity: cacheCapacity,
      autoCompactThreshold: autoCompactThreshold,
      name: name,
    );
  }

  // ─── Singleton ────────────────────────────────────────────────────────────

  static FastDB? _instance;

  /// The global singleton instance. Throws if [init()] has not been called yet.
  static FastDB get instance {
    if (_instance == null) {
      throw StateError(
        'FfastDb not initialized. Call `await FfastDb.init(storage)` first.',
      );
    }
    if (_instance!._isClosed) {
      throw StateError(
        'FfastDb instance has been closed. Call `await FfastDb.init(storage)` again.',
      );
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
    double autoCompactThreshold = 0,
    int version = 1,
    Map<int, dynamic Function(dynamic)>? migrations,
    List<String> indexes = const [],
    List<String> sortedIndexes = const [],
    List<String> ftsIndexes = const [],
    List<List<String>> compositeIndexes = const [],
    void Function(double)? onProgress,
    String? name,
  }) async {
    final db = FastDB._internal(
      storage,
      dataStorage: dataStorage,
      cacheCapacity: cacheCapacity,
      autoCompactThreshold: autoCompactThreshold,
      name: name,
    );
    // Register indexes BEFORE open() so that _loadIndexes() can match blobs
    // to their correct type, and the singleton is never exposed without indexes.
    for (final field in indexes) db.addIndex(field);
    for (final field in sortedIndexes) db.addSortedIndex(field);
    for (final field in ftsIndexes) db.addFtsIndex(field);
    for (final fields in compositeIndexes) db.addCompositeIndex(fields);

    await db.open(
      version: version,
      migrations: migrations,
      onProgress: onProgress,
    );
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
  void registerAdapter<T>(TypeAdapter<T> adapter) =>
      _indexMgr.registerAdapter(adapter);

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
    void Function(double)? onProgress,
  }) async {
    // Clear this instance's query cache when (re)opening.
    _queryCache.clear();

    _schemaVersion = version;
    await storage.open();
    await _opLog.open();

    if (!storage.needsExplicitFlush) _pageManager.writeBehind = true;

    final size = await storage.size;
    int currentVersion = 1;

    if (size < PageManager.pageSize) {
      final header = Uint8List(PageManager.pageSize);
      header[0] = 70;
      header[1] = 68;
      header[2] = 66;
      header[3] = 50; // "FDB2"
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
          'Delete the database files to create a new database.',
        );
      }
      _nextId = _readInt32(header, 8);
      _primaryIndex.rootPage = _readInt32(header, 4);
      currentVersion = _readInt32(header, 12);
      if (currentVersion == 0) currentVersion = 1;

      final lostIds = await _primaryIndex.rangeSearch(_nextId, 0x7FFFFFFF);
      if (lostIds.isNotEmpty) _nextId = lostIds.last + 1;

      final isClean = header.length >= 25 && header[24] == 0x43;
      if (isClean) {
        // Restore the free-page list (only trustworthy after a CLEAN shutdown;
        // a stale list after a crash could hand out live pages).
        await _pageManager.loadFreeList();
        final loadedKeys = await _loadIndexes();
        final missingKeys = _secondaryIndexes.keys
            .where((k) => !loadedKeys.contains(k))
            .toList();
        if (missingKeys.isNotEmpty) {
          // Some newly registered indexes weren't in the payload, rebuild them!
          await _indexMgr.rebuildSecondaryIndexes(onProgress: onProgress);
        }
      } else {
        await _indexMgr.rebuildSecondaryIndexes(onProgress: onProgress);
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

    // RECOVERY: Replay any pending operations from the sequential log.
    await _replayOpLog();
  }

  Future<void> _replayOpLog() async {
    final ops = await _opLog.readAll();
    if (ops.isEmpty) return;

    _isReplayingOpLog = true;
    try {
      for (final op in ops) {
        try {
          switch (op.type) {
            case 'insert':
              // Use put to ensure the same ID is reused if possible, or just insert
              if (op.id != null) {
                await _putImpl(op.id!, op.data);
              } else {
                await _crudOps.insertImpl(op.data);
              }
              break;
            case 'put':
              await _putImpl(op.id!, op.data);
              break;
            case 'update':
              await _crudOps.updateImpl(
                op.id!,
                op.data as Map<String, dynamic>,
              );
              break;
            case 'delete':
              await _crudOps.deleteImpl(op.id!);
              break;
          }
        } catch (_) {
          // Skip failed replays
        }
      }
    } finally {
      _isReplayingOpLog = false;
    }
    await _opLog.clear();
  }

  /// Closes the database and releases all resources.
  Future<void> close() async {
    if (_isClosed) return; // Already closed

    // Use the exclusive lock to ensure all pending writes are finished before closing.
    // We cannot use _exclusive() helper because it checks _isClosed.
    final next = _writeLock.then((_) async {
      if (_isClosed) return;
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
      // Clean shutdown: everything is durable — clear the operation log so
      // the next open() has nothing to replay (replays after a CLEAN close
      // would redo already-applied operations, clobbering e.g. migrations).
      await _opLog.clear();
      await _opLog.close();
      final watchersCopy = _watchers.values.toList();
      _watchers.clear();
      for (final c in watchersCopy) {
        await c.close();
      }

      if (identical(_instance, this)) {
        _instance = null;
      }
    });
    _writeLock = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// Flushes the header and all pending page writes to disk.
  Future<void> flush() async {
    await _saveHeader();
    await storage.flush();
    await dataStorage?.flush();
  }

  // ─── CRUD Operations ──────────────────────────────────────────────────────
  // Single-document create, read, update, delete operations.

  Future<int> insert(dynamic doc) {
    return _exclusive(() => _crudOps.insertImpl(doc));
  }

  /// Inserts if it does not exist, updates if it does. Atómico.
  /// Retorna el ID del documento (existente o nuevo).
  Future<int> upsert(int id, Map<String, dynamic> fields) =>
      _exclusive(() => _crudOps.upsertImpl(id, fields));

  /// Upsert basado en campo único (sin conocer el ID interno).
  Future<int> upsertWhere(
    String uniqueField,
    dynamic value,
    Map<String, dynamic> fields,
  ) => _exclusive(() => _crudOps.upsertWhereImpl(uniqueField, value, fields));

  /// Hive-style put with manual key.
  Future<void> put(int id, dynamic value) {
    return _exclusive(() => _putImpl(id, value));
  }

  Future<void> _putImpl(int id, dynamic value) => _crudOps.putImpl(id, value);

  // ─── Batch & Transaction Operations ────────────────────────────────────────
  // Bulk inserts, batch modes, and atomic transactions.

  Future<List<int>> insertAll(List<dynamic> docs) =>
      _exclusive(() => _batchOps.insertAllImpl(docs));

  Future<void> beginBatch() async {
    // Checkpoint pre-existing dirty pages FIRST. Rollback paths
    // (transaction/updateWhere/insertAll) discard the dirty pages of the
    // failed batch — they must contain ONLY batch writes, never earlier
    // committed state.
    await _pageManager.flushDirty();
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
    _disableWriteBehind();
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

  /// Updates all documents matching [queryFn].
  Future<int> updateWhere(
    FutureOr<List<int>> Function(QueryBuilder q) queryFn,
    Map<String, dynamic> fields,
  ) => _exclusive(() async {
    final ids = await queryFn(
      QueryBuilder(_secondaryIndexes, findById, rangeSearch, null, _queryCache),
    );
    if (ids.isEmpty) return 0;

    // Batch mode for massive updates
    final wasInBatch = _batchMode;
    if (!wasInBatch) {
      await beginBatch();
    }

    int updated = 0;
    try {
      int count = 0;
      for (final id in ids) {
        if (await _crudOps.updateImpl(id, fields)) updated++;
        count++;

        // On web, flush periodically to prevent IndexedDB chunk accumulation and memory overflow
        if (_runningOnWeb && count % 500 == 0) {
          final targetStorage = dataStorage ?? storage;
          await targetStorage.flush();
          if (dataStorage != null) await storage.flush();
          await Future.delayed(Duration.zero);
        }
      }
      if (!wasInBatch) {
        await commitBatch();
        if (_autoCompactThreshold > 0) {
          await _maybeAutoCompact();
        }
      } else {
        await _saveHeader();
      }
    } catch (e) {
      if (!wasInBatch) {
        _batchMode = false;
        _batchEntries.clear();
        _pageManager.writeBehind = false;
        // Discard dirty pages from the failed batch: otherwise the next
        // flushDirty() would write stale B-Tree pages on top of the state
        // restored by the WAL rollback.
        _pageManager.clearDirtyPages();
        _pageManager.clearLruCache();
        _primaryIndex.clearNodeCache();
        // Rollback WAL if necessary (handled by transaction if in transaction)
      }
      rethrow;
    }
    return updated;
  });

  /// Updates a single document by ID.
  Future<bool> update(int id, Map<String, dynamic> fields) {
    return _exclusive(() => _crudOps.updateImpl(id, fields));
  }

  /// Executes [fn] as an atomic transaction.
  Future<T> transaction<T>(Future<T> Function() fn) {
    if (_inTransaction) {
      // Join the outer transaction
      return fn();
    }
    return _exclusive(() async {
      _inTransaction = true;
      final savedNextId = _nextId;
      final savedRoot = _primaryIndex.rootPage;
      final wal = _wal;

      // Checkpoint pre-transaction dirty pages BEFORE opening the WAL tx:
      // they are committed state and must not join (and be lost with) a
      // possible rollback.
      await _pageManager.flushDirty();
      if (wal != null) await wal.beginTransaction();

      try {
        await beginBatch();
        final result = await fn();
        await commitBatch();
        if (wal != null) await wal.commit();
        return result;
      } catch (e) {
        _nextId = savedNextId;
        _primaryIndex.rootPage = savedRoot;
        if (wal != null) await wal.rollback();
        // Clear batch entries and CACHE on rollback to prevent them from leaking into next operations.
        // Dirty pages at this point are transaction-only (pre-tx state was
        // flushed before opening the tx) — safe to discard. LRU-cached pages
        // may hold post-tx reads — must be invalidated.
        _batchEntries.clear();
        _batchMode = false;
        _pageManager.clearDirtyPages();
        _pageManager.clearLruCache();
        _primaryIndex.clearNodeCache();
        _queryCache.clear();
        // Roll back SECONDARY indexes too: aborted operations already mutated
        // them eagerly. Rebuild from the restored primary index (rollback is
        // rare — correctness over speed here).
        await _indexMgr.rebuildSecondaryIndexes();
        rethrow;
      } finally {
        _inTransaction = false;
      }
    });
  }

  // ─── Read Operations ──────────────────────────────────────────────────────

  Future<dynamic> findById(int id) => _exclusive(() => _findById(id));

  Future<dynamic> _findById(int id) async {
    final offset = await _primaryIndex.search(id);
    if (offset != null) return _readAt(offset);
    // Read-your-writes in batch/transaction mode: pending inserts live in
    // _batchEntries until bulkLoad() at commit — they are not in the B-Tree yet.
    if (_batchEntries.isNotEmpty) {
      for (final e in _batchEntries) {
        if (e.key == id) return _readAt(e.value);
      }
    }
    return null;
  }

  /// Find all documents matching a query.
  Future<List<dynamic>> find(
    FutureOr<List<int>> Function(QueryBuilder q) queryFn,
  ) => _exclusive(() => _queryOps.findImpl(queryFn));

  /// Returns a fluent [QueryBuilder] for chaining conditions.
  ///
  /// The returned builder has access to [QueryBuilder.find] and
  /// [QueryBuilder.findFirst] which resolve full documents without
  /// requiring a manual `findById` loop.
  QueryBuilder query() => QueryBuilder(
    _secondaryIndexes,
    _findById,
    _rangeSearch,
    watch,
    _queryCache,
  );

  Future<List<dynamic>> findWhere(
    Future<List<int>> Function(QueryBuilder q) fn,
  ) => find(fn);

  /// Returns all documents in the database.
  Future<List<dynamic>> getAll() => _exclusive(() => _queryOps.getAllImpl());

  /// Carga múltiples documentos en paralelo. Preserva el orden de [ids].
  /// Los IDs no encontrados son omitidos del resultado.
  Future<List<dynamic>> findByIds(List<int> ids) =>
      _exclusive(() => _queryOps.findByIdsImpl(ids));

  /// Versión tipada de [findByIds].
  Future<List<T>> findByIdsCast<T>(List<int> ids) async {
    final docs = await findByIds(ids);
    return docs.cast<T>();
  }

  /// Returns the number of live documents.
  Future<int> count() => _exclusive(() => _queryOps.countImpl());

  /// Returns true if a document with the given [id] exists.
  Future<bool> exists(int id) => _exclusive(() => _queryOps.existsImpl(id));

  /// Returns all IDs where the primary key is between [low] and [high] (inclusive).
  Future<List<int>> rangeSearch(int low, int high) =>
      _exclusive(() => _rangeSearch(low, high));

  Future<List<int>> _rangeSearch(int low, int high) =>
      _primaryIndex.rangeSearch(low, high);

  // ─── Aggregations ─────────────────────────────────────────────────────────

  Future<int> countWhere(
    FutureOr<List<int>> Function(QueryBuilder q) queryFn,
  ) => _exclusive(
    () async => (await queryFn(
      QueryBuilder(
        _secondaryIndexes,
        _findById,
        _rangeSearch,
        null,
        _queryCache,
      ),
    )).length,
  );

  Future<num> sumWhere(
    FutureOr<List<int>> Function(QueryBuilder q) queryFn,
    String field,
  ) => _exclusive(() async {
    final ids = await queryFn(
      QueryBuilder(
        _secondaryIndexes,
        _findById,
        _rangeSearch,
        null,
        _queryCache,
      ),
    );
    num total = 0;
    final idx = _secondaryIndexes[field];
    if (idx != null) {
      for (final id in ids) {
        final v = idx.valueOf(id);
        if (v is num) total += v;
      }
      return total;
    }
    for (final id in ids) {
      final doc = await _findById(id);
      if (doc is Map<String, dynamic>) {
        final v = doc[field];
        if (v is num) total += v;
      }
    }
    return total;
  });

  Future<double?> avgWhere(
    FutureOr<List<int>> Function(QueryBuilder q) queryFn,
    String field,
  ) => _exclusive(() async {
    final ids = await queryFn(
      QueryBuilder(
        _secondaryIndexes,
        _findById,
        _rangeSearch,
        null,
        _queryCache,
      ),
    );
    if (ids.isEmpty) return null;
    num total = 0;
    int count = 0;
    final idx = _secondaryIndexes[field];
    if (idx != null) {
      for (final id in ids) {
        final v = idx.valueOf(id);
        if (v is num) {
          total += v;
          count++;
        }
      }
      return count == 0 ? null : total / count;
    }
    for (final id in ids) {
      final doc = await _findById(id);
      if (doc is Map<String, dynamic>) {
        final v = doc[field];
        if (v is num) {
          total += v;
          count++;
        }
      }
    }
    return count == 0 ? null : total / count;
  });

  Future<dynamic> minWhere(
    FutureOr<List<int>> Function(QueryBuilder q) queryFn,
    String field,
  ) => _exclusive(() async {
    final ids = await queryFn(
      QueryBuilder(
        _secondaryIndexes,
        _findById,
        _rangeSearch,
        null,
        _queryCache,
      ),
    );
    dynamic min;
    final idx = _secondaryIndexes[field];
    if (idx != null) {
      for (final id in ids) {
        final v = idx.valueOf(id);
        if (v != null &&
            (min == null || (v as Comparable).compareTo(min) < 0)) {
          min = v;
        }
      }
      return min;
    }
    for (final id in ids) {
      final doc = await _findById(id);
      if (doc is Map<String, dynamic>) {
        final v = doc[field];
        if (v != null && (min == null || (v as Comparable).compareTo(min) < 0))
          min = v;
      }
    }
    return min;
  });

  Future<dynamic> maxWhere(
    FutureOr<List<int>> Function(QueryBuilder q) queryFn,
    String field,
  ) => _exclusive(() async {
    final ids = await queryFn(
      QueryBuilder(
        _secondaryIndexes,
        _findById,
        _rangeSearch,
        null,
        _queryCache,
      ),
    );
    dynamic max;
    final idx = _secondaryIndexes[field];
    if (idx != null) {
      for (final id in ids) {
        final v = idx.valueOf(id);
        if (v != null &&
            (max == null || (v as Comparable).compareTo(max) > 0)) {
          max = v;
        }
      }
      return max;
    }
    for (final id in ids) {
      final doc = await _findById(id);
      if (doc is Map<String, dynamic>) {
        final v = doc[field];
        if (v != null && (max == null || (v as Comparable).compareTo(max) > 0))
          max = v;
      }
    }
    return max;
  });

  /// Lazy stream of documents matching [queryFn] — yields one at a time.
  Stream<dynamic> findStream(
    FutureOr<List<int>> Function(QueryBuilder q) queryFn,
  ) async* {
    if (_isClosed)
      throw StateError('Cannot perform operations on a closed database.');
    final ids = await queryFn(
      QueryBuilder(
        _secondaryIndexes,
        _findById,
        _rangeSearch,
        null,
        _queryCache,
      ),
    );
    for (final id in ids) {
      final doc = await _findById(id);
      if (doc != null) yield doc;
    }
  }

  // ─── Reactive Watchers ────────────────────────────────────────────────────

  Stream<List<int>> watch(String field) async* {
    // 1. Emit current state immediately
    final idx = _secondaryIndexes[field];
    if (idx != null) {
      yield idx.all();
    } else {
      yield await _primaryIndex.rangeSearch(1, _nextId - 1);
    }

    // 2. Yield future updates from the broadcast controller
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
    yield* _watchers[field]!.stream;
  }

  /// Stream de documentos completos cuando el campo indexado cambia.
  Stream<List<dynamic>> watchDocs(String field) =>
      watch(field).asyncMap((ids) => findByIds(ids));

  /// Versión tipada de [watchDocs].
  Stream<List<T>> watchDocsCast<T>(String field) =>
      watchDocs(field).map((docs) => docs.cast<T>());

  void _notifyWatchers(dynamic doc) {
    if (_batchMode) return;
    if (doc is Map<String, dynamic>) {
      // Notify only watchers whose field was modified in doc,
      // or if it has a nested/dot field whose prefix field was modified
      for (final field in _watchers.keys) {
        bool shouldNotify = false;
        // '' is the wildcard used by QueryBuilder.watch() with no conditions:
        // it must be notified on EVERY write.
        if (field.isEmpty || doc.containsKey(field)) {
          shouldNotify = true;
        } else if (field.contains('.')) {
          final rootField = field.split('.').first;
          if (doc.containsKey(rootField)) {
            shouldNotify = true;
          }
        }
        if (shouldNotify) {
          final stream = _watchers[field];
          final idx = _secondaryIndexes[field];
          if (stream != null && idx != null) {
            stream.add(idx.all());
          } else if (stream != null) {
            _primaryIndex.rangeSearch(1, _nextId - 1, skipDedupe: true).then((
              ids,
            ) {
              if (!stream.isClosed) stream.add(ids);
            });
          }
        }
      }
    } else {
      _notifyWatchersBatch();
    }
  }

  void _notifyWatchersBatch() {
    for (final field in _watchers.keys) {
      final stream = _watchers[field];
      if (stream == null) continue;
      final idx = _secondaryIndexes[field];
      if (idx != null) {
        stream.add(idx.all());
      } else {
        _primaryIndex.rangeSearch(1, _nextId - 1, skipDedupe: true).then((ids) {
          if (!stream.isClosed) stream.add(ids);
        });
      }
    }
  }

  // ─── Internal Helpers ─────────────────────────────────────────────────────

  // Indexing & Document Management

  void _indexDocument(int id, Map<String, dynamic> doc) =>
      _indexMgr.indexDocument(id, doc);

  void _removeDocument(int id, Map<String, dynamic> doc) =>
      _indexMgr.removeDocument(id, doc);

  // Data Reading (Async Path)

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
        '(exceeds 10 MB). This likely indicates file corruption.',
      );
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

    // Migration helper for backwards compatibility
    void migrateLegacyDoc(Map<dynamic, dynamic> doc) {
      if (!doc.containsKey('ffdbID') && doc.containsKey('id')) {
        doc['ffdbID'] = doc['id'];
        if (doc.containsKey('_originalId')) {
          doc['id'] = doc.remove('_originalId');
        } else {
          doc.remove('id');
        }
      }
    }

    // 1. New format: magic prefix [0x00, 0x01]
    if (body.length >= 2 && body[0] == 0x00 && body[1] == 0x01) {
      final doc = FastSerializer.deserialize(body);
      migrateLegacyDoc(doc);
      return doc;
    }

    // 2. Legacy format: starts with '{' (123) or '[' (91)
    if (body.isNotEmpty && (body[0] == 123 || body[0] == 91)) {
      try {
        final jsonStr = utf8.decode(body);
        final raw = jsonDecode(jsonStr) as Map<String, dynamic>;
        final doc = FastSerializer.revive(raw) as Map<String, dynamic>;
        migrateLegacyDoc(doc);
        return doc;
      } catch (_) {}
    }
    final reader = FastBinaryReader(body);
    final doc = _registry.read(reader);
    // Restore original 'id' field if it was preserved (e.g., from Firebase)
    if (doc is Map) migrateLegacyDoc(doc);
    return doc;
  }

  // Serialization & Encoding

  Uint8List _serialize(dynamic doc, {int? id}) {
    final Uint8List payload;
    if (doc is Map) {
      // Copy ONLY when we must inject ffdbID (the old code copied
      // unconditionally AND then again conditionally — the "optimization"
      // was broken). When no injection is needed, pass the map straight to
      // the serializer (it only reads).
      final Map<String, dynamic> map;
      if (id != null && doc['ffdbID'] != id) {
        map = Map<String, dynamic>.from(doc)..['ffdbID'] = id;
      } else {
        map = doc.cast<String, dynamic>();
      }

      payload = FastSerializer.serialize(map);
    } else if (_registry.getTypeId(doc.runtimeType) != null) {
      // Registered TypeAdapter path — fast binary format.
      final writer = FastBinaryWriter();
      _registry.write(writer, doc);
      payload = writer.result;
    } else {
      // No TypeAdapter registered — fall back to JSON.
      Map<String, dynamic> map;
      try {
        final json = (doc as dynamic).toJson();
        map = Map<String, dynamic>.from(json as Map);
      } catch (_) {
        map = {
          'value': doc.toString(),
          'runtimeType': doc.runtimeType.toString(),
        };
      }
      if (id != null) {
        map['ffdbID'] = id;
      }
      payload = FastSerializer.serialize(map);
    }

    final result = Uint8List(4 + payload.length + 4);
    _writeInt32(result, 0, payload.length);
    result.setRange(4, 4 + payload.length, payload);
    final crc = _crc32(payload);
    _writeInt32(result, 4 + payload.length, crc);
    return result;
  }

  // Storage Management (Headers, Indexes, Persistence)

  Future<void> _saveHeader() => _storageMgr.saveHeader();

  // ─── Index Persistence ─────────────────────────────────────────────────────

  Future<void> _saveIndexes() => _storageMgr.saveIndexes();

  Future<Set<String>> _loadIndexes() => _storageMgr.loadIndexes();

  // ─── Delete ────────────────────────────────────────────────────────────────

  Future<bool> delete(int id) {
    return _exclusive(() => _crudOps.deleteImpl(id));
  }

  /// Count of documents deleted or overwritten since last compact().
  /// Used by auto-compact threshold logic. A `Set<int>` was previously used here
  /// but caused unbounded memory growth under heavy delete/update loads.
  int _deletedCount = 0;

  /// Deletes all documents matching [queryFn] in a single atomic transaction.
  Future<int> deleteWhere(
    FutureOr<List<int>> Function(QueryBuilder q) queryFn,
  ) => _exclusive(() async {
    final ids = List<int>.from(
      await queryFn(
        QueryBuilder(
          _secondaryIndexes,
          _findById,
          _rangeSearch,
          null,
          _queryCache,
        ),
      ),
    );
    if (ids.isEmpty) return 0;
    final wal = _wal;
    _inTransaction = true;
    _batchMode = true; // Use batch mode to avoid redundant disk writes per item
    // Checkpoint pre-existing dirty pages BEFORE opening the WAL tx
    // (same reasoning as in transaction()).
    await _pageManager.flushDirty();
    if (wal != null) await wal.beginTransaction();
    try {
      int count = 0;
      for (int i = 0; i < ids.length; i++) {
        if (await _crudOps.deleteImpl(ids[i])) count++;
        if (_runningOnWeb && count % 500 == 0) {
          await storage.flush();
          await Future.delayed(Duration.zero);
        }
      }
      if (wal != null) await wal.commit();
      _batchMode = false;
      await _pageManager.flushDirty();
      await storage.flush();
      await _saveHeader();
      _queryCache.clear();
      if (_autoCompactThreshold > 0) {
        await _maybeAutoCompact();
      }
      return count;
    } catch (e) {
      _batchMode = false;
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
    int currentVersion,
    int targetVersion,
    Map<int, dynamic Function(dynamic)>? migrations,
  ) => _storageMgr.runMigrations(currentVersion, targetVersion, migrations);

  // ─── Header Utils ──────────────────────────────────────────────────────────

  int _readInt32(Uint8List b, int off) =>
      (b[off] & 0xFF) |
      ((b[off + 1] & 0xFF) << 8) |
      ((b[off + 2] & 0xFF) << 16) |
      ((b[off + 3] & 0xFF) << 24);

  void _writeInt32(Uint8List b, int off, int v) {
    b[off] = v & 0xFF;
    b[off + 1] = (v >> 8) & 0xFF;
    b[off + 2] = (v >> 16) & 0xFF;
    b[off + 3] = (v >> 24) & 0xFF;
  }

  static int _crc32(Uint8List data) => crc.crc32(data);

  /// Synchronizes the document write pointer with the actual storage size.
  /// Crucial for single-file mode where docs and pages share the same file.
  Future<void> _syncDataOffset(int writtenLength) async {
    if (dataStorage == null) {
      _dataOffset = storage.sizeSync ?? await storage.size;
    } else {
      _dataOffset += writtenLength;
    }
  }
}

/// Canonical public alias for [FastDB].
typedef FfastDb = FastDB;
