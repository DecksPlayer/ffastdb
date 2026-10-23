part of 'fastdb.dart';

/// Manages database persistence, header I/O, index serialization, and compaction.
class _StorageManager {
  final FastDB _db;

  _StorageManager(this._db);

  /// Saves the database header (magic bytes, root page, next ID, schema version).
  Future<void> saveHeader() async {
    final header = Uint8List(16);
    header[0] = 70; header[1] = 68; header[2] = 66; header[3] = 50; // "FDB2"
    _db._writeInt32(header, 4, _db._primaryIndex.rootPage ?? 0);
    _db._writeInt32(header, 8, _db._nextId);
    _db._writeInt32(header, 12, _db._schemaVersion);
    await _db.storage.write(0, header);
    // Persist the free-page list alongside (bytes 25+; no-op unless changed).
    await _db._pageManager.persistFreeList();
  }

  /// Persists all secondary indexes to storage using typeTag serialization.
  Future<void> saveIndexes() async {
    final persistable = <({int typeTag, Uint8List blob})>[];
    for (final entry in _db._secondaryIndexes.entries) {
      if (entry.value is HashIndex) {
        final blob = (entry.value as HashIndex).serialize();
        if (blob.isNotEmpty) persistable.add((typeTag: 1, blob: blob));
      } else if (entry.value is SortedIndex) {
        final blob = (entry.value as SortedIndex).serialize();
        if (blob.isNotEmpty) persistable.add((typeTag: 2, blob: blob));
      } else if (entry.value is BitmaskIndex) {
        final blob = (entry.value as BitmaskIndex).serialize();
        if (blob.isNotEmpty) persistable.add((typeTag: 3, blob: blob));
      } else if (entry.value is FtsIndex) {
        final blob = (entry.value as FtsIndex).serialize();
        if (blob.isNotEmpty) persistable.add((typeTag: 4, blob: blob));
      } else if (entry.value is CompositeIndex) {
        final blob = (entry.value as CompositeIndex).serialize();
        if (blob.isNotEmpty) persistable.add((typeTag: 5, blob: blob));
      }
    }
    if (persistable.isEmpty) return;

    final buf = BytesBuilder();
    final countBytes = Uint8List(4);
    countBytes[0] = persistable.length & 0xFF;
    countBytes[1] = (persistable.length >> 8) & 0xFF;
    countBytes[2] = (persistable.length >> 16) & 0xFF;
    countBytes[3] = (persistable.length >> 24) & 0xFF;
    buf.add(countBytes);

    for (final entry in persistable) {
      final blob = entry.blob;
      buf.addByte(entry.typeTag);
      final lenBytes = Uint8List(4);
      lenBytes[0] = blob.length & 0xFF;
      lenBytes[1] = (blob.length >> 8) & 0xFF;
      lenBytes[2] = (blob.length >> 16) & 0xFF;
      lenBytes[3] = (blob.length >> 24) & 0xFF;
      buf.add(lenBytes);
      buf.add(blob);
    }

    final payload = buf.toBytes();
    final meta = await _db.storage.read(16, 8);
    final prevOffset = _db._readInt32(meta, 0);
    final prevLen = _db._readInt32(meta, 4);
    final currentSize = await _db.storage.size;
    final int writeOffset;
    if (prevOffset > 0 && prevLen > 0 && payload.length <= prevLen) {
      writeOffset = prevOffset;
    } else {
      // Round up to next page boundary to keep B-Tree pages aligned if they grow later
      writeOffset = ((currentSize + PageManager.pageSize - 1) ~/ PageManager.pageSize) * PageManager.pageSize;
    }
    await _db.storage.write(writeOffset, payload);
    // Reclaim the tail ONLY when the previous blob was the last thing in the
    // file. Documents and B-Tree pages appended after it (the normal case
    // once the database is reopened) live past prevOffset + prevLen —
    // truncating unconditionally destroyed them whenever the index shrank.
    if (writeOffset == prevOffset &&
        payload.length < prevLen &&
        prevOffset + prevLen >= currentSize) {
      await _db.storage.truncate(writeOffset + payload.length);
    }
    // Single-file mode: documents share this file — the next one must land
    // after the blob. In dual-file mode _dataOffset is an offset into
    // dataStorage and must not be touched (it used to be overwritten with
    // this file's offset, so the next insert clobbered existing documents).
    if (_db.dataStorage == null) {
      _db._dataOffset = _db.storage.sizeSync ?? await _db.storage.size;
    }
    final header = Uint8List(8);
    _db._writeInt32(header, 0, writeOffset);
    _db._writeInt32(header, 4, payload.length);
    await _db.storage.write(16, header);
  }

  /// Loads persisted secondary indexes from storage.
  /// Returns a set of keys for the indexes that were successfully loaded.
  Future<Set<String>> loadIndexes() async {
    final loadedKeys = <String>{};
    try {
      final meta = await _db.storage.read(16, 8);
      final idxOffset = _db._readInt32(meta, 0);
      final idxLength = _db._readInt32(meta, 4);
      if (idxOffset <= 0 || idxLength <= 0) return loadedKeys;
      final blob = await _db.storage.read(idxOffset, idxLength);
      int off = 0;
      final count = _db._readInt32(blob, off); off += 4;
      for (int i = 0; i < count; i++) {
        final typeTag = blob[off]; off += 1;
        final len = _db._readInt32(blob, off); off += 4;
        final indexBytes = blob.sublist(off, off + len);
        off += len;
        SecondaryIndex idx;
        switch (typeTag) {
          case 1: idx = HashIndex.deserialize(indexBytes);
          case 2: idx = SortedIndex.deserialize(indexBytes);
          case 3: idx = BitmaskIndex.deserialize(indexBytes);
          case 4: idx = FtsIndex.deserialize(indexBytes);
          case 5: idx = CompositeIndex.deserialize(indexBytes);
          default: continue;
        }

        // The _secondaryIndexes map key is NOT always idx.fieldName: FtsIndex
        // is keyed "_fts_<field>" (idx.fieldName is just the plain field —
        // shared with, e.g., a SortedIndex on the same field, which is a
        // DIFFERENT registered index) and CompositeIndex is keyed by its
        // joined field names. Compute the real key FIRST — looking up by
        // idx.fieldName directly could find an unrelated index sharing that
        // plain field name and reject this one as a "type mismatch",
        // silently discarding it even though nothing is actually wrong.
        String key = idx.fieldName;
        if (idx is FtsIndex) {
          key = '_fts_${idx.fieldName}';
        } else if (idx is CompositeIndex) {
          key = idx.fieldNames.join('+');
        }

        // If the user changed index type between startups (e.g. HashIndex →
        // SortedIndex), the pre-registered type wins — discard the old blob so
        // _rebuildSecondaryIndexes() will rebuild with the correct type.
        final existing = _db._secondaryIndexes[key];
        if (existing != null && existing.runtimeType != idx.runtimeType) {
          continue;
        }

        _db._secondaryIndexes[key] = idx;
        loadedKeys.add(key);
      }
    } catch (_) {}
    return loadedKeys;
  }

  /// Checks if auto-compaction threshold is exceeded and compacts if needed.
  /// Called after every delete — O(1): the live count is maintained
  /// incrementally (the old code scanned the whole B-Tree each time).
  Future<void> maybeAutoCompact() async {
    final threshold = _db._autoCompactThreshold;
    if (threshold <= 0) return;
    final deleted = _db._deletedCount;
    if (deleted == 0) return;
    final live = await _db._countLive();
    if (deleted / (live + deleted) >= threshold) {
      // In a transaction: compaction rewrites the file in place — a crash
      // half-way must roll back, not leave a half-moved file.
      await _db._runTransaction(compactImpl);
    }
  }

  /// Resets the dead-slot counter used by [maybeAutoCompact].
  void _resetDeletedCount() => _db._deletedCount = 0;

  /// Compacts the database: removes dead records (deleted / overwritten
  /// documents, abandoned index blobs, old B-Tree pages) and rebuilds the
  /// B-Tree.
  ///
  /// Live records are slid towards the start of the data region byte-for-byte
  /// ([_slideRecords]) — no document is deserialized and secondary indexes
  /// stay valid (ids do not change). Peak memory is one (id, offset) pair per
  /// document plus one chunk of records; the old single-file path buffered
  /// EVERY document in RAM and re-indexed them all.
  ///
  /// Must run inside a transaction ([FastDB.compact], [maybeAutoCompact]):
  /// with a WAL the whole rewrite then commits or rolls back atomically. In
  /// dual-file mode the data file is not covered by the WAL.
  Future<void> compactImpl() async {
    final single = _db.dataStorage == null;
    final target = _db.dataStorage ?? _db.storage;
    final slid = await _slideRecords(target, single ? PageManager.pageSize : 0);

    // The old tree is dead — its pages were overwritten (single-file) or are
    // rebuilt below (dual-file). Rebuild it from the new offsets.
    _db._pageManager.clearCache();
    _db._pageManager.clearFreeList();
    _db._primaryIndex.clearNodeCache();
    _db._primaryIndex.rootPage = null;
    // Zero the secondary-index blob pointer (bytes 16-23): its old location
    // is gone; saveIndexes() below writes a fresh blob.
    await _db.storage.write(16, Uint8List(8));
    if (single) {
      await _db.storage.truncate(slid.end);
    } else {
      await _db.dataStorage!.truncate(slid.end);
      await _db.storage.truncate(PageManager.pageSize); // header page only
    }
    await _db._primaryIndex.bulkLoad([const MapEntry(0, 0), ...slid.moved]);
    await _db._pageManager.flushDirty();
    _db._dataOffset = single
        ? (_db.storage.sizeSync ?? await _db.storage.size)
        : slid.end;

    for (final id in slid.dropped) {
      for (final idx in _db._secondaryIndexes.values) {
        idx.removeById(id);
      }
    }
    _db._liveCount = slid.moved.length;
    _resetDeletedCount();
    await saveIndexes();
    await saveHeader();
    await _db.storage.flush();
    if (_db.dataStorage != null) await _db.dataStorage!.flush();
  }

  /// Moves every live record to `[start, end)` of [target], packed, keeping
  /// their relative order. Records are visited in ascending OFFSET order and
  /// moved in chunks: a chunk is fully read before it is written, and its
  /// packed output ends at or before the chunk's original end, so a write
  /// never reaches a record that has not been read yet. Chunked I/O also
  /// keeps the WAL read-your-writes overlay cheap (few, large entries).
  ///
  /// Returns the new (id → offset) entries sorted by id, the end of the
  /// packed region, and the ids of unreadable records (dropped).
  Future<({List<MapEntry<int, int>> moved, int end, List<int> dropped})>
      _slideRecords(StorageStrategy target, int start) async {
    final entries =
        await _db._primaryIndex.rangeSearchEntries(1, _db._nextId - 1);
    entries.sort((a, b) => a.value.compareTo(b.value));

    const chunkRecords = 2000;
    final moved = <MapEntry<int, int>>[];
    final dropped = <int>[];
    int writePos = start;
    for (int i = 0; i < entries.length; i += chunkRecords) {
      final end = i + chunkRecords < entries.length ? i + chunkRecords : entries.length;
      final chunk = entries.sublist(i, end);
      final raws = await _db._batchReadRaw(chunk);
      final out = BytesBuilder(copy: false);
      final chunkStart = writePos;
      bool inPlace = true;
      for (int j = 0; j < chunk.length; j++) {
        final raw = raws[j];
        if (raw == null) {
          dropped.add(chunk[j].key);
          continue;
        }
        if (chunk[j].value != writePos) inPlace = false;
        moved.add(MapEntry(chunk[j].key, writePos));
        out.add(raw);
        writePos += raw.length;
      }
      // Leading records that are already packed need no rewrite.
      if (!inPlace && out.length > 0) await target.write(chunkStart, out.takeBytes());
      await Future.delayed(Duration.zero);
    }
    moved.sort((a, b) => a.key.compareTo(b.key));
    return (moved: moved, end: writePos, dropped: dropped);
  }

  /// Wipes all documents from the database in O(1) time by truncating storage
  /// and resetting B-Tree and secondary indexes.
  Future<void> clearImpl() async {
    final wal = _db._wal;
    if (!_db._inTransaction && wal != null) await wal.beginTransaction();
    try {
      await _db.storage.truncate(PageManager.pageSize);
      if (_db.dataStorage != null) {
        await _db.dataStorage!.truncate(0);
      }
      _db._pageManager.clearCache();
      _db._pageManager.clearFreeList();
      _db._primaryIndex.clearNodeCache();
      _db._primaryIndex.rootPage = null;
      for (final idx in _db._secondaryIndexes.values) {
        idx.clear();
      }

      _db._nextId = 1;
      _resetDeletedCount();
      _db._liveCount = 0;
      _db._batchEntries.clear();

      await _db._primaryIndex.insert(0, 0);
      _db._dataOffset = await _db.storage.size;

      // Zero out the secondary-index block pointer (bytes 16-23) so that
      // loadIndexes() on the next open does not find a stale offset/length
      // and reload old index data from beyond the now-truncated file.
      await _db.storage.write(16, Uint8List(8));

      await saveHeader();
      await _db.storage.flush();
      if (_db.dataStorage != null) await _db.dataStorage!.flush();
      _db._queryCache.clear();
      if (!_db._inTransaction && wal != null) await wal.commit();
      _db._notifyWatchersBatch();
    } catch (e) {
      if (!_db._inTransaction && wal != null) await wal.rollback();
      rethrow;
    }
  }

  /// Applies schema migrations to all documents.
  Future<void> runMigrations(
      int currentVersion, int targetVersion, Map<int, dynamic Function(dynamic)>? migrations) async {
    final allIds = await _db._primaryIndex.rangeSearch(1, _db._nextId - 1);
    if (allIds.isEmpty) return;
    for (int i = 0; i < allIds.length; i++) {
      final id = allIds[i];
      final doc = await _db._findById(id);
      if (doc != null) {
        dynamic migratedDoc = doc;
        if (migrations != null) {
          for (int v = currentVersion; v < targetVersion; v++) {
            if (migrations.containsKey(v)) {
              migratedDoc = migrations[v]!(migratedDoc);
            }
          }
        }
        
        final targetStorage = _db.dataStorage ?? _db.storage;
        final newOffset = _db._dataOffset;
        final data = _db._serialize(migratedDoc, id: id);
        await targetStorage.write(newOffset, data);
        await _db._primaryIndex.insert(id, newOffset);
        // NOT `_dataOffset += data.length`: in single-file mode the insert
        // above may allocate a B-Tree page right after this document, and
        // the next document would be written over it.
        await _db._syncDataOffset(data.length);
      }
      if (i > 0 && i % 250 == 0) await Future.delayed(Duration.zero);
    }
    _resetDeletedCount();
    if (_db.dataStorage != null) await _db.dataStorage!.truncate(_db._dataOffset);
    await _db.storage.flush();
    if (_db.dataStorage != null) await _db.dataStorage!.flush();
  }
}
