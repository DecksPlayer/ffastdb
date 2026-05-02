part of 'fastdb.dart';

/// Manages Create, Read, Update, Delete operations for FastDB.
class _CrudOperations {
  final FastDB _db;

  _CrudOperations(this._db);

  Future<int> insertImpl(dynamic doc) async {
    final wal = _db._wal;
    final hasWal = !_db._inTransaction && !_db._batchMode && wal != null;
    final id = _db._nextId++;
    
    // Log operation before starting
    if (!_db._inTransaction && !_db._batchMode) {
      await _db._opLog.log('insert', id: id, data: doc);
    }

    if (hasWal) await wal.beginTransaction();
    
    try {
      final data = _db._serialize(doc, id: id);
      final targetStorage = _db.dataStorage ?? _db.storage;
      final offset = _db._dataOffset;

      if (!targetStorage.writeSync(offset, data)) {
        await targetStorage.write(offset, data);
      }

      if (_db._batchMode) {
        _db._batchEntries.add(MapEntry(id, offset));
      } else {
        await _db._primaryIndex.insert(id, offset);
      }
      await _db._syncDataOffset(data.length);

      if (!_db._batchMode && targetStorage.needsExplicitFlush) {
        await targetStorage.flush();
        if (_db.dataStorage != null) await _db.storage.flush();
        await _db._saveHeader();
      }

      if (doc is Map) _db._indexDocument(id, Map<String, dynamic>.from(doc));
      if (!_db._batchMode) {
        QueryBuilder.clearCache();
        _db._notifyWatchers(doc);
      }
      if (hasWal) await wal.commit();
      if (!_db._inTransaction && !_db._batchMode) await _db._opLog.clear();
      return id;
    } catch (e) {
      if (hasWal) await wal.rollback();
      rethrow;
    }
  }

  /// Encapsulates the logic for put() with manual key.
  Future<void> putImpl(int id, dynamic value) async {
    final oldOffset = await _db._primaryIndex.search(id);
    
    // Log operation before starting
    if (!_db._inTransaction && !_db._batchMode) {
      await _db._opLog.log('put', id: id, data: value);
    }

    final wal = _db._wal;
    final hasWal = !_db._inTransaction && !_db._batchMode && wal != null;
    if (hasWal) await wal.beginTransaction();
    
    try {
      if (oldOffset != null) {
        _db._deletedCount++;
        final existing = await _db._readAt(oldOffset);
        if (existing is Map) {
          _db._removeDocument(id, Map<String, dynamic>.from(existing));
        } else {
          for (final idx in _db._secondaryIndexes.values) {
            idx.removeById(id);
          }
        }
      }

      final data = _db._serialize(value, id: id);
      final targetStorage = _db.dataStorage ?? _db.storage;
      final offset = _db._dataOffset;
      if (!targetStorage.writeSync(offset, data)) {
        await targetStorage.write(offset, data);
      }
      if (!_db._batchMode && _db.storage.needsExplicitFlush) await targetStorage.flush();
      await _db._primaryIndex.insert(id, offset);
      await _db._syncDataOffset(data.length);
      if (id >= _db._nextId) _db._nextId = id + 1;
      if (!_db._batchMode && _db.storage.needsExplicitFlush) {
        await _db.storage.flush();
        await _db._saveHeader();
      }
      if (value is Map) _db._indexDocument(id, Map<String, dynamic>.from(value));
      QueryBuilder.clearCache();
      _db._notifyWatchers(value);
      if (hasWal) await wal.commit();
      if (!_db._inTransaction && !_db._batchMode) await _db._opLog.clear();
    } catch (e) {
      if (hasWal) await wal.rollback();
      rethrow;
    }
  }

  /// Encapsulates the logic for update() with field merging.
  Future<bool> updateImpl(int id, Map<String, dynamic> fields) async {
    final existing = await _db._findById(id);
    if (existing == null) return false;
    if (existing is! Map) {
      throw UnsupportedError(
          'update() requires a Map document. TypeAdapter objects must be '
          'replaced via put() or insert().');
    }
    final oldOffset = await _db._primaryIndex.search(id);
    final merged = Map<String, dynamic>.from(existing as Map<String, dynamic>)..addAll(fields);

    // Log operation before starting
    if (!_db._inTransaction && !_db._batchMode) {
      await _db._opLog.log('update', id: id, data: fields);
    }

    final wal = _db._wal;
    final hasWal = !_db._inTransaction && !_db._batchMode && wal != null;
    if (hasWal) await wal.beginTransaction();
    try {
      if (oldOffset != null) _db._deletedCount++;

      _db._removeDocument(id, Map<String, dynamic>.from(existing));

      final data = _db._serialize(merged, id: id);
      final targetStorage = _db.dataStorage ?? _db.storage;
      final offset = _db._dataOffset;

      if (!targetStorage.writeSync(offset, data)) {
        await targetStorage.write(offset, data);
      }

      await _db._primaryIndex.insert(id, offset);
      await _db._syncDataOffset(data.length);
      _db._indexDocument(id, Map<String, dynamic>.from(merged));

      if (!_db._batchMode) {
        await targetStorage.flush();
        if (_db.dataStorage != null) await _db.storage.flush();
        await _db._saveHeader();
        QueryBuilder.clearCache();
        _db._notifyWatchers(merged);
      }
      if (hasWal) await wal.commit();
      if (!_db._inTransaction && !_db._batchMode) await _db._opLog.clear();
      return true;
    } catch (e) {
      if (hasWal) await wal.rollback();
      rethrow;
    }
  }

  /// Encapsulates the logic for delete() operations.
  Future<bool> deleteImpl(int id) async {
    final offset = await _db._primaryIndex.search(id);
    if (offset == null) return false;
    if (_db.dataStorage == null && offset < PageManager.pageSize) return false;
    final doc = await _db._readAt(offset);
    // Log operation before starting
    if (!_db._inTransaction && !_db._batchMode) {
      await _db._opLog.log('delete', id: id);
    }

    final wal = _db._wal;
    final hasWal = !_db._inTransaction && !_db._batchMode && wal != null;
    if (hasWal) await wal.beginTransaction();
    try {
      await _db._primaryIndex.delete(id);
      await _db._syncDataOffset(0);
      if (doc is Map) {
        _db._removeDocument(id, Map<String, dynamic>.from(doc));
      } else {
        for (final idx in _db._secondaryIndexes.values) {
          idx.removeById(id);
        }
      }
      _db._deletedCount++;
      if (!_db._batchMode) {
        await _db._saveHeader();
        QueryBuilder.clearCache();
      }
      if (hasWal) await wal.commit();
      if (!_db._inTransaction && !_db._batchMode) await _db._opLog.clear();
      if (_db._autoCompactThreshold > 0 && !_db._inTransaction && !_db._batchMode) {
        await _db._maybeAutoCompact();
      }
      return true;
    } catch (e) {
      if (hasWal) await wal.rollback();
      rethrow;
    }
  }
}
