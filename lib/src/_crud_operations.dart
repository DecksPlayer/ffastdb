part of 'fastdb.dart';

/// Manages Create, Read, Update, Delete operations for FastDB.
class _CrudOperations {
  final FastDB _db;

  _CrudOperations(this._db);

  /// Encapsulates the logic for insert() without assigning ID upfront.
  /// Called by FastDB.insert() after acquiring the exclusive lock.
  Future<int> insertImpl(dynamic doc) async {
    final wal = _db._wal;
    final hasWal = !_db._inTransaction && !_db._batchMode && wal != null;
    if (hasWal) await wal.beginTransaction();
    
    try {
      final id = _db._nextId++;
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

      _db._dataOffset += data.length;

      if (!_db._batchMode && targetStorage.needsExplicitFlush) {
        await targetStorage.flush();
        if (_db.dataStorage != null) await _db.storage.flush();
        await _db._saveHeader();
      }

      if (doc is Map<String, dynamic>) _db._indexDocument(id, doc);
      if (!_db._batchMode) _db._notifyWatchers(doc);
      if (hasWal) await wal.commit();
      return id;
    } catch (e) {
      if (hasWal) await wal.rollback();
      rethrow;
    }
  }

  /// Encapsulates the logic for put() with manual key.
  Future<void> putImpl(int id, dynamic value) async {
    final oldOffset = await _db._primaryIndex.search(id);
    if (oldOffset != null) _db._deletedCount++;

    final wal = _db._wal;
    if (!_db._inTransaction && wal != null) await wal.beginTransaction();
    try {
      final data = _db._serialize(value, id: id);
      final targetStorage = _db.dataStorage ?? _db.storage;
      final offset = _db._dataOffset;
      if (!targetStorage.writeSync(offset, data)) {
        await targetStorage.write(offset, data);
      }
      if (_db.storage.needsExplicitFlush) await targetStorage.flush();
      _db._dataOffset += data.length;
      await _db._primaryIndex.insert(id, offset);
      if (id >= _db._nextId) _db._nextId = id + 1;
      if (_db.storage.needsExplicitFlush) {
        await _db.storage.flush();
        await _db._saveHeader();
      }
      if (value is Map<String, dynamic>) _db._indexDocument(id, value);
      _db._notifyWatchers(value);
      if (!_db._inTransaction && wal != null) await wal.commit();
    } catch (e) {
      if (!_db._inTransaction && wal != null) await wal.rollback();
      rethrow;
    }
  }

  /// Encapsulates the logic for update() with field merging.
  Future<bool> updateImpl(int id, Map<String, dynamic> fields) async {
    final existing = await _db.findById(id);
    if (existing == null) return false;
    if (existing is! Map) {
      throw UnsupportedError(
          'update() requires a Map document. TypeAdapter objects must be '
          'replaced via put() or insert().');
    }
    final oldOffset = await _db._primaryIndex.search(id);
    final merged = Map<String, dynamic>.from(existing as Map<String, dynamic>)..addAll(fields);

    final wal = _db._wal;
    if (!_db._inTransaction && wal != null) await wal.beginTransaction();
    try {
      if (oldOffset != null) _db._deletedCount++;

      for (final idx in _db._secondaryIndexes.values) {
        idx.remove(id, existing[idx.fieldName]);
      }

      final data = _db._serialize(merged, id: id);
      final targetStorage = _db.dataStorage ?? _db.storage;
      final offset = _db._dataOffset;

      if (!targetStorage.writeSync(offset, data)) {
        await targetStorage.write(offset, data);
      }

      _db._dataOffset += data.length;

      await _db._primaryIndex.insert(id, offset);
      _db._indexDocument(id, merged);

      if (!_db._batchMode) {
        await targetStorage.flush();
        if (_db.dataStorage != null) await _db.storage.flush();
        await _db._saveHeader();
        _db._notifyWatchers(merged);
      }
      if (!_db._inTransaction && wal != null) await wal.commit();
      return true;
    } catch (e) {
      if (!_db._inTransaction && wal != null) await wal.rollback();
      rethrow;
    }
  }

  /// Encapsulates the logic for delete() operations.
  Future<bool> deleteImpl(int id) async {
    final offset = await _db._primaryIndex.search(id);
    if (offset == null) return false;
    if (_db.dataStorage == null && offset < PageManager.pageSize) return false;
    final doc = await _db._readAt(offset);
    final wal = _db._wal;
    if (!_db._inTransaction && wal != null) await wal.beginTransaction();
    try {
      await _db._primaryIndex.delete(id);
      if (doc is Map) {
        for (final idx in _db._secondaryIndexes.values) {
          idx.remove(id, doc[idx.fieldName]);
        }
      } else {
        for (final idx in _db._secondaryIndexes.values) {
          idx.removeById(id);
        }
      }
      _db._deletedCount++;
      if (!_db._batchMode) await _db._saveHeader();
      if (!_db._inTransaction && wal != null) await wal.commit();
      if (_db._autoCompactThreshold > 0 && !_db._inTransaction && !_db._batchMode) {
        await _db._maybeAutoCompact();
      }
      return true;
    } catch (e) {
      if (!_db._inTransaction && wal != null) await wal.rollback();
      rethrow;
    }
  }
}
