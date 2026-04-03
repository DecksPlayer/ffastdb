import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;
import '../storage_strategy.dart';

// ── IndexedDB JS interop via package:web ─────────────────────────────────────
// No more manual definitions needed, fully standard now.
// ─────────────────────────────────────────────────────────────────────────────

/// [StorageStrategy] for Web that uses `IndexedDB` for persistence.
/// 
/// Unlike `localStorage`, `IndexedDB` has much larger storage limits and 
/// supports binary data directly.
class IndexedDbStorageStrategy implements StorageStrategy {
  final String _dbName;
  final String _storeName = 'ffastdb_store';
  // BUG FIX: Previously used a fixed key 'db_buffer' shared across all
  // database instances, causing data collision when opening multiple databases
  // (e.g., 'users' and 'products') in the same web application.
  final String _dataKey;
  
  web.IDBDatabase? _database;
  Uint8List _buffer = Uint8List(0);
  int _usedSize = 0;

  /// True when [_buffer] has been modified since the last [flush()].
  /// Prevents redundant IndexedDB puts when fastdb calls flush() multiple
  /// times per operation (e.g. after every insert/update/delete).
  bool _dirty = false;

  IndexedDbStorageStrategy(this._dbName) : _dataKey = '${_dbName}_buffer';

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
      
      // Load initial data. IDB transaction can take a single string or a List.
      // package:web sometimes expects JSAny (which can be a single string or array).
      final txn = _database!.transaction(_storeName.toJS, 'readonly');
      final store = txn.objectStore(_storeName);
      final getRequest = store.get(_dataKey.toJS);
      
      getRequest.onsuccess = (web.Event e) {
        final result = getRequest.result;
        if (result != null) {
          // Convert JS TypedArray back to Dart Uint8List
          final jsArray = result as JSUint8Array;
          _buffer = jsArray.toDart;
          _usedSize = _buffer.length;
        }
        completer.complete();
      }.toJS;
      
      getRequest.onerror = (web.Event e) {
        completer.complete(); // Start fresh if error
      }.toJS;
    }.toJS;

    request.onerror = (web.Event event) {
      completer.completeError('Failed to open IndexedDB');
    }.toJS;

    return completer.future;
  }

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
    final required = offset + data.length;
    if (required > _buffer.length) {
      int newLen = _buffer.isEmpty ? 4096 : _buffer.length;
      while (newLen < required) newLen *= 2;
      final grown = Uint8List(newLen);
      if (_buffer.isNotEmpty) grown.setRange(0, _buffer.length, _buffer);
      _buffer = grown;
    }
    _buffer.setRange(offset, offset + data.length, data);
    if (required > _usedSize) _usedSize = required;
    _dirty = true;
  }

  @override
  Future<void> flush() async {
    if (_database == null || !_dirty) return;
    // Reset before the async put so writes that arrive while the IDB
    // transaction is in-flight are captured in the next flush().
    _dirty = false;
    
    final completer = Completer<void>();
    final txn = _database!.transaction(_storeName.toJS, 'readwrite');
    final store = txn.objectStore(_storeName);
    
    // Use a typed-data view to avoid an extra Dart-side copy of the buffer.
    // When the backing allocation is oversized (due to doubling growth),
    // the view limits the JS Uint8Array to only the live bytes.
    final view = _usedSize == _buffer.length
        ? _buffer
        : _buffer.buffer.asUint8List(0, _usedSize);
    final jsBuffer = view.toJS;
    final putRequest = store.put(jsBuffer as JSAny, _dataKey.toJS);
    
    putRequest.onsuccess = ((web.Event e) => completer.complete()).toJS;
    putRequest.onerror = ((web.Event e) => completer.completeError('Failed to flush to IndexedDB')).toJS;
    
    return completer.future;
  }

  @override
  Future<void> close() async {
    await flush();
    // IndexedDB doesn't have an explicit close on the factory, 
    // but the database instance can be closed.
    // (Actual closing is handled by JS garbage collection usually).
  }

  @override
  Future<int> get size async => _usedSize;

  @override
  Future<void> truncate(int size) async {
    if (size >= _usedSize) return;
    _usedSize = size;
    // BUG FIX: Reclaim backing-buffer memory when the used size shrinks
    // significantly (e.g. after compact()). Without this, a DB that grew
    // to 50 MB and was then compacted to 5 MB still holds a 64 MB buffer
    // in RAM until the page reloads — because the "file" is entirely in RAM.
    if (_buffer.length > size + 512 * 1024) { // >512 KB overhead
      final shrunk = Uint8List(size);
      if (size > 0) shrunk.setRange(0, size, _buffer);
      _buffer = shrunk;
    }
  }

  // ── Synchronous fast paths ────────────────────────────────────────────────

  @override
  int? get sizeSync => _usedSize;

  @override
  bool get needsExplicitFlush => true; // Essential to call flush() for persistence

  @override
  bool writeSync(int offset, Uint8List data) {
    // RAM write is sync, but persistence is async (requires flush)
    write(offset, data);
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
}
