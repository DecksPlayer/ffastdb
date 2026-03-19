import 'dart:async';
import 'dart:typed_data';
import 'storage/storage_strategy.dart';
import 'storage/page_manager.dart';
import 'storage/wal_storage_strategy.dart';
import 'index/btree.dart';
import 'index/hash_index.dart';
import 'index/sorted_index.dart';
import 'index/bitmask_index.dart';
import 'query/fast_query.dart';
import 'serialization/fast_serializer.dart';
import 'serialization/type_adapter.dart';
import 'serialization/type_registry.dart';
import 'index/secondary_index.dart';
import 'serialization/binary_io.dart';

/// True on JavaScript/web (integer and double share representation),
/// false on native Dart VM. Used to gate UI-yield calls that are only
/// needed on web to prevent browser tab jank.
const bool _runningOnWeb = identical(0, 0.0);

/// FastDB — A high-performance, pure-Dart NoSQL database.
///
/// Supports JSON documents, custom objects via TypeAdapters,
/// B-Tree primary index, hash-based secondary indexes,
/// fluent queries, and reactive watchers.
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

  Future<void> _writeLock = Future.value();

  Future<T> _exclusive<T>(Future<T> Function() fn) {
    if (_inTransaction) return fn();
    final next = _writeLock.then((_) => fn());
    _writeLock = next.then((_) {}, onError: (_) {});
    return next;
  }

  final List<MapEntry<int, int>> _batchEntries = [];
  int _dataOffset = 0;

  int _schemaVersion = 1;
  double _autoCompactThreshold = 0;

  WalStorageStrategy? get _wal =>
      storage is WalStorageStrategy ? storage as WalStorageStrategy : null;

  /// Standard constructor.
  /// Provide [dataStorage] to separate documents from B-Tree pages for max performance.
  /// Set [autoCompactThreshold] (0–1) to trigger automatic compaction whenever the
  /// ratio of deleted documents exceeds that fraction. E.g. `0.3` = compact when
  /// more than 30 % of slots are deleted. Disabled by default (0).
  FastDB(this.storage, {
    this.dataStorage,
    int cacheCapacity = 256,
    double autoCompactThreshold = 0,
  }) {
    _autoCompactThreshold = autoCompactThreshold;
    _pageManager = PageManager(storage, cacheCapacity: cacheCapacity);
    _primaryIndex = BTree(_pageManager);
  }

  // ─── Singleton ────────────────────────────────────────────────────────────

  static FastDB? _instance;

  /// The global singleton instance. Throws if [init()] has not been called yet.
  static FastDB get instance {
    if (_instance == null) {
      throw StateError(
          'FfastDb not initialized. Call `await FfastDb.init(storage)` first.');
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
  }) async {
    final db = FastDB(
      storage,
      dataStorage: dataStorage,
      cacheCapacity: cacheCapacity,
      autoCompactThreshold: autoCompactThreshold,
    );
    await db.open(version: version, migrations: migrations);
    _instance = db;
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
  void registerAdapter<T>(TypeAdapter<T> adapter) {
    _registry.registerAdapter(adapter);
  }

  /// Creates an O(1) hash-based secondary index on [fieldName].
  void addIndex(String fieldName) {
    _secondaryIndexes.putIfAbsent(fieldName, () => HashIndex(fieldName));
  }

  /// Creates an O(log n) sorted secondary index on [fieldName].
  void addSortedIndex(String fieldName) {
    _secondaryIndexes[fieldName] = SortedIndex(fieldName);
  }

  /// Creates a bitmask index on [fieldName].
  void addBitmaskIndex(String fieldName, {int maxDocId = 1 << 20}) {
    _secondaryIndexes[fieldName] = BitmaskIndex(fieldName, maxDocId: maxDocId);
  }

  /// Rebuilds secondary indexes from live documents.
  ///
  /// Pass [field] to rebuild only that index; omit to rebuild all.
  Future<void> reindex([String? field]) async {
    if (field != null) {
      final idx = _secondaryIndexes[field];
      if (idx == null) throw ArgumentError('No index registered for field "$field"');
      idx.clear();
      final allIds = await _primaryIndex.rangeSearch(1, _nextId - 1);
      for (int i = 0; i < allIds.length; i++) {
        final doc = await findById(allIds[i]);
        if (doc is Map<String, dynamic>) {
          final val = doc[field];
          if (val != null) idx.add(allIds[i], val);
        }
        if (i > 0 && i % 250 == 0) await Future.delayed(Duration.zero);
      }
    } else {
      await _rebuildSecondaryIndexes();
    }
  }

  // ─── Open / Close ─────────────────────────────────────────────────────────

  Future<void> open({
    int version = 1,
    Map<int, dynamic Function(dynamic)>? migrations,
  }) async {
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
        await _rebuildSecondaryIndexes();
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

  Future<void> close() async {
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
    for (final c in _watchers.values) {
      await c.close();
    }
  }

  /// Flushes the header and all pending page writes to disk.
  Future<void> flush() async {
    await _saveHeader();
    await storage.flush();
    await dataStorage?.flush();
  }

  // ─── Write Operations ─────────────────────────────────────────────────────

  Future<int> insert(dynamic doc) => _exclusive(() => _insertImpl(doc));

  Future<int> _insertImpl(dynamic doc) async {
    final wal = _wal;
    if (!_inTransaction && !_batchMode && wal != null) await wal.beginTransaction();
    try {
      final id = _nextId++;
      final data = _serialize(doc, id: id);
      final targetStorage = dataStorage ?? storage;
      final offset = _dataOffset;

      await targetStorage.write(offset, data);

      if (_batchMode) {
        _batchEntries.add(MapEntry(id, offset));
      } else {
        await _primaryIndex.insert(id, offset);
      }

      if (dataStorage != null) {
        _dataOffset += data.length;
      } else {
        _dataOffset = storage.sizeSync ?? await storage.size;
      }

      if (!_batchMode && storage.needsExplicitFlush) {
        await targetStorage.flush();
        await storage.flush();
        await _saveHeader();
      }

      if (doc is Map<String, dynamic>) _indexDocument(id, doc);
      if (!_batchMode) _notifyWatchers(doc);
      if (!_inTransaction && !_batchMode && wal != null) await wal.commit();
      return id;
    } catch (e) {
      if (!_inTransaction && !_batchMode && wal != null) await wal.rollback();
      rethrow;
    }
  }

  /// Hive-style put with manual key.
  Future<void> put(int id, dynamic value) => _exclusive(() => _putImpl(id, value));

  Future<void> _putImpl(int id, dynamic value) async {
    final oldOffset = await _primaryIndex.search(id);
    if (oldOffset != null) _deletedOffsets.add(oldOffset);

    final wal = _wal;
    if (!_inTransaction && wal != null) await wal.beginTransaction();
    try {
      final data = _serialize(value, id: id);
      final targetStorage = dataStorage ?? storage;
      final offset = _dataOffset;
      if (!targetStorage.writeSync(offset, data)) {
        await targetStorage.write(offset, data);
      }
      if (storage.needsExplicitFlush) await targetStorage.flush();
      if (dataStorage != null) {
        _dataOffset += data.length;
      } else {
        _dataOffset = storage.sizeSync ?? await storage.size;
      }
      await _primaryIndex.insert(id, offset);
      if (id >= _nextId) _nextId = id + 1;
      if (storage.needsExplicitFlush) {
        await storage.flush();
        await _saveHeader();
      }
      if (value is Map<String, dynamic>) _indexDocument(id, value);
      _notifyWatchers(value);
      if (!_inTransaction && wal != null) await wal.commit();
    } catch (e) {
      if (!_inTransaction && wal != null) await wal.rollback();
      rethrow;
    }
  }

  Future<List<int>> insertAll(List<dynamic> docs) => _exclusive(() => _insertAllImpl(docs));

  Future<List<int>> _insertAllImpl(List<dynamic> docs) async {
    if (docs.isEmpty) return [];
    _enableWriteBehind();
    _batchMode = true;
    _batchEntries.clear();

    final ids = <int>[];
    final serializedDocs = <Uint8List>[];

    var state = _BatchState.serialize;
    bool done = false;

    while (!done) {
      switch (state) {
        case _BatchState.serialize:
          for (int i = 0; i < docs.length; i++) {
            final doc = docs[i];
            final id = _nextId++;
            ids.add(id);
            serializedDocs.add(_serialize(doc, id: id));
            if (_runningOnWeb && i > 0 && i % 500 == 0) await Future.delayed(Duration.zero);
          }
          if (!_inTransaction && _wal != null) await _wal!.beginTransaction();
          state = _BatchState.write;
          break;

        case _BatchState.write:
          final targetStorage = dataStorage ?? storage;
          for (int i = 0; i < serializedDocs.length; i++) {
            final data = serializedDocs[i];
            final offset = _dataOffset;
            final id = ids[i];
            if (!targetStorage.writeSync(offset, data)) {
              await targetStorage.write(offset, data);
            }
            _batchEntries.add(MapEntry(id, offset));
            _dataOffset += data.length;
            final doc = docs[i];
            if (doc is Map<String, dynamic>) _indexDocument(id, doc);
            if (_runningOnWeb && i > 0 && i % 500 == 0) await Future.delayed(Duration.zero);
          }
          state = _BatchState.indexing;
          break;

        case _BatchState.indexing:
          await _primaryIndex.bulkLoad(_batchEntries);
          _batchEntries.clear();
          state = _BatchState.finish;
          break;

        case _BatchState.finish:
          final wal = _wal;
          _batchMode = false;
          await _pageManager.flushDirty();
          await dataStorage?.flush();
          await storage.flush();
          await _saveHeader();
          _disableWriteBehind();
          if (!_inTransaction && wal != null) await wal.commit();
          if (dataStorage == null) {
            _dataOffset = await storage.size;
          }
          for (final doc in docs) {
            _notifyWatchers(doc);
          }
          done = true;
          break;
      }
    }
    return ids;
  }

  Future<void> beginBatch() async {
    _batchMode = true;
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
      _exclusive(() => _updateImpl(id, fields));

  Future<bool> _updateImpl(int id, Map<String, dynamic> fields) async {
    final existing = await findById(id);
    if (existing == null) return false;
    if (existing is! Map) {
      throw UnsupportedError(
          'update() requires a Map document. TypeAdapter objects must be '
          'replaced via put() or insert().');
    }
    final oldOffset = await _primaryIndex.search(id);
    final merged = Map<String, dynamic>.from(existing as Map<String, dynamic>)..addAll(fields);

    final wal = _wal;
    if (!_inTransaction && wal != null) await wal.beginTransaction();
    try {
      if (oldOffset != null) _deletedOffsets.add(oldOffset);

      for (final idx in _secondaryIndexes.values) {
        idx.remove(id, existing[idx.fieldName]);
      }

      final data = _serialize(merged, id: id);
      final targetStorage = dataStorage ?? storage;
      final offset = _dataOffset;

      if (!targetStorage.writeSync(offset, data)) {
        await targetStorage.write(offset, data);
      }

      if (dataStorage != null) {
        _dataOffset += data.length;
      } else {
        _dataOffset = storage.sizeSync ?? await storage.size;
      }

      await _primaryIndex.insert(id, offset);
      _indexDocument(id, merged);

      if (!_batchMode) {
        await targetStorage.flush();
        await storage.flush();
        await _saveHeader();
        _notifyWatchers(merged);
      }
      if (!_inTransaction && wal != null) await wal.commit();
      return true;
    } catch (e) {
      if (!_inTransaction && wal != null) await wal.rollback();
      rethrow;
    }
  }

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
        if (await _updateImpl(id, fields)) updated++;
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
        _nextId = savedNextId;
        _dataOffset = savedDataOffset;
        _primaryIndex.rootPage = savedRootPage;
        _pageManager.clearLruCache();
        _primaryIndex.clearNodeCache();
        if (_secondaryIndexes.isNotEmpty) await _rebuildSecondaryIndexes();
        rethrow;
      } finally {
        _inTransaction = false;
      }
    });
  }

  // ─── Read Operations ──────────────────────────────────────────────────────

  /// Get by primary key — O(log n).
  Future<dynamic> findById(int id) async {
    final syncOffset = _primaryIndex.searchSync(id);
    if (syncOffset != null) {
      if (dataStorage == null && syncOffset < PageManager.pageSize) return null;
      final syncDoc = _readAtSync(syncOffset);
      if (syncDoc != null) return syncDoc;
    }
    final offset = await _primaryIndex.search(id);
    if (offset == null) return null;
    if (dataStorage == null && offset < PageManager.pageSize) return null;
    return _readAt(offset);
  }

  /// Returns document IDs where primary key is in [low..high] range.
  Future<List<int>> rangeSearch(int low, int high) => _primaryIndex.rangeSearch(low, high);

  /// Hive-style get.
  Future<dynamic> get(int id) => findById(id);

  /// Find all documents matching a query.
  Future<List<dynamic>> find(List<int> Function(QueryBuilder q) queryFn) async {
    final builder = QueryBuilder(_secondaryIndexes);
    final ids = queryFn(builder);
    final results = <dynamic>[];
    for (final id in ids) {
      final doc = await findById(id);
      if (doc != null) results.add(doc);
    }
    return results;
  }

  /// Returns a fluent QueryBuilder for chaining conditions.
  QueryBuilder query() => QueryBuilder(_secondaryIndexes);

  Future<List<dynamic>> findWhere(List<int> Function(QueryBuilder q) fn) => find(fn);

  /// Returns all documents in the database.
  Future<List<dynamic>> getAll() async {
    final ids = await _primaryIndex.rangeSearch(1, _nextId - 1);
    final results = <dynamic>[];
    for (final id in ids) {
      final doc = await findById(id);
      if (doc != null) results.add(doc);
    }
    return results;
  }

  /// Returns the number of live documents.
  Future<int> count() async {
    final ids = await _primaryIndex.rangeSearch(1, _nextId - 1);
    return ids.length;
  }

  /// Returns true if a document with the given [id] exists.
  Future<bool> exists(int id) async {
    return await _primaryIndex.search(id) != null;
  }

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
    final ctrl = _watchers.putIfAbsent(
      field,
      () => StreamController<List<int>>.broadcast(),
    );
    return ctrl.stream;
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

  void _indexDocument(int id, Map<String, dynamic> doc) {
    for (final idx in _secondaryIndexes.values) {
      final val = doc[idx.fieldName];
      if (val != null) idx.add(id, val);
    }
  }

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
      return FastSerializer.deserialize(fullData);
    }
    final reader = FastBinaryReader(body);
    return _registry.read(reader);
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
    final Uint8List fullData;
    if (4 + length <= chunk.length) {
      fullData = chunk;
    } else {
      fullData = await targetStorage.read(offset, 4 + length);
    }
    final body = fullData.sublist(4, 4 + length);
    if (body.isNotEmpty && (body[0] == 123 || body[0] == 91)) {
      return FastSerializer.deserialize(fullData);
    }
    final reader = FastBinaryReader(body);
    return _registry.read(reader);
  }

  Uint8List _serialize(dynamic doc, {int? id}) {
    final Uint8List payload;
    if (doc is Map) {
      final map = Map<String, dynamic>.from(doc as Map<String, dynamic>);
      if (id != null) map['id'] = id;
      payload = FastSerializer.serialize(map);
    } else {
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

  Future<void> _saveHeader() async {
    final header = Uint8List(16);
    header[0] = 70; header[1] = 68; header[2] = 66; header[3] = 50; // "FDB2"
    _writeInt32(header, 4, _primaryIndex.rootPage ?? 0);
    _writeInt32(header, 8, _nextId);
    _writeInt32(header, 12, _schemaVersion);
    await storage.write(0, header);
  }

  // ─── Index Persistence ─────────────────────────────────────────────────────

  Future<void> _saveIndexes() async {
    final persistable = <({int typeTag, Uint8List blob})>[];
    for (final entry in _secondaryIndexes.entries) {
      if (entry.value is HashIndex) {
        final blob = (entry.value as HashIndex).serialize();
        if (blob.isNotEmpty) persistable.add((typeTag: 1, blob: blob));
      } else if (entry.value is SortedIndex) {
        final blob = (entry.value as SortedIndex).serialize();
        if (blob.isNotEmpty) persistable.add((typeTag: 2, blob: blob));
      } else if (entry.value is BitmaskIndex) {
        final blob = (entry.value as BitmaskIndex).serialize();
        if (blob.isNotEmpty) persistable.add((typeTag: 3, blob: blob));
      }
    }
    if (persistable.isEmpty) return;

    final buf = BytesBuilder();
    final countBytes = Uint8List(4);
    countBytes[0] = persistable.length & 0xFF;
    countBytes[1] = (persistable.length >> 8) & 0xFF;
    countBytes[2] = (persistable.length >> 16) & 0xFF;
    countBytes[3] = (persistable.length >> 24) & 0xFF;
    buf.add(countBytes);

    for (final entry in persistable) {
      final blob = entry.blob;
      buf.addByte(entry.typeTag);
      final lenBytes = Uint8List(4);
      lenBytes[0] = blob.length & 0xFF;
      lenBytes[1] = (blob.length >> 8) & 0xFF;
      lenBytes[2] = (blob.length >> 16) & 0xFF;
      lenBytes[3] = (blob.length >> 24) & 0xFF;
      buf.add(lenBytes);
      buf.add(blob);
    }

    final payload = buf.toBytes();
    final meta = await storage.read(16, 8);
    final prevOffset = _readInt32(meta, 0);
    final prevLen = _readInt32(meta, 4);
    final int writeOffset;
    if (prevOffset > 0 && prevLen > 0 && payload.length <= prevLen) {
      writeOffset = prevOffset;
    } else {
      writeOffset = _dataOffset;
    }
    await storage.write(writeOffset, payload);
    if (prevOffset > 0 && prevLen > 0 && writeOffset == prevOffset && payload.length < prevLen) {
      await storage.truncate(writeOffset + payload.length);
    }
    final header = Uint8List(8);
    _writeInt32(header, 0, writeOffset);
    _writeInt32(header, 4, payload.length);
    await storage.write(16, header);
  }

  Future<void> _loadIndexes() async {
    try {
      final meta = await storage.read(16, 8);
      final idxOffset = _readInt32(meta, 0);
      final idxLength = _readInt32(meta, 4);
      if (idxOffset <= 0 || idxLength <= 0) return;
      final blob = await storage.read(idxOffset, idxLength);
      int off = 0;
      final count = _readInt32(blob, off); off += 4;
      for (int i = 0; i < count; i++) {
        final typeTag = blob[off]; off += 1;
        final len = _readInt32(blob, off); off += 4;
        final indexBytes = blob.sublist(off, off + len);
        off += len;
        SecondaryIndex idx;
        switch (typeTag) {
          case 1: idx = HashIndex.deserialize(indexBytes);
          case 2: idx = SortedIndex.deserialize(indexBytes);
          case 3: idx = BitmaskIndex.deserialize(indexBytes);
          default: continue;
        }
        _secondaryIndexes[idx.fieldName] = idx;
      }
    } catch (_) {}
  }

  // ─── Delete ────────────────────────────────────────────────────────────────

  Future<bool> delete(int id) => _exclusive(() => _deleteImpl(id));

  Future<bool> _deleteImpl(int id) async {
    final offset = await _primaryIndex.search(id);
    if (offset == null) return false;
    if (dataStorage == null && offset < PageManager.pageSize) return false;
    final doc = await _readAt(offset);
    final wal = _wal;
    if (!_inTransaction && wal != null) await wal.beginTransaction();
    try {
      await _primaryIndex.delete(id);
      if (doc is Map) {
        for (final idx in _secondaryIndexes.values) {
          idx.remove(id, doc[idx.fieldName]);
        }
      } else {
        for (final idx in _secondaryIndexes.values) {
          idx.removeById(id);
        }
      }
      _deletedOffsets.add(offset);
      if (!_batchMode) await _saveHeader();
      if (!_inTransaction && wal != null) await wal.commit();
      if (_autoCompactThreshold > 0 && !_inTransaction && !_batchMode) {
        await _maybeAutoCompact();
      }
      return true;
    } catch (e) {
      if (!_inTransaction && wal != null) await wal.rollback();
      rethrow;
    }
  }

  final Set<int> _deletedOffsets = {};

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
            if (await _deleteImpl(id)) count++;
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

  Future<void> _maybeAutoCompact() async {
    if (_autoCompactThreshold <= 0) return;
    final liveIds = await _primaryIndex.rangeSearch(1, _nextId - 1);
    final deleted = _deletedOffsets.length;
    final total = liveIds.length + deleted;
    if (total == 0) return;
    if (deleted / total >= _autoCompactThreshold) await _compactImpl();
  }

  // ─── Compact (Vacuum) ──────────────────────────────────────────────────────

  Future<void> compact() => _exclusive(() => _compactImpl());

  Future<void> _compactImpl() async {
    final allIds = await _primaryIndex.rangeSearch(1, _nextId - 1);
    if (allIds.isEmpty) return;
    final docs = <int, dynamic>{};
    for (int i = 0; i < allIds.length; i++) {
      final id = allIds[i];
      final doc = await findById(id);
      if (doc != null) docs[id] = doc;
      if (i > 0 && i % 250 == 0) await Future.delayed(Duration.zero);
    }
    final targetStorage = dataStorage ?? storage;
    final int writeStart = dataStorage != null ? 0 : _dataOffset;
    int writePos = writeStart;
    int i = 0;
    for (final entry in docs.entries) {
      final data = _serialize(entry.value, id: entry.key);
      await targetStorage.write(writePos, data);
      await _primaryIndex.insert(entry.key, writePos);
      writePos += data.length;
      if (i > 0 && i % 250 == 0) await Future.delayed(Duration.zero);
      i++;
    }
    _dataOffset = writePos;
    if (dataStorage != null) await dataStorage!.truncate(_dataOffset);
    await _pageManager.flushDirty();
    _pageManager.clearCache();
    _primaryIndex.clearNodeCache();
    _deletedOffsets.clear();
    await _saveHeader();
    await storage.flush();
    if (dataStorage != null) await dataStorage!.flush();
  }

  // ─── Migrations ────────────────────────────────────────────────────────────

  Future<void> _runMigrations(
      int currentVersion, int targetVersion, Map<int, dynamic Function(dynamic)>? migrations) async {
    final allIds = await _primaryIndex.rangeSearch(1, _nextId - 1);
    if (allIds.isEmpty) return;
    final docs = <int, dynamic>{};
    for (int i = 0; i < allIds.length; i++) {
      final id = allIds[i];
      final doc = await findById(id);
      if (doc != null) {
        dynamic migratedDoc = doc;
        if (migrations != null) {
          for (int v = currentVersion; v < targetVersion; v++) {
            if (migrations.containsKey(v)) {
              migratedDoc = migrations[v]!(migratedDoc);
            }
          }
        }
        docs[id] = migratedDoc;
      }
      if (i > 0 && i % 250 == 0) await Future.delayed(Duration.zero);
    }
    int i = 0;
    for (final entry in docs.entries) {
      final targetStorage = dataStorage ?? storage;
      final newOffset = _dataOffset;
      final data = _serialize(entry.value, id: entry.key);
      await targetStorage.write(newOffset, data);
      _dataOffset += data.length;
      await _primaryIndex.insert(entry.key, newOffset);
      if (i > 0 && i % 250 == 0) await Future.delayed(Duration.zero);
      i++;
    }
    _deletedOffsets.clear();
    if (dataStorage != null) await dataStorage!.truncate(_dataOffset);
    await storage.flush();
    if (dataStorage != null) await dataStorage!.flush();
  }

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

  Future<void> _rebuildSecondaryIndexes() async {
    if (_secondaryIndexes.isEmpty) return;
    for (final idx in _secondaryIndexes.values) idx.clear();
    final allIds = await _primaryIndex.rangeSearch(1, 0x7FFFFFFF);
    for (int i = 0; i < allIds.length; i++) {
      final id = allIds[i];
      final doc = await findById(id);
      if (doc is Map<String, dynamic>) _indexDocument(id, doc);
      if (i > 0 && i % 250 == 0) await Future.delayed(Duration.zero);
    }
  }
}

/// Canonical public alias for [FastDB].
typedef FfastDb = FastDB;

enum _BatchState { serialize, write, indexing, finish }
