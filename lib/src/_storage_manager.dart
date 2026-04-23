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
    final int writeOffset;
    if (prevOffset > 0 && prevLen > 0 && payload.length <= prevLen) {
      writeOffset = prevOffset;
    } else {
      // Round up to next page boundary to keep B-Tree pages aligned if they grow later
      final currentSize = await _db.storage.size;
      writeOffset = ((currentSize + PageManager.pageSize - 1) ~/ PageManager.pageSize) * PageManager.pageSize;
    }
    await _db.storage.write(writeOffset, payload);
    // Update data offset so subsequent writes (docs/more indexes) don't overlap
    _db._dataOffset = writeOffset + payload.length;
    if (prevOffset > 0 && prevLen > 0 && writeOffset == prevOffset && payload.length < prevLen) {
      await _db.storage.truncate(writeOffset + payload.length);
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
        // If the user changed index type between startups (e.g. HashIndex →
        // SortedIndex), the pre-registered type wins — discard the old blob so
        // _rebuildSecondaryIndexes() will rebuild with the correct type.
        final existing = _db._secondaryIndexes[idx.fieldName];
        if (existing != null && existing.runtimeType != idx.runtimeType) {
          continue;
        }

        String key = idx.fieldName;
        if (idx is FtsIndex) {
          key = '_fts_${idx.fieldName}';
        } else if (idx is CompositeIndex) {
          key = idx.fieldNames.join('+');
        }
        _db._secondaryIndexes[key] = idx;
        loadedKeys.add(key);
      }
    } catch (_) {}
    return loadedKeys;
  }

  /// Checks if auto-compaction threshold is exceeded and compacts if needed.
  Future<void> maybeAutoCompact() async {
    if (_db._autoCompactThreshold <= 0) return;
    final liveIds = await _db._primaryIndex.rangeSearch(1, _db._nextId - 1);
    final deleted = _db._deletedCount;
    final total = liveIds.length + deleted;
    if (total == 0) return;
    if (deleted / total >= _db._autoCompactThreshold) {
      await compactImpl();
      // BUG FIX: Reset _deletedCount after successful compaction to prevent
      // infinite re-triggering of auto-compact on every subsequent operation.
      _db._deletedCount = 0;
    }
  }

  /// Compacts the database by removing deleted entries and rewriting all data.
  Future<void> compactImpl() async {
    final allIds = await _db._primaryIndex.rangeSearch(1, _db._nextId - 1);
    if (allIds.isEmpty) return;

    if (_db.dataStorage != null) {
      // ── OOM-Safe Streaming Compaction (Dual-file mode) ────────────────────
      // We can overwrite the data file safely because the B-Tree index is in a 
      // separate file (storage). This allows us to process documents one by one
      // without buffering them all in RAM.
      
      // 1. Get current offsets for all IDs to ensure we don't need the B-Tree nodes 
      // during the write phase? No, findById already does that.
      // Since dataStorage != storage, writing to dataStorage is always safe.
      
      int writePos = 0;
      for (int i = 0; i < allIds.length; i++) {
        final id = allIds[i];
        final doc = await _db._findById(id);
        if (doc != null) {
          final data = _db._serialize(doc, id: id);
          await _db.dataStorage!.write(writePos, data);
          await _db._primaryIndex.insert(id, writePos);
          writePos += data.length;
        }
        if (i > 0 && i % 250 == 0) await Future.delayed(Duration.zero);
      }
      _db._dataOffset = writePos;
      await _db.dataStorage!.truncate(_db._dataOffset);
      await _db._pageManager.flushDirty();
      _db._pageManager.clearCache();
      _db._primaryIndex.clearNodeCache();
    } else {
      // ── Single-file mode: full rebuild ────────────────────────────────────
      // In single-file mode, B-Tree and data share the same file. 
      // Truncating or overwriting is destructive to the index we need for findById.
      // We must buffer the documents before rebuilding.
      
      final docs = <int, dynamic>{};
      for (int i = 0; i < allIds.length; i++) {
        final id = allIds[i];
        final doc = await _db._findById(id);
        if (doc != null) docs[id] = doc;
        if (i > 0 && i % 250 == 0) await Future.delayed(Duration.zero);
      }

      await _db.storage.truncate(PageManager.pageSize); // keep only the header page
      _db._pageManager.clearCache();                    // discard all cached/dirty B-Tree pages
      _db._primaryIndex.clearNodeCache();
      _db._primaryIndex.rootPage = null;                // force a fresh root on first insert
      for (final idx in _db._secondaryIndexes.values) idx.clear();

      // Create the initial sentinel entry (id=0, offset=0) — same as open().
      await _db._primaryIndex.insert(0, 0);
      // Mark header dirty so clean-flag byte is written below.
      if (_db.storage.needsExplicitFlush) {
        await _db.storage.write(24, Uint8List(1)); // dirty flag — forces index rebuild on next open
      }
      _db._dataOffset = await _db.storage.size;

      int i = 0;
      for (final entry in docs.entries) {
        final data = _db._serialize(entry.value, id: entry.key);
        await _db.storage.write(_db._dataOffset, data);
        await _db._primaryIndex.insert(entry.key, _db._dataOffset);
        if (entry.value is Map<String, dynamic>) {
          _db._indexDocument(entry.key, entry.value as Map<String, dynamic>);
        }
        // Track actual file end including any new B-Tree pages allocated during insert.
        _db._dataOffset = _db.storage.sizeSync ?? await _db.storage.size;
        if (i > 0 && i % 250 == 0) await Future.delayed(Duration.zero);
        i++;
      }
      await _db._pageManager.flushDirty();
    }

    _db._deletedCount = 0;
    await saveHeader();
    await _db.storage.flush();
    if (_db.dataStorage != null) await _db.dataStorage!.flush();
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
        _db._dataOffset += data.length;
        await _db._primaryIndex.insert(id, newOffset);
      }
      if (i > 0 && i % 250 == 0) await Future.delayed(Duration.zero);
    }
    _db._deletedCount = 0;
    if (_db.dataStorage != null) await _db.dataStorage!.truncate(_db._dataOffset);
    await _db.storage.flush();
    if (_db.dataStorage != null) await _db.dataStorage!.flush();
  }
}
