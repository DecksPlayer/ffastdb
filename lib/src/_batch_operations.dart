part of 'fastdb.dart';

/// Manages Batch and Transaction operations for FastDB.
class _BatchOperations {
  final FastDB _db;

  _BatchOperations(this._db);

  /// Executes bulk insert of multiple documents with memory-efficient chunking.
  Future<List<int>> insertAllImpl(List<dynamic> docs) async {
    if (docs.isEmpty) return [];
    
    // Chunk size: 5000 docs per block to limit RAM peak
    const chunkSize = 5000;
    
    _db._enableWriteBehind();
    _db._batchMode = true;
    _db._batchEntries.clear();

    final ids = List<int>.generate(docs.length, (i) => _db._nextId++);

    try {
      if (!_db._inTransaction && _db._wal != null) await _db._wal!.beginTransaction();

      final targetStorage = _db.dataStorage ?? _db.storage;
      
      // Process in chunks to keep memory usage low
      for (int i = 0; i < docs.length; i += chunkSize) {
        final end = (i + chunkSize < docs.length) ? i + chunkSize : docs.length;
        
        // 1. Write data and collect batch entries for this chunk
        for (int j = i; j < end; j++) {
          final data = _db._serialize(docs[j], id: ids[j]);
          final offset = _db._dataOffset;
          if (!targetStorage.writeSync(offset, data)) {
            await targetStorage.write(offset, data);
          }
          _db._batchEntries.add(MapEntry(ids[j], offset));
          _db._dataOffset += data.length;
        }

        // 2. Load chunk into primary index
        await _db._primaryIndex.bulkLoad(_db._batchEntries);
        _db._batchEntries.clear();

        // 3. Index chunk into secondary indexes
        for (int j = i; j < end; j++) {
          if (docs[j] is Map) {
            _db._indexDocument(ids[j], Map<String, dynamic>.from(docs[j]));
          }
        }
        
        // 4. Checkpoint header to ensure _nextId recovery works if crash occurs
        // This is crucial for Duplicate ID prevention.
        await _db._saveHeader();

        // 5. Update _dataOffset to account for any B-Tree pages allocated during bulkLoad
        await _db._syncDataOffset(0);

        // Yield to event loop to prevent blocking and allow GC
        if (_runningOnWeb) {
          await targetStorage.flush();
          if (_db.dataStorage != null) await _db.storage.flush();
        }
        await Future.delayed(Duration.zero);
      }

      final wal = _db._wal;
      _db._batchMode = false;
      await _db._pageManager.flushDirty();
      await _db.dataStorage?.flush();
      await _db.storage.flush();
      await _db._saveHeader();
      QueryBuilder.clearCache();
      _db._disableWriteBehind();
      
      if (!_db._inTransaction && wal != null) await wal.commit();
      
      await _db._syncDataOffset(0);
      
      // Notify watchers ONCE at the end of the entire batch
      _db._notifyWatchersBatch();
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
