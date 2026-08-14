part of 'fastdb.dart';

/// Manages Create, Read, Update, Delete operations for FastDB.
class _CrudOperations {
  final FastDB _db;

  _CrudOperations(this._db);

  Future<int> insertImpl(dynamic doc) async {
    final wal = _db._wal;
    final hasWal = !_db._inTransaction && !_db._batchMode && wal != null;
    final id = _db._nextId++;

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

      if (!_db._batchMode) {
        // Header FIRST: it must become durable in the same flush/transaction
        // as the document + B-Tree pages, or a dirty close leaves persisted
        // docs unreachable (stale rootPage/nextId). With a WAL it is
        // journaled in the same tx; wal.commit() then provides durability —
        // an intermediate flush of the main file would be a wasted fsync.
        await _db._saveHeader();
        if (!hasWal && targetStorage.needsExplicitFlush) {
          await targetStorage.flush();
          if (_db.dataStorage != null) await _db.storage.flush();
        }
      }

      if (doc is Map) _db._indexDocument(id, Map<String, dynamic>.from(doc));
      if (!_db._batchMode) {
        _db._queryCache.clear();
        _db._notifyWatchers(doc);
      }
      if (hasWal) await wal.commit();
      // Log AFTER commit: if the process dies between log() and commit(),
      // _replayOpLog() would re-insert an operation that never completed.
      if (!_db._inTransaction && !_db._batchMode && !_db._isReplayingOpLog) {
        await _db._opLog.log('insert', id: id, data: doc);
      }
      if (!_db._inTransaction && !_db._batchMode) await _db._opLog.maybeCheckpoint();
      return id;
    } catch (e) {
      if (hasWal) await wal.rollback();
      rethrow;
    }
  }

  /// Encapsulates the logic for put() with manual key.
  Future<void> putImpl(int id, dynamic value) async {
    // ids <= 0 would be persisted but NEVER reachable by queries
    // (rangeSearch/isNull-complement start at 1) — reject them loudly.
    if (id < 1) {
      throw ArgumentError.value(
          id, 'id', 'FastDB ids must be >= 1 (ids <= 0 are not reachable by queries)');
    }
    final oldOffset = await _db._primaryIndex.search(id);

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
      await _db._primaryIndex.insert(id, offset);
      await _db._syncDataOffset(data.length);
      if (id >= _db._nextId) _db._nextId = id + 1;
      if (!_db._batchMode) {
        // Header FIRST so it is durable in the same flush/tx (see insertImpl).
        await _db._saveHeader();
        // Flush skipped with a WAL: wal.commit() provides durability.
        if (!hasWal && _db.storage.needsExplicitFlush) {
          await targetStorage.flush();
          if (_db.dataStorage != null) await _db.storage.flush();
        }
      }
      if (value is Map) _db._indexDocument(id, Map<String, dynamic>.from(value));
      _db._queryCache.clear();
      _db._notifyWatchers(value);
      if (hasWal) await wal.commit();
      // Log AFTER commit (see insertImpl for rationale).
      if (!_db._inTransaction && !_db._batchMode && !_db._isReplayingOpLog) {
        await _db._opLog.log('put', id: id, data: value);
      }
      if (!_db._inTransaction && !_db._batchMode) await _db._opLog.maybeCheckpoint();
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
        // Header FIRST so it is durable in the same flush (see insertImpl).
        await _db._saveHeader();
        // Skipped with a WAL: wal.commit() below provides durability.
        if (!hasWal && targetStorage.needsExplicitFlush) {
          await targetStorage.flush();
          if (_db.dataStorage != null) await _db.storage.flush();
        }
        _db._queryCache.clear();
        _db._notifyWatchers(merged);
      }
      if (hasWal) await wal.commit();
      // Log AFTER commit (see insertImpl for rationale).
      if (!_db._inTransaction && !_db._batchMode && !_db._isReplayingOpLog) {
        await _db._opLog.log('update', id: id, data: fields);
      }
      if (!_db._inTransaction && !_db._batchMode) await _db._opLog.maybeCheckpoint();
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
        // Header FIRST, then flush: delete must be durable on storages with
        // explicit flush (IndexedDB) — previously it never flushed here and a
        // dirty tab close silently lost the deletion.
        await _db._saveHeader();
        final targetStorage = _db.dataStorage ?? _db.storage;
        // Skipped with a WAL: wal.commit() below provides durability.
        if (!hasWal && targetStorage.needsExplicitFlush) {
          await targetStorage.flush();
          if (_db.dataStorage != null) await _db.storage.flush();
        }
        _db._queryCache.clear();
        _db._notifyWatchers(doc);
      }
      if (hasWal) await wal.commit();
      // Log AFTER commit (see insertImpl for rationale).
      if (!_db._inTransaction && !_db._batchMode && !_db._isReplayingOpLog) {
        await _db._opLog.log('delete', id: id);
      }
      if (!_db._inTransaction && !_db._batchMode) await _db._opLog.maybeCheckpoint();
      if (_db._autoCompactThreshold > 0 && !_db._inTransaction && !_db._batchMode) {
        await _db._maybeAutoCompact();
      }
      return true;
    } catch (e) {
      if (hasWal) await wal.rollback();
      rethrow;
    }
  }

  Future<int> upsertImpl(int id, Map<String, dynamic> fields) async {
    final existing = await _db._findById(id);
    if (existing != null) {
      await updateImpl(id, fields);
      return id;
    } else {
      // Honor the manual id: put() writes with the given key (and bumps
      // _nextId), unlike insert() which always auto-increments.
      final doc = Map<String, dynamic>.from(fields)..['ffdbID'] = id;
      await putImpl(id, doc);
      return id;
    }
  }

  Future<int> upsertWhereImpl(
    String uniqueField,
    dynamic value,
    Map<String, dynamic> fields,
  ) async {
    final q = QueryBuilder(_db._secondaryIndexes, _db._findById, _db._rangeSearch, _db.watch, _db._queryCache)
        .where(uniqueField)
        .equals(value);
    final ids = await q.findIds();
    if (ids.isNotEmpty) {
      final id = ids.first;
      await updateImpl(id, fields);
      return id;
    } else {
      final doc = Map<String, dynamic>.from(fields);
      doc[uniqueField] = value;
      return insertImpl(doc);
    }
  }
}
