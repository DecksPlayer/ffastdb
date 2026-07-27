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
    // Checkpoint pre-existing dirty pages BEFORE the batch (and its WAL tx):
    // the failure path discards dirty pages, which must contain ONLY batch
    // writes, never earlier committed state.
    await _db._pageManager.flushDirty();
    _db._batchMode = true;
    _db._batchEntries.clear();

    final ids = List<int>.generate(docs.length, (i) => _db._nextId++);

    // Save B-Tree state so a failed batch can be rolled back in memory too
    // (the WAL rollback only discards the on-disk writes).
    final savedRoot = _db._primaryIndex.rootPage;

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
      _db._queryCache.clear();
      _db._disableWriteBehind();
      
      if (!_db._inTransaction && wal != null) await wal.commit();
      
      await _db._syncDataOffset(0);
      
      // Notify watchers ONCE at the end of the entire batch
      _db._notifyWatchersBatch();
    } catch (e) {
      _db._batchMode = false;
      _db._batchEntries.clear();
      _db._disableWriteBehind();
      // Roll back in-memory state: discard dirty pages from the failed batch
      // (they would bypass the WAL rollback on the next flushDirty) and
      // restore the B-Tree root so stale nodes are not reachable.
      _db._pageManager.clearDirtyPages();
      _db._pageManager.clearLruCache();
      _db._primaryIndex.rootPage = savedRoot;
      _db._primaryIndex.clearNodeCache();
      // Revert _nextId so failed batch IDs are not burned... unless the batch
      // ran inside a transaction, which manages its own rollback.
      if (!_db._inTransaction) _db._nextId = ids.first;
      if (!_db._inTransaction && _db._wal != null) await _db._wal!.rollback();
      rethrow;
    }
    return ids;
  }
}
