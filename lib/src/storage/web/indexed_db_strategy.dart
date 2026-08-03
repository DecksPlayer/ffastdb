import 'dart:async';
import 'dart:js_interop';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:web/web.dart' as web;
import '../storage_strategy.dart';

/// [StorageStrategy] for Web that uses `IndexedDB` for persistence.
///
/// Data is stored as fixed-size **chunks** (64 KB each). Chunks are loaded
/// **lazily** from IndexedDB on first access rather than all at once at
/// [open] time, keeping RAM usage proportional to the *working set* rather
/// than the full database size.
///
/// A bounded LRU cache of at most [_maxCachedChunks] chunks (32 × 64 KB =
/// 2 MB) is maintained in RAM. Clean chunks are evicted when the cache is
/// full; dirty (not-yet-flushed) chunks are never evicted.
///
/// ## Format in IndexedDB (objectStore `"ffastdb_store"`)
///   - `<name>_meta`  → usedSize (JSUint8Array, 4 bytes LE)
///   - `<name>_c<i>`  → chunk *i* (JSUint8Array, up to [_chunkSize] bytes)
///
/// ## Backward compatibility
/// If the legacy single-key format (`<name>_buffer`) is detected on [open],
/// the bytes are loaded into the chunk cache and migrated to the chunked
/// format on the next [flush].
class IndexedDbStorageStrategy implements StorageStrategy {
  /// Chunk size in bytes — 64 KB gives good granularity vs. IDB overhead.
  static const int _chunkSize = 65536;

  /// Maximum number of chunks kept in the in-memory LRU cache.
  /// 32 × 64 KB = 2 MB — enough to hold the full B-Tree working set for
  /// most apps while keeping RAM bounded regardless of database size.
  static const int _maxCachedChunks = 32;

  final String _dbName;
  final String _storeName = 'ffastdb_store';
  final String _dataKey;

  web.IDBDatabase? _database;

  // ── Sparse chunk cache ───────────────────────────────────────────────────
  // Only chunks that have been accessed (read or written) since open() are
  // held in RAM. The map is bounded by _maxCachedChunks via LRU eviction.
  final Map<int, Uint8List> _chunks = {};

  // LRU order: front = oldest, back = most-recently-used.
  // List.remove() is O(n) but with ≤ 32 entries that's negligible.
  final List<int> _lruOrder = [];

  int _usedSize = 0;

  /// Chunk indices modified since the last [flush].
  /// Dirty chunks are never evicted from [_chunks] until after flush commits.
  final Set<int> _dirtyChunks = {};

  /// Number of chunk keys persisted in IndexedDB after the last flush.
  /// Used to delete orphan chunks after [truncate] / compact.
  int _persistedChunkCount = 0;

  /// `true` when the legacy single-key format was loaded and needs migration
  /// to the chunked format on the next [flush].
  bool _migrateLegacy = false;

  IndexedDbStorageStrategy(this._dbName) : _dataKey = _dbName;

  // ── Open ─────────────────────────────────────────────────────────────────

  @override
  Future<void> open() async {
    final completer = Completer<void>();
    final request = web.window.indexedDB.open(_dbName, 1);

    request.onupgradeneeded = (web.IDBVersionChangeEvent event) {
      final db = request.result as web.IDBDatabase;
      db.createObjectStore(_storeName);
    }.toJS;

    request.onsuccess = (web.Event event) {
      _database = request.result as web.IDBDatabase;
      _loadMetadata().then((_) => completer.complete()).catchError((e) {
        // FAIL-CLOSED: a metadata load failure must not silently start fresh
        // because the next flush() would overwrite persisted data.
        completer.completeError(
            'IndexedDbStorageStrategy: failed to load metadata: $e');
      });
    }.toJS;

    request.onerror = (web.Event event) {
      completer.completeError('Failed to open IndexedDB');
    }.toJS;

    return completer.future;
  }

  /// Reads only the `_meta` key to learn [_usedSize] and [_persistedChunkCount].
  /// Chunk data is NOT loaded here — it is fetched lazily on first [read].
  Future<void> _loadMetadata() async {
    // 1. Chunked format: read metadata only.
    final meta = await _idbGet('${_dataKey}_meta');
    if (meta != null) {
      final metaBytes = (meta as JSUint8Array).toDart;
      if (metaBytes.length >= 4) {
        _usedSize = _readUint32(metaBytes, 0);
        _persistedChunkCount = _usedSize == 0
            ? 0
            : (_usedSize + _chunkSize - 1) ~/ _chunkSize;
      }
      return;
    }

    // 2. Legacy single-key format (`<name>_buffer`): load all bytes and split
    //    into chunks so the next flush() migrates to the chunked format.
    final legacy = await _idbGet('${_dataKey}_buffer');
    if (legacy != null) {
      final bytes = (legacy as JSUint8Array).toDart;
      _writeInternal(0, bytes); // populates _chunks and marks them dirty
      _migrateLegacy = true;
    }
  }

  // ── Read ─────────────────────────────────────────────────────────────────

  @override
  Future<Uint8List> read(int offset, int size) async {
    if (offset >= _usedSize) return Uint8List(size);

    // Fast path: every required chunk is already in the cache.
    final cached = readSync(offset, size);
    if (cached != null) return cached;

    // Slow path: load missing chunks from IndexedDB, then serve from cache.
    final end = min(offset + size, _usedSize);
    final firstChunk = offset ~/ _chunkSize;
    final lastChunk = (end - 1) ~/ _chunkSize;
    await _loadChunksFromIdb(firstChunk, lastChunk);

    return readSync(offset, size) ?? Uint8List(size);
  }

  // ── Write ────────────────────────────────────────────────────────────────

  @override
  Future<void> write(int offset, Uint8List data) async {
    _writeInternal(offset, data);
  }

  /// Writes [data] starting at [offset], splitting across chunk boundaries.
  /// All affected chunks are allocated in [_chunks] and marked dirty.
  void _writeInternal(int offset, Uint8List data) {
    if (data.isEmpty) return;
    final required = offset + data.length;
    if (required > _usedSize) _usedSize = required;

    int remaining = data.length;
    int dataOff = 0;
    int cur = offset;

    while (remaining > 0) {
      final ci = cur ~/ _chunkSize;
      final chunkOff = cur % _chunkSize;
      final n = min(_chunkSize - chunkOff, remaining);

      final chunk = _getOrCreateChunk(ci);
      chunk.setRange(chunkOff, chunkOff + n, data, dataOff);
      _dirtyChunks.add(ci);

      cur += n;
      dataOff += n;
      remaining -= n;
    }
  }

  // ── Flush ────────────────────────────────────────────────────────────────

  @override
  Future<void> flush() async {
    if (_database == null) return;
    if (_dirtyChunks.isEmpty && !_migrateLegacy) return;

    final completer = Completer<void>();
    final txn = _database!.transaction(_storeName.toJS, 'readwrite');
    final store = txn.objectStore(_storeName);

    // Snapshot the dirty set for this transaction. New dirty markers added
    // while the IDB transaction is in-flight must survive for the next flush.
    final flushedChunks = Set<int>.of(_dirtyChunks);

    for (final ci in flushedChunks) {
      final chunk = _chunks[ci];
      if (chunk == null) continue;

      final start = ci * _chunkSize;
      if (start >= _usedSize) continue;
      final end = min(start + _chunkSize, _usedSize);

      // Write only the used portion of this chunk.
      final slice = (end - start) < chunk.length
          ? Uint8List.sublistView(chunk, 0, end - start)
          : chunk;
      store.put(slice.toJS as JSAny, '${_dataKey}_c$ci'.toJS);
    }

    // Delete orphan chunks beyond the current usedSize (after truncate/compact).
    final currentChunkCount =
        _usedSize == 0 ? 0 : (_usedSize + _chunkSize - 1) ~/ _chunkSize;
    for (int i = currentChunkCount; i < _persistedChunkCount; i++) {
      store.delete('${_dataKey}_c$i'.toJS);
    }

    // Persist metadata (usedSize as 4-byte LE).
    final metaBytes = Uint8List(4);
    _writeUint32(metaBytes, 0, _usedSize);
    store.put(metaBytes.toJS as JSAny, '${_dataKey}_meta'.toJS);

    // Delete legacy key on first migration flush.
    if (_migrateLegacy) {
      store.delete('${_dataKey}_buffer'.toJS);
      _migrateLegacy = false;
    }

    txn.oncomplete = ((web.Event e) {
      // Clear dirty markers only after the transaction actually commits.
      // Markers added while in-flight survive for the next flush().
      _dirtyChunks.removeAll(flushedChunks);
      _persistedChunkCount = currentChunkCount;
      completer.complete();
    }).toJS;
    txn.onerror = ((web.Event e) =>
        completer.completeError('Failed to flush chunks to IndexedDB')).toJS;

    return completer.future;
  }

  // ── Truncate ─────────────────────────────────────────────────────────────

  @override
  Future<void> truncate(int size) async {
    if (size >= _usedSize) return;
    _usedSize = size;

    // Remove chunks entirely beyond the new size from both cache and dirty set.
    final maxChunk = size == 0 ? -1 : (size - 1) ~/ _chunkSize;
    _dirtyChunks.removeWhere((c) => c > maxChunk);
    final toEvict = _chunks.keys.where((c) => c > maxChunk).toList();
    for (final c in toEvict) {
      _chunks.remove(c);
      _lruOrder.remove(c);
    }
    // Orphan chunk deletion in IndexedDB happens in flush().
  }

  @override
  Future<void> close() async {
    await flush();
    _database?.close();
    _database = null;
  }

  @override
  Future<int> get size async => _usedSize;

  // ── Synchronous fast paths ────────────────────────────────────────────────

  @override
  StorageStrategy? get innerStorage => null;

  @override
  int? get sizeSync => _usedSize;

  @override
  bool get needsExplicitFlush => true;

  @override
  bool writeSync(int offset, Uint8List data) {
    _writeInternal(offset, data);
    return true;
  }

  /// Returns data if every required chunk is in the cache, or `null` on a
  /// cache miss so FastDB can fall back to the async [read] path.
  @override
  Uint8List? readSync(int offset, int size) {
    if (offset >= _usedSize) return Uint8List(size);

    final end = min(offset + size, _usedSize);
    final result = Uint8List(size);
    int cur = offset;
    int resultOff = 0;

    while (cur < end) {
      final ci = cur ~/ _chunkSize;
      final chunkOff = cur % _chunkSize;
      final n = min(_chunkSize - chunkOff, end - cur);

      final chunk = _chunks[ci];
      if (chunk == null) return null; // Cache miss → caller uses async read()

      _touchLru(ci);
      result.setRange(resultOff, resultOff + n, chunk, chunkOff);
      cur += n;
      resultOff += n;
    }

    return result;
  }

  // ── LRU cache helpers ────────────────────────────────────────────────────

  /// Returns the chunk at [ci], allocating a zeroed one if absent.
  /// Marks it as most-recently-used and evicts stale clean chunks if needed.
  Uint8List _getOrCreateChunk(int ci) {
    var chunk = _chunks[ci];
    if (chunk == null) {
      chunk = Uint8List(_chunkSize);
      _chunks[ci] = chunk;
    }
    _touchLru(ci);
    return chunk;
  }

  /// Moves [ci] to the back of [_lruOrder] (most-recently-used) and evicts
  /// the oldest clean chunk(s) when the cache exceeds [_maxCachedChunks].
  void _touchLru(int ci) {
    _lruOrder.remove(ci);
    _lruOrder.add(ci);
    _evictCleanChunks();
  }

  /// Evicts the oldest clean (non-dirty) chunks until [_chunks] fits within
  /// [_maxCachedChunks]. Dirty chunks are skipped — they must stay in RAM
  /// until [flush] persists them.
  void _evictCleanChunks() {
    int i = 0;
    while (_chunks.length > _maxCachedChunks && i < _lruOrder.length) {
      final candidate = _lruOrder[i];
      if (!_dirtyChunks.contains(candidate)) {
        _chunks.remove(candidate);
        _lruOrder.removeAt(i);
        // Don't advance i — the next element shifted into position i.
      } else {
        i++;
      }
    }
  }

  // ── IDB helpers ──────────────────────────────────────────────────────────

  /// Fetches chunks [firstChunk]..[lastChunk] (inclusive) that are not
  /// already in [_chunks] using a single readonly IDB transaction, then
  /// adds them to the cache and runs one eviction pass.
  Future<void> _loadChunksFromIdb(int firstChunk, int lastChunk) async {
    final toLoad = <int>[
      for (int i = firstChunk; i <= lastChunk; i++)
        if (!_chunks.containsKey(i)) i,
    ];
    if (toLoad.isEmpty) return;

    final completer = Completer<void>();
    final txn = _database!.transaction(_storeName.toJS, 'readonly');
    final store = txn.objectStore(_storeName);

    for (final idx in toLoad) {
      final req = store.get('${_dataKey}_c$idx'.toJS);
      req.onsuccess = ((web.Event e) {
        final r = req.result;
        final chunk = Uint8List(_chunkSize);
        if (r != null) {
          final bytes = (r as JSUint8Array).toDart;
          chunk.setRange(0, bytes.length, bytes);
        }
        _chunks[idx] = chunk;
        // Add to LRU without triggering eviction yet — all loaded chunks
        // must survive until the transaction completes.
        _lruOrder.remove(idx);
        _lruOrder.add(idx);
      }).toJS;
    }

    txn.oncomplete = ((web.Event e) {
      // Single eviction pass after all chunks are loaded.
      _evictCleanChunks();
      completer.complete();
    }).toJS;
    txn.onerror = ((web.Event e) => completer.completeError(
        StateError(
            'IndexedDbStorageStrategy: failed to load chunks $toLoad'))).toJS;

    return completer.future;
  }

  /// Reads a single value from IndexedDB by [key].
  Future<JSAny?> _idbGet(String key) {
    final completer = Completer<JSAny?>();
    final txn = _database!.transaction(_storeName.toJS, 'readonly');
    final store = txn.objectStore(_storeName);
    final req = store.get(key.toJS);
    req.onsuccess = ((web.Event e) => completer.complete(req.result)).toJS;
    req.onerror = ((web.Event e) => completer.complete(null)).toJS;
    return completer.future;
  }

  // ── Byte helpers ──────────────────────────────────────────────────────────

  static int _readUint32(Uint8List b, int off) =>
      (b[off] & 0xFF) |
      ((b[off + 1] & 0xFF) << 8) |
      ((b[off + 2] & 0xFF) << 16) |
      ((b[off + 3] & 0xFF) << 24);

  static void _writeUint32(Uint8List b, int off, int v) {
    b[off] = v & 0xFF;
    b[off + 1] = (v >> 8) & 0xFF;
    b[off + 2] = (v >> 16) & 0xFF;
    b[off + 3] = (v >> 24) & 0xFF;
  }
}
