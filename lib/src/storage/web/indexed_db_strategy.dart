import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;
import '../storage_strategy.dart';

/// [StorageStrategy] for Web that uses `IndexedDB` for persistence.
///
/// Data is stored as fixed-size **chunks** (64 KB each) so that [flush] only
/// writes the chunks that were modified since the last flush.  This avoids
/// copying the entire database buffer to JavaScript on every write — the
/// primary cause of OOM crashes on web when databases grow beyond a few MB.
///
/// Format in IndexedDB (objectStore "ffastdb_store"):
///   - `<name>_meta`   → usedSize (JSUint8Array, 4 bytes LE)
///   - `<name>_c<i>`   → chunk *i* (JSUint8Array, up to [_chunkSize] bytes)
///
/// Backward-compatible: on [open], if the legacy single-key format
/// (`<name>_buffer`) is detected it is loaded and migrated to chunks on the
/// next [flush].
class IndexedDbStorageStrategy implements StorageStrategy {
  /// Chunk size in bytes.  64 KB gives a good trade-off between granularity
  /// (a 4 KB page write only dirties one chunk) and transaction overhead
  /// (a 50 MB DB ≈ 800 chunks, well within a single IDB transaction).
  static const int _chunkSize = 65536; // 64 KB

  final String _dbName;
  final String _storeName = 'ffastdb_store';
  final String _dataKey;

  web.IDBDatabase? _database;
  Uint8List _buffer = Uint8List(0);
  int _usedSize = 0;

  /// Indices of chunks modified since the last [flush].
  final Set<int> _dirtyChunks = {};

  /// Number of chunk keys persisted in IndexedDB after the last flush.
  /// Used to delete orphan chunks after [truncate] / compact.
  int _persistedChunkCount = 0;

  /// `true` when the legacy single-key format was loaded on [open] and needs
  /// migration to chunks on the next [flush].
  bool _migrateLegacy = false;

  IndexedDbStorageStrategy(this._dbName) : _dataKey = _dbName;

  // ── Open / Load ──────────────────────────────────────────────────────────

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
      _loadData().then((_) => completer.complete()).catchError((_) {
        completer.complete(); // start fresh on error
      });
    }.toJS;

    request.onerror = (web.Event event) {
      completer.completeError('Failed to open IndexedDB');
    }.toJS;

    return completer.future;
  }

  /// Loads data from IndexedDB — tries the chunked format first, then falls
  /// back to the legacy single-key format for backward compatibility.
  Future<void> _loadData() async {
    // 1. Try chunked format (has a _meta key).
    final meta = await _idbGet('${_dataKey}_meta');
    if (meta != null) {
      final metaBytes = (meta as JSUint8Array).toDart;
      if (metaBytes.length >= 4) {
        final size = _readUint32(metaBytes, 0);
        if (size > 0) await _loadChunked(size);
      }
      return;
    }

    // 2. Fallback: legacy single-key format (`<name>_buffer`).
    final legacy = await _idbGet('${_dataKey}_buffer');
    if (legacy != null) {
      _buffer = (legacy as JSUint8Array).toDart;
      _usedSize = _buffer.length;
      _migrateLegacy = true;
      // Mark every chunk dirty so the next flush() migrates to chunked format.
      _markAllChunksDirty();
    }
  }

  /// Loads all chunks from a single readonly transaction and composes the
  /// in-memory buffer.
  Future<void> _loadChunked(int size) async {
    _usedSize = size;
    final chunkCount = (size + _chunkSize - 1) ~/ _chunkSize;
    _buffer = Uint8List(_roundUpBuffer(size));
    _persistedChunkCount = chunkCount;
    if (chunkCount == 0) return;

    final completer = Completer<void>();
    final txn = _database!.transaction(_storeName.toJS, 'readonly');
    final store = txn.objectStore(_storeName);

    for (int i = 0; i < chunkCount; i++) {
      final idx = i;
      final req = store.get('${_dataKey}_c$idx'.toJS);
      req.onsuccess = ((web.Event e) {
        final r = req.result;
        if (r != null) {
          final bytes = (r as JSUint8Array).toDart;
          final start = idx * _chunkSize;
          final end = (start + bytes.length > size) ? size : start + bytes.length;
          _buffer.setRange(start, end, bytes);
        }
      }).toJS;
    }

    txn.oncomplete = ((web.Event e) => completer.complete()).toJS;
    txn.onerror = ((web.Event e) => completer.complete()).toJS;

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

  // ── Read / Write (in-memory buffer) ──────────────────────────────────────

  @override
  Future<Uint8List> read(int offset, int size) async {
    if (offset >= _usedSize) return Uint8List(size);
    final end = (offset + size > _usedSize) ? _usedSize : offset + size;
    final result = Uint8List(size);
    result.setRange(0, end - offset, _buffer, offset);
    return result;
  }

  @override
  Future<void> write(int offset, Uint8List data) async {
    _writeInternal(offset, data);
  }

  void _writeInternal(int offset, Uint8List data) {
    if (data.isEmpty) return;
    final required = offset + data.length;
    if (required > _buffer.length) {
      final newLen = _roundUpBuffer(required);
      final grown = Uint8List(newLen);
      if (_buffer.isNotEmpty) grown.setRange(0, _buffer.length, _buffer);
      _buffer = grown;
    }
    _buffer.setRange(offset, offset + data.length, data);
    if (required > _usedSize) _usedSize = required;

    // Mark affected chunks as dirty.
    final firstChunk = offset ~/ _chunkSize;
    final lastChunk = (offset + data.length - 1) ~/ _chunkSize;
    for (int c = firstChunk; c <= lastChunk; c++) {
      _dirtyChunks.add(c);
    }
  }

  // ── Flush (chunked, incremental) ─────────────────────────────────────────

  @override
  Future<void> flush() async {
    if (_database == null) return;
    if (_dirtyChunks.isEmpty && !_migrateLegacy) return;

    final completer = Completer<void>();
    final txn = _database!.transaction(_storeName.toJS, 'readwrite');
    final store = txn.objectStore(_storeName);

    // Write only dirty chunks — each JS copy is at most 64 KB instead of
    // the entire buffer, reducing peak memory from O(DB size) to O(64 KB).
    for (final ci in _dirtyChunks) {
      final start = ci * _chunkSize;
      if (start >= _usedSize) continue;
      final end = (start + _chunkSize > _usedSize) ? _usedSize : start + _chunkSize;
      final chunk = _buffer.sublist(start, end);
      store.put(chunk.toJS as JSAny, '${_dataKey}_c$ci'.toJS);
    }

    // Delete orphan chunks that are now beyond usedSize (after truncate/compact).
    final currentChunkCount =
        _usedSize == 0 ? 0 : (_usedSize + _chunkSize - 1) ~/ _chunkSize;
    for (int i = currentChunkCount; i < _persistedChunkCount; i++) {
      store.delete('${_dataKey}_c$i'.toJS);
    }

    // Persist metadata (usedSize as 4-byte LE).
    final metaBytes = Uint8List(4);
    _writeUint32(metaBytes, 0, _usedSize);
    store.put(metaBytes.toJS as JSAny, '${_dataKey}_meta'.toJS);

    // Delete legacy key on migration.
    if (_migrateLegacy) {
      store.delete('${_dataKey}_buffer'.toJS);
      _migrateLegacy = false;
    }

    txn.oncomplete = ((web.Event e) => completer.complete()).toJS;
    txn.onerror = ((web.Event e) =>
        completer.completeError('Failed to flush chunks to IndexedDB')).toJS;

    // Clear dirty state immediately so writes that arrive while the IDB
    // transaction is in-flight are captured in the next flush().
    _dirtyChunks.clear();
    _persistedChunkCount = currentChunkCount;

    return completer.future;
  }

  // ── Truncate ─────────────────────────────────────────────────────────────

  @override
  Future<void> truncate(int size) async {
    if (size >= _usedSize) return;
    _usedSize = size;
    // Remove dirty markers for chunks now entirely beyond the new size.
    final maxChunk = size == 0 ? -1 : (size - 1) ~/ _chunkSize;
    _dirtyChunks.removeWhere((c) => c > maxChunk);
    // Reclaim backing-buffer memory on significant shrink.
    if (_buffer.length > size + 512 * 1024) {
      final shrunk = Uint8List(size > 0 ? _roundUpBuffer(size) : 0);
      if (size > 0) shrunk.setRange(0, size, _buffer);
      _buffer = shrunk;
    }
    // Orphan chunk cleanup in IndexedDB happens in flush().
  }

  @override
  Future<void> close() async {
    await flush();
  }

  @override
  Future<int> get size async => _usedSize;

  // ── Synchronous fast paths ────────────────────────────────────────────────

  @override
  int? get sizeSync => _usedSize;

  @override
  bool get needsExplicitFlush => true;

  @override
  bool writeSync(int offset, Uint8List data) {
    _writeInternal(offset, data);
    return true;
  }

  @override
  Uint8List? readSync(int offset, int size) {
    if (offset >= _usedSize) return Uint8List(size);
    final end = (offset + size > _usedSize) ? _usedSize : offset + size;
    final result = Uint8List(size);
    result.setRange(0, end - offset, _buffer, offset);
    return result;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _markAllChunksDirty() {
    final n = (_usedSize + _chunkSize - 1) ~/ _chunkSize;
    for (int i = 0; i < n; i++) {
      _dirtyChunks.add(i);
    }
  }

  /// Rounds [n] up to the next power-of-two (minimum 4096).
  static int _roundUpBuffer(int n) {
    if (n <= 4096) return 4096;
    int v = n - 1;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    return v + 1;
  }

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
