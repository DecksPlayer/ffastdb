import 'dart:async';
import 'dart:convert';
import 'dart:collection';
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
import 'index/parallel_indexer.dart';
import 'query/fast_query.dart';
import 'query/query_cache.dart';
import 'serialization/document_codec.dart';
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
part '_json_operations.dart';

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

  /// Path of the operation log written by ffastdb <= 0.3.5, deleted at open()
  /// (see [deleteLegacyOperationLog]). Null when not backed by a file.
  String? _legacyLogPath;

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

  /// Zone key under which [_runTransaction] publishes its [_txToken].
  static final Object _txZoneKey = Object();

  /// Identity of the open transaction (null when none is open). Only code
  /// running inside that transaction's zone — the transaction body and every
  /// async continuation it spawns — may skip the lock; any other caller
  /// queues behind the transaction. A plain `_inTransaction` check let
  /// unrelated callers run INSIDE someone else's transaction (and be rolled
  /// back with it).
  Object? _txToken;

  bool get _inOwnTransaction =>
      _txToken != null && identical(Zone.current[_txZoneKey], _txToken);

  /// On-disk state of the clean flag (header byte 24 == 0x43): the persisted
  /// secondary-index blob and free-page list match the data, so the next
  /// open() can load them instead of rebuilding every index. Cleared —
  /// durably, before the data changes — by the first write after a clean
  /// point ([_beforeWrite]); set again by [flush] and [close].
  bool _cleanOnDisk = false;

  /// Like [_exclusive], for operations that modify the database.
  Future<T> _exclusiveWrite<T>(Future<T> Function() fn) =>
      _exclusive(() async {
        await _beforeWrite();
        return fn();
      });

  /// Marks the file dirty before its first modification since the last
  /// clean point. The old code did this unconditionally in open(), so even a
  /// read-only session that crashed forced a full reindex on the next start.
  Future<void> _beforeWrite() async {
    if (!_cleanOnDisk) return;
    _cleanOnDisk = false;
    await storage.write(24, Uint8List(1));
  }

  /// Persists the secondary indexes, header and free list, then sets the
  /// clean flag — atomically when a WAL is present (one transaction).
  Future<void> _persistCleanState() async {
    await dataStorage?.flush(); // documents durable before the flag says so
    final wal = _wal;
    if (wal != null) await wal.beginTransaction();
    try {
      await _saveIndexes();
      await _saveHeader();
      await _pageManager.flushDirty();
      if (storage.needsExplicitFlush) {
        await storage.write(24, Uint8List(1)..[0] = 0x43);
      }
      if (wal != null) await wal.commit();
    } catch (_) {
      if (wal != null) await wal.rollback();
      rethrow;
    }
    await storage.flush();
    _cleanOnDisk = storage.needsExplicitFlush;
  }

  Future<T> _exclusive<T>(Future<T> Function() fn) {
    if (_isClosed) {
      throw StateError(
        'Bad state: Cannot perform operations on a closed database'
        '${name != null ? " \"$name\"" : ""}.',
      );
    }
    if (_inOwnTransaction) return fn();
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

  /// Number of live documents, maintained incrementally once known; null
  /// until first needed ([_countLive] computes it with one B-Tree scan), so
  /// it costs nothing for apps that never call count().
  int? _liveCount;

  void _adjustLiveCount(int delta) {
    final c = _liveCount;
    if (c != null) _liveCount = c + delta;
  }

  /// O(1) after the first call. Pending batch inserts are not in the B-Tree
  /// yet ([_batchEntries]) but are live documents.
  Future<int> _countLive() async => _liveCount ??=
      (await _primaryIndex.rangeSearch(1, _nextId - 1)).length + _batchEntries.length;

  // Helper classes for modularized operations
  late final _CrudOperations _crudOps;
  late final _QueryOperations _queryOps;
  late final _BatchOperations _batchOps;
  late final IndexManager _indexMgr;
  late final _StorageManager _storageMgr;
  late final _JsonOperations _jsonOps;

  /// Returns the [WalStorageStrategy] in the storage stack, if any.
  ///
  /// The stack may be wrapped (e.g. `EncryptedStorageStrategy(WalStorageStrategy(...))`),
  /// so we unwrap layers via [StorageStrategy.innerStorage] — same traversal as
  /// the legacy log path resolution in the constructor. Without this, a wrapped
  /// WAL is silently not detected: every internal write opens its own
  /// auto-transaction (no atomicity, ~2.5x fsyncs, non-atomic compact()).
  WalStorageStrategy? get _wal {
    StorageStrategy? current = storage;
    while (current != null) {
      if (current is WalStorageStrategy) return current;
      current = current.innerStorage;
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

    // Locate a leftover operation log from ffastdb <= 0.3.5 (next to the
    // main DB file) so open() can delete it.
    StorageStrategy? current = storage;
    while (current != null) {
      if (current is IoStorageStrategy) {
        _legacyLogPath = '${current.path}.log';
        break;
      }
      current = current.innerStorage;
    }

    // Initialize helper classes for modularized operations
    _crudOps = _CrudOperations(this);
    _queryOps = _QueryOperations(this);
    _batchOps = _BatchOperations(this);
    _indexMgr = IndexManager(this);
    _storageMgr = _StorageManager(this);
    _jsonOps = _JsonOperations(this);
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
  /// [batchSize] controls how many documents are fetched concurrently per
  /// iteration (default 32). Increase for faster storage, decrease for
  /// memory-constrained environments.
  Future<void> reindex({String? field, int batchSize = 32}) =>
      _indexMgr.reindex(field: field, batchSize: batchSize);

  // ─── Open / Close ─────────────────────────────────────────────────────────

  Future<void> open({
    int version = 1,
    Map<int, dynamic Function(dynamic)>? migrations,
    void Function(double)? onProgress,
  }) async {
    // Clear this instance's query cache when (re)opening.
    _queryCache.clear();
    _liveCount = null;
    _cleanOnDisk = false;

    _schemaVersion = version;
    await storage.open();
    // Before anything reads documents: an index rebuild below reads them
    // from dataStorage (it used to be opened only after that rebuild).
    await dataStorage?.open();
    final legacyLog = _legacyLogPath;
    if (legacyLog != null) await deleteLegacyOperationLog(legacyLog);

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
          // Rebuild ONLY newly added/missing indexes, keeping pre-loaded indexes in RAM
          for (final key in missingKeys) {
            await _indexMgr.reindex(field: key);
          }
        }
        // The flag stays set until the first write ([_beforeWrite]).
        _cleanOnDisk = true;
      } else {
        await _indexMgr.rebuildSecondaryIndexes(onProgress: onProgress);
        // Persist the rebuilt indexes right away: another crash before the
        // next clean close would otherwise force the same full rebuild.
        if (storage.needsExplicitFlush && _secondaryIndexes.isNotEmpty) {
          await _persistCleanState();
        }
      }
    }

    if (dataStorage != null) {
      _dataOffset = await dataStorage!.size;
    } else {
      _dataOffset = await storage.size;
    }

    if (currentVersion < _schemaVersion) {
      // Migrations + version bump must be ATOMIC. Previously the header was
      // saved only after runMigrations() completed, so a crash mid-migration
      // re-ran the ENTIRE migration on the next open — applying
      // non-idempotent migrations (counters, increments) twice to the docs
      // that had already been migrated. Wrapping in a transaction makes it
      // all-or-nothing: the WAL either commits every migrated doc plus the
      // new version header, or rolls back to the pre-migration state and the
      // next open retries cleanly from scratch.
      await transaction(() async {
        await _runMigrations(currentVersion, _schemaVersion, migrations);
        await _saveHeader();
      });
    }
  }

  /// Closes the database and releases all resources.
  Future<void> close() async {
    if (_isClosed) return; // Already closed

    // Use the exclusive lock to ensure all pending writes are finished before closing.
    // We cannot use _exclusive() helper because it checks _isClosed.
    final next = _writeLock.then((_) async {
      if (_isClosed) return;
      _isClosed = true;

      // Best-effort close: if any durability step fails (e.g. ENOSPC), we
      // still MUST release the storage locks/handles below — otherwise the
      // file stays locked until process exit and even this process cannot
      // reopen the database. The original error is rethrown afterwards so
      // callers know the last writes may not be durable.
      Object? closeError;
      try {
        await _persistCleanState();
      } catch (e) {
        closeError = e;
      } finally {
        try {
          await storage.close();
        } catch (_) {}
        try {
          await dataStorage?.flush();
          await dataStorage?.close();
        } catch (_) {}
        final watchersCopy = _watchers.values.toList();
        _watchers.clear();
        for (final c in watchersCopy) {
          try {
            await c.close();
          } catch (_) {}
        }

        if (identical(_instance, this)) {
          _instance = null;
        }
      }
      final err = closeError;
      if (err != null) throw err;
    });
    _writeLock = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// Makes everything durable AND persists the secondary indexes, so that if
  /// the process is killed afterwards (the normal end of a mobile app) the
  /// next open() loads the indexes instead of rebuilding them from every
  /// document. Call it when the app goes to the background, e.g. on
  /// `AppLifecycleState.paused`. Cost: one index serialization.
  ///
  /// Inside a transaction or batch it only flushes (nothing is committed yet).
  Future<void> flush() => _exclusive(() async {
    if (_inTransaction || _batchMode) {
      await _saveHeader();
      await storage.flush();
      await dataStorage?.flush();
      return;
    }
    await _persistCleanState();
  });

  // ─── CRUD Operations ──────────────────────────────────────────────────────
  // Single-document create, read, update, delete operations.

  Future<int> insert(dynamic doc) {
    return _exclusiveWrite(() => _crudOps.insertImpl(doc));
  }

  /// Inserts if it does not exist, updates if it does. Atómico.
  /// Retorna el ID del documento (existente o nuevo).
  Future<int> upsert(int id, Map<String, dynamic> fields) =>
      _exclusiveWrite(() => _crudOps.upsertImpl(id, fields));

  /// Upsert basado en campo único (sin conocer el ID interno).
  Future<int> upsertWhere(
    String uniqueField,
    dynamic value,
    Map<String, dynamic> fields,
  ) => _exclusiveWrite(() => _crudOps.upsertWhereImpl(uniqueField, value, fields));

  /// Hive-style put with manual key.
  Future<void> put(int id, dynamic value) {
    return _exclusiveWrite(() => _putImpl(id, value));
  }

  Future<void> _putImpl(int id, dynamic value) => _crudOps.putImpl(id, value);

  // ─── Batch & Transaction Operations ────────────────────────────────────────
  // Bulk inserts, batch modes, and atomic transactions.

  Future<List<int>> insertAll(List<dynamic> docs) =>
      _exclusiveWrite(() => _batchOps.insertAllImpl(docs));

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

    // Results cached before or during the batch are stale now.
    _queryCache.clear();
    // Every watcher — including non-indexed fields and the '' wildcard used
    // by QueryBuilder.watch(), which the old indexed-only loop skipped.
    _notifyWatchersBatch();
  }

  /// Updates all documents matching [queryFn] — atomically: if any update
  /// fails, none is applied.
  Future<int> updateWhere(
    FutureOr<List<int>> Function(QueryBuilder q) queryFn,
    Map<String, dynamic> fields,
  ) => _exclusiveWrite(() async {
    // Internal (lock-free) lookups: the public findById/rangeSearch re-enter
    // _exclusive() and wait on the lock this call already holds — a deadlock
    // for any condition on an unindexed field (full-scan fallback).
    final ids = await queryFn(
      QueryBuilder(_secondaryIndexes, _findById, _rangeSearch, null, _queryCache),
    );
    if (ids.isEmpty) return 0;

    Future<int> updateAll() async {
      int updated = 0;
      for (int i = 0; i < ids.length; i++) {
        if (await _crudOps.updateImpl(ids[i], fields)) updated++;
        if (_runningOnWeb && (i + 1) % 500 == 0) await _webBatchFlush();
      }
      return updated;
    }

    // Caller-managed batch (beginBatch()): the caller commits.
    if (_batchMode && !_inTransaction) {
      final updated = await updateAll();
      await _saveHeader();
      return updated;
    }
    final updated = await _runTransaction(updateAll);
    if (_autoCompactThreshold > 0 && !_inTransaction) await _maybeAutoCompact();
    return updated;
  });

  /// Periodic flush during large web batches: prevents IndexedDB chunk
  /// accumulation and memory overflow, and yields to the browser.
  Future<void> _webBatchFlush() async {
    await (dataStorage ?? storage).flush();
    if (dataStorage != null) await storage.flush();
    await Future.delayed(Duration.zero);
  }

  /// Updates a single document by ID.
  Future<bool> update(int id, Map<String, dynamic> fields) {
    return _exclusiveWrite(() => _crudOps.updateImpl(id, fields));
  }

  /// Executes [fn] as an atomic transaction.
  ///
  /// Other callers' operations wait until the transaction finishes; calls
  /// made from inside [fn] (including nested transactions) join it.
  Future<T> transaction<T>(Future<T> Function() fn) {
    if (_inOwnTransaction) return fn(); // nested: join the outer transaction
    return _exclusiveWrite(() => _runTransaction(fn));
  }

  /// Transaction engine shared by [transaction], [updateWhere] and
  /// [deleteWhere]. Must run under the lock; joins an already open
  /// transaction.
  Future<T> _runTransaction<T>(Future<T> Function() fn) async {
    if (_inTransaction) return fn();
    {
      _inTransaction = true;
      final token = Object();
      _txToken = token;
      final savedNextId = _nextId;
      final savedLiveCount = _liveCount;
      final savedRoot = _primaryIndex.rootPage;
      // compact() and migrations move _dataOffset — restore it on rollback
      // or subsequent writes would land at stale offsets.
      final savedDataOffset = _dataOffset;
      final wal = _wal;

      // Checkpoint pre-transaction dirty pages BEFORE opening the WAL tx:
      // they are committed state and must not join (and be lost with) a
      // possible rollback.
      await _pageManager.flushDirty();
      final savedFreeList = _pageManager.snapshotFreeList();
      if (wal != null) await wal.beginTransaction();

      try {
        await beginBatch();
        final result = await runZoned(fn, zoneValues: {_txZoneKey: token});
        await commitBatch();
        if (wal != null) await wal.commit();
        return result;
      } catch (e) {
        _nextId = savedNextId;
        _liveCount = savedLiveCount;
        _primaryIndex.rootPage = savedRoot;
        _dataOffset = savedDataOffset;
        if (wal != null) await wal.rollback();
        // Clear batch entries and CACHE on rollback to prevent them from leaking into next operations.
        // Dirty pages at this point are transaction-only (pre-tx state was
        // flushed before opening the tx) — safe to discard. LRU-cached pages
        // may hold post-tx reads — must be invalidated.
        _batchEntries.clear();
        _batchMode = false;
        _pageManager.clearDirtyPages();
        _pageManager.clearLruCache();
        // Pages freed inside the tx belong to the tree restored above.
        _pageManager.restoreFreeList(savedFreeList);
        _primaryIndex.clearNodeCache();
        _queryCache.clear();
        // Roll back SECONDARY indexes too: aborted operations already mutated
        // them eagerly. Rebuild from the restored primary index (rollback is
        // rare — correctness over speed here).
        await _indexMgr.rebuildSecondaryIndexes();
        rethrow;
      } finally {
        _inTransaction = false;
        _txToken = null;
      }
    }
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
    _batchFindByIds,
    _exclusive, // terminal operations run under the lock
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

  // ─── JSON Interoperability ────────────────────────────────────────────────

  /// Exports every document as a JSON array (ascending id order), for
  /// syncing with or migrating to other document databases.
  ///
  /// Values are mapped onto plain JSON: `DateTime` → ISO-8601 UTC string,
  /// `Uint8List` → base64 string, NaN/±Infinity → `null`. Each document keeps
  /// its `ffdbID` field. Documents stored through a TypeAdapter are exported
  /// via their `toJson()`. The whole export is built in memory.
  Future<String> exportJson() => _exclusive(() => _jsonOps.exportJsonImpl());

  /// Inserts the documents of a JSON array (or a single JSON object) as new
  /// documents, in one batch, and returns their ids.
  ///
  /// An `ffdbID` field in the input is dropped — this database assigns the
  /// ids. Values stay plain JSON types: ISO-8601 strings are NOT converted
  /// back to `DateTime` (nor base64 to bytes). Throws [FormatException] for
  /// input that is not an object or an array of objects.
  Future<List<int>> importJson(String json) =>
      _exclusiveWrite(() => _jsonOps.importJsonImpl(json));

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
    // Each step takes the lock (lazily — a slow consumer must not block
    // writers between documents).
    final ids = await _exclusive(
      () async => await queryFn(
        QueryBuilder(
          _secondaryIndexes,
          _findById,
          _rangeSearch,
          null,
          _queryCache,
        ),
      ),
    );
    for (final id in ids) {
      final doc = await _exclusive(() => _findById(id));
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
    if (doc is! Map<String, dynamic>) return _notifyWatchersBatch();
    // Notify only watchers whose field was modified in doc, or whose dotted
    // path starts with a modified field. '' is the wildcard used by
    // QueryBuilder.watch() with no conditions: notified on EVERY write.
    for (final field in _watchers.keys) {
      if (field.isEmpty ||
          doc.containsKey(field) ||
          (field.contains('.') && doc.containsKey(field.split('.').first))) {
        _scheduleWatch(field);
      }
    }
  }

  void _notifyWatchersBatch() {
    _watchers.keys.forEach(_scheduleWatch);
  }

  /// Fields with a pending emission, flushed once per event-loop turn.
  final Set<String> _pendingWatchFields = {};
  bool _watchFlushScheduled = false;

  /// Coalesces watcher emissions: each one materializes the field's FULL id
  /// list (an index copy, or a B-Tree scan for non-indexed fields), and the
  /// old code did that synchronously on every single write — O(n) per
  /// write, O(n²) for a burst. Now a burst emits once, with its final state.
  void _scheduleWatch(String field) {
    _pendingWatchFields.add(field);
    if (_watchFlushScheduled) return;
    _watchFlushScheduled = true;
    Timer.run(_flushWatchers);
  }

  void _flushWatchers() {
    _watchFlushScheduled = false;
    if (_isClosed || _pendingWatchFields.isEmpty) {
      _pendingWatchFields.clear();
      return;
    }
    final fields = _pendingWatchFields.toList();
    _pendingWatchFields.clear();
    // Under the lock: never emit an open transaction's uncommitted state.
    _exclusive(() async {
      for (final field in fields) {
        final stream = _watchers[field];
        if (stream == null || stream.isClosed) continue;
        final idx = _secondaryIndexes[field];
        final ids = idx != null
            ? idx.all()
            : await _primaryIndex.rangeSearch(1, _nextId - 1, skipDedupe: true);
        if (!stream.isClosed) stream.add(ids);
      }
    }).then((_) {}, onError: (_) {}); // closed meanwhile — nothing to emit
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
    return _deserializeRecord(fullData, length, offset);
  }

  /// Parses one record's already-in-memory bytes
  /// (`[4-byte length][payload][4-byte CRC32]`) into a document.
  ///
  /// Factored out of [_readAt] so [_batchFindByIds] can deserialize records
  /// fetched via one large contiguous read instead of one `storage.read()`
  /// call per document — see [_batchReadRaw] for why that matters on real
  /// disk storage.
  dynamic _deserializeRecord(Uint8List fullData, int length, int offset) {
    final int totalSize = 4 + length + 4;
    // Verify CRC — same check as the sync path (_readAtSync).
    // Views, not copies: fullData is a fresh buffer owned by this read.
    final body = Uint8List.sublistView(fullData, 4, 4 + length);
    if (fullData.length >= totalSize) {
      final storedCrc = _readInt32(fullData, 4 + length);
      final computedCrc = _crc32(body);
      if (storedCrc != 0 && storedCrc != computedCrc) {
        throw StateError(
          'FastDB: CRC32 mismatch at offset $offset '
          '(stored 0x${storedCrc.toRadixString(16)}, '
          'computed 0x${computedCrc.toRadixString(16)}). '
          'Document data may be corrupted.',
        );
      }
    }

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

    // 1. Map documents: binary v2 [0x00, 0x02] or JSON v1 [0x00, 0x01]
    final mapDoc = decodeDocumentPayload(body);
    if (mapDoc != null) {
      migrateLegacyDoc(mapDoc);
      return mapDoc;
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

  /// Reads raw document bytes (length header + payload + CRC32) at [offset] without deserialization.
  Future<Uint8List?> _readRawAt(int offset) async {
    if (offset < 0) return null;
    if (dataStorage == null && offset < PageManager.pageSize) return null;
    final targetStorage = dataStorage ?? storage;
    const int readAheadSize = 512;
    final chunk = await targetStorage.read(offset, readAheadSize);
    if (chunk.length < 4) return null;
    final length = _readInt32(chunk, 0);
    if (length <= 0 || length > 10 * 1024 * 1024) return null;
    final int totalSize = 4 + length + 4;
    if (totalSize <= chunk.length) {
      return chunk.sublist(0, totalSize); // one copy (Uint8List.sublist)
    }
    return targetStorage.read(offset, totalSize);
  }

  /// Reads raw document bytes for a batch of (id, offset) entries.
  ///
  /// Documents written by normal inserts/insertAll sit back-to-back in the
  /// file, so a batch's entries are almost always densely packed — fetching
  /// them with [Future.wait] over individually-awaited reads still means one
  /// `read()` call (and one trip through IoStorageStrategy's serializing
  /// lock, each allocating its own Completer/Future) PER DOCUMENT. Measured
  /// on 100k docs: only ~5% of that time is actual disk I/O: the rest is
  /// Dart-side Future/lock-chain overhead from making 100k separate calls.
  ///
  /// Instead, this reads the whole batch's byte span in ONE call and slices
  /// each record out of the shared buffer in memory. Falls back to the
  /// existing per-entry path (a) entirely, if the span is too sparse to be
  /// worth it (e.g. many deletions scattered between the batch's live docs),
  /// or (b) per-entry, if a specific record turns out to extend past what
  /// was fetched (larger than [_batchReadTailCeiling], or near EOF).
  ///
  /// Shared by [IndexManager] (reindex) and [_QueryOperations] (regular
  /// queries / `getAll()`) — both resolve many ids to full records and both
  /// used to pay the per-call overhead above before this existed.
  static const int _batchReadAvgDocCeiling = 4096;
  static const int _batchReadTailCeiling = 64 * 1024;

  Future<List<Uint8List?>> _batchReadRaw(List<MapEntry<int, int>> batch) async {
    if (batch.isEmpty) return const [];
    if (batch.length == 1) return [await _readRawAt(batch[0].value)];

    int minOffset = batch[0].value;
    int maxOffset = batch[0].value;
    for (final e in batch) {
      if (e.value < minOffset) minOffset = e.value;
      if (e.value > maxOffset) maxOffset = e.value;
    }

    final span = maxOffset - minOffset;
    if (span > batch.length * _batchReadAvgDocCeiling) {
      // Too sparse — reading the whole span would fetch mostly dead space.
      return Future.wait(batch.map((e) => _readRawAt(e.value)));
    }

    final targetStorage = dataStorage ?? storage;
    final chunk = await targetStorage.read(minOffset, span + _batchReadTailCeiling);

    final results = List<Uint8List?>.filled(batch.length, null);
    for (int i = 0; i < batch.length; i++) {
      final localOffset = batch[i].value - minOffset;
      if (localOffset + 4 > chunk.length) {
        results[i] = await _readRawAt(batch[i].value);
        continue;
      }
      final length = _readInt32(chunk, localOffset);
      if (length <= 0 || length > 10 * 1024 * 1024) {
        results[i] = null;
        continue;
      }
      final totalSize = 4 + length + 4;
      if (localOffset + totalSize <= chunk.length) {
        results[i] = chunk.sublist(localOffset, localOffset + totalSize);
      } else {
        // Record extends past the fetched span — fetch it directly instead.
        results[i] = await _readRawAt(batch[i].value);
      }
    }
    return results;
  }

  /// Batch-resolves ids to fully deserialized documents, using
  /// [_batchReadRaw] instead of one `_readAt()`-style storage read per id.
  ///
  /// The result is ALIGNED with [ids]: element i is the document of ids[i],
  /// or null when it does not exist (like [_findById]). Callers that return
  /// documents to the user drop the nulls; the query full-scan relies on the
  /// alignment to map documents back to their ids.
  Future<List<dynamic>> _batchFindByIds(List<int> ids) async {
    final docs = List<dynamic>.filled(ids.length, null);
    if (ids.isEmpty) return docs;

    final entries = <MapEntry<int, int>>[];
    final positions = <int>[];
    for (int p = 0; p < ids.length; p++) {
      final id = ids[p];
      final offset = await _primaryIndex.search(id);
      if (offset != null) {
        entries.add(MapEntry(id, offset));
        positions.add(p);
      } else if (_batchEntries.isNotEmpty) {
        // Read-your-writes in batch/transaction mode (see _findById).
        for (final e in _batchEntries) {
          if (e.key == id) {
            entries.add(e);
            positions.add(p);
            break;
          }
        }
      }
    }
    if (entries.isEmpty) return docs;

    final rawResults = await _batchReadRaw(entries);
    for (int i = 0; i < entries.length; i++) {
      final raw = rawResults[i];
      if (raw == null || raw.length < 4) continue;
      final length = _readInt32(raw, 0);
      if (length <= 0) continue;
      docs[positions[i]] = _deserializeRecord(raw, length, entries[i].value);
    }
    return docs;
  }

  // Serialization & Encoding

  Uint8List _serialize(dynamic doc, {int? id}) {
    if (doc is Map) return _sealRecord(DocumentCodec.encodeRecord(doc, id: id));

    if (_registry.getTypeId(doc.runtimeType) != null) {
      // Registered TypeAdapter path — the adapter's own binary format.
      final writer = FastBinaryWriter();
      _registry.write(writer, doc);
      final payload = writer.result;
      final result = Uint8List(4 + payload.length + 4);
      _writeInt32(result, 0, payload.length);
      result.setRange(4, 4 + payload.length, payload);
      return _sealRecord(result);
    }

    // No TypeAdapter registered — store the object's toJson() as a document.
    Map map;
    try {
      map = (doc as dynamic).toJson() as Map;
    } catch (_) {
      map = {
        'value': doc.toString(),
        'runtimeType': doc.runtimeType.toString(),
      };
    }
    return _sealRecord(DocumentCodec.encodeRecord(map, id: id));
  }

  /// Fills the trailing CRC32 of a `[length][payload][crc]` record in place.
  Uint8List _sealRecord(Uint8List record) {
    final length = record.length - 8;
    _writeInt32(record, 4 + length, _crc32(Uint8List.sublistView(record, 4, 4 + length)));
    return record;
  }

  // Storage Management (Headers, Indexes, Persistence)

  Future<void> _saveHeader() => _storageMgr.saveHeader();

  // ─── Index Persistence ─────────────────────────────────────────────────────

  Future<void> _saveIndexes() => _storageMgr.saveIndexes();

  Future<Set<String>> _loadIndexes() => _storageMgr.loadIndexes();

  // ─── Delete ────────────────────────────────────────────────────────────────

  Future<bool> delete(int id) {
    return _exclusiveWrite(() => _crudOps.deleteImpl(id));
  }

  /// Count of documents deleted or overwritten since last compact().
  /// Used by auto-compact threshold logic. A `Set<int>` was previously used here
  /// but caused unbounded memory growth under heavy delete/update loads.
  int _deletedCount = 0;

  /// Deletes all documents matching [queryFn] in a single atomic transaction.
  Future<int> deleteWhere(
    FutureOr<List<int>> Function(QueryBuilder q) queryFn,
  ) => _exclusiveWrite(() async {
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

    Future<int> deleteAll() async {
      int count = 0;
      for (int i = 0; i < ids.length; i++) {
        if (await _crudOps.deleteImpl(ids[i])) count++;
        if (_runningOnWeb && (i + 1) % 500 == 0) await _webBatchFlush();
      }
      return count;
    }

    // Caller-managed batch (beginBatch()): the caller commits.
    if (_batchMode && !_inTransaction) {
      final count = await deleteAll();
      await _saveHeader();
      return count;
    }
    // A real transaction: the old hand-rolled one committed the WAL BEFORE
    // flushing the B-Tree pages and header (not atomic) and, on failure,
    // restored neither the tree root, the dirty pages nor the indexes.
    final count = await _runTransaction(deleteAll);
    if (_autoCompactThreshold > 0 && !_inTransaction) await _maybeAutoCompact();
    return count;
  });

  Future<void> _maybeAutoCompact() => _storageMgr.maybeAutoCompact();

  // ─── Compact (Vacuum) ──────────────────────────────────────────────────────

  /// Compacts the database inside a WAL transaction.
  Future<void> compact() => transaction(() => _storageMgr.compactImpl());

  /// Completely removes all documents from the database in O(1) time and resets
  /// auto-increment IDs to 1.
  Future<void> clear() => _exclusiveWrite(() => _storageMgr.clearImpl());

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
