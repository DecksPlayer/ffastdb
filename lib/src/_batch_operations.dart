part of 'fastdb.dart';

/// Manages Batch and Transaction operations for FastDB.
class _BatchOperations {
  final FastDB _db;

  _BatchOperations(this._db);

  /// Executes bulk insert of multiple documents.
  Future<List<int>> insertAllImpl(List<dynamic> docs) async {
    if (docs.isEmpty) return [];
    _db._enableWriteBehind();
    _db._batchMode = true;
    _db._batchEntries.clear();

    final ids = <int>[];

    try {
      for (int i = 0; i < docs.length; i++) {
        ids.add(_db._nextId++);
      }

      if (!_db._inTransaction && _db._wal != null) await _db._wal!.beginTransaction();

      final targetStorage = _db.dataStorage ?? _db.storage;
      for (int i = 0; i < docs.length; i++) {
        final data = _db._serialize(docs[i], id: ids[i]);
        final offset = _db._dataOffset;
        if (!targetStorage.writeSync(offset, data)) {
          await targetStorage.write(offset, data);
        }
        _db._batchEntries.add(MapEntry(ids[i], offset));
        _db._dataOffset += data.length;
        if (_runningOnWeb && i > 0 && i % 500 == 0) await Future.delayed(Duration.zero);
      }

      await _db._primaryIndex.bulkLoad(_db._batchEntries);
      _db._batchEntries.clear();

      for (int i = 0; i < docs.length; i++) {
        if (docs[i] is Map<String, dynamic>) _db._indexDocument(ids[i], docs[i] as Map<String, dynamic>);
      }

      final wal = _db._wal;
      _db._batchMode = false;
      await _db._pageManager.flushDirty();
      await _db.dataStorage?.flush();
      await _db.storage.flush();
      await _db._saveHeader();
      _db._disableWriteBehind();
      if (!_db._inTransaction && wal != null) await wal.commit();
      if (_db.dataStorage == null) {
        _db._dataOffset = await _db.storage.size;
      }
      for (final doc in docs) {
        _db._notifyWatchers(doc);
      }
    } catch (e) {
      _db._batchMode = false;
      _db._batchEntries.clear();
      _db._disableWriteBehind();
      if (!_db._inTransaction && _db._wal != null) await _db._wal!.rollback();
      rethrow;
    }
    return ids;
  }
}
