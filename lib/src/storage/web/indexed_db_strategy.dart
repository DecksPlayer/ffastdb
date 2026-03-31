// This file is only compiled on web and uses IndexedDB for storage.
import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import '../storage_strategy.dart';

// ── IndexedDB JS interop ─────────────────────────────────────────────────────

@JS('indexedDB')
external JSObject get _indexedDB;

extension type _IDBFactory(JSObject _) {
  external _IDBOpenDBRequest open(JSString name, int version);
}

extension type _IDBOpenDBRequest(JSObject _) {
  external set onupgradeneeded(JSFunction callback);
  external set onsuccess(JSFunction callback);
  external set onerror(JSFunction callback);
  external _IDBDatabase get result;
}

extension type _IDBDatabase(JSObject _) {
  external _IDBObjectStore createObjectStore(JSString name);
  external _IDBTransaction transaction(JSArray<JSString> stores, JSString mode);
}

extension type _IDBTransaction(JSObject _) {
  external _IDBObjectStore objectStore(JSString name);
  external set oncomplete(JSFunction callback);
  external set onerror(JSFunction callback);
}

extension type _IDBObjectStore(JSObject _) {
  external _IDBRequest get(JSAny key);
  external _IDBRequest put(JSAny value, JSAny key);
}

extension type _IDBRequest(JSObject _) {
  external set onsuccess(JSFunction callback);
  external set onerror(JSFunction callback);
  external JSAny? get result;
}

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
  
  _IDBDatabase? _database;
  Uint8List _buffer = Uint8List(0);
  int _usedSize = 0;

  IndexedDbStorageStrategy(this._dbName) : _dataKey = '${_dbName}_buffer';

  @override
  Future<void> open() async {
    final completer = Completer<void>();
    final factory = _IDBFactory(_indexedDB);
    final request = factory.open(_dbName.toJS, 1);

    request.onupgradeneeded = ((JSObject event) {
      final db = request.result;
      db.createObjectStore(_storeName.toJS);
    }).toJS;

    request.onsuccess = ((JSObject event) async {
      _database = request.result;
      
      // Load initial data
      final txn = _database!.transaction([_storeName.toJS].toJS, 'readonly'.toJS);
      final store = txn.objectStore(_storeName.toJS);
      final getRequest = store.get(_dataKey.toJS);
      
      getRequest.onsuccess = ((JSObject e) {
        final result = getRequest.result;
        if (result != null) {
          // Convert JS TypedArray back to Dart Uint8List
          final jsArray = result as JSUint8Array;
          _buffer = jsArray.toDart;
          _usedSize = _buffer.length;
        }
        completer.complete();
      }).toJS;
      
      getRequest.onerror = ((JSObject e) {
        completer.complete(); // Start fresh if error
      }).toJS;
    }).toJS;

    request.onerror = ((JSObject event) {
      completer.completeError('Failed to open IndexedDB');
    }).toJS;

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
  }

  @override
  Future<void> flush() async {
    if (_database == null) return;
    
    final completer = Completer<void>();
    final txn = _database!.transaction([_storeName.toJS].toJS, 'readwrite'.toJS);
    final store = txn.objectStore(_storeName.toJS);
    
    // We only store the used partial to save space, or a copy to avoid mutation issues
    final snapshot = _buffer.sublist(0, _usedSize);
    final putRequest = store.put(snapshot.toJS, _dataKey.toJS);
    
    putRequest.onsuccess = ((JSObject e) => completer.complete()).toJS;
    putRequest.onerror = ((JSObject e) => completer.completeError('Failed to flush to IndexedDB')).toJS;
    
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
    if (size < _usedSize) _usedSize = size;
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
