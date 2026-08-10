part of 'fastdb.dart';

/// Manages index registration, creation, and maintenance for FastDB.
class IndexManager {
  final FastDB _db;

  IndexManager(this._db);

  /// Access to all registered secondary indexes.
  Map<String, SecondaryIndex> get all => _db._secondaryIndexes;

  /// Registers a TypeAdapter for custom serialization of type [T].
  void registerAdapter<T>(TypeAdapter<T> adapter) {
    _db._registry.registerAdapter(adapter);
  }

  /// Creates an O(1) hash-based secondary index on [fieldName].
  void addIndex(String fieldName) {
    _db._secondaryIndexes.putIfAbsent(fieldName, () => HashIndex(fieldName));
  }

  /// Creates an O(log n) sorted secondary index on [fieldName].
  void addSortedIndex(String fieldName) {
    // Use putIfAbsent so that a pre-loaded index (from _loadIndexes) is not
    // overwritten with an empty one on subsequent startups.
    _db._secondaryIndexes.putIfAbsent(fieldName, () => SortedIndex(fieldName));
  }

  /// Creates a bitmask index on [fieldName].
  void addBitmaskIndex(String fieldName, {int maxDocId = 1 << 16}) {
    _db._secondaryIndexes.putIfAbsent(
        fieldName, () => BitmaskIndex(fieldName, maxDocId: maxDocId));
  }

  /// Creates a composite (multi-field) index for efficient AND queries.
  ///
  /// Composite indexes dramatically speed up queries on multiple fields:
  ///
  /// ```dart
  /// // Before: requires intersection of 2 indexes
  /// db.query()
  ///   .where('city').equals('London')
  ///   .where('status').equals('active')
  ///   .findIds();  // O(n + m) time
  ///
  /// // After: single index lookup
  /// db.indexes.addCompositeIndex(['city', 'status']);
  /// db.query()
  ///   .where('city').equals('London')
  ///   .where('status').equals('active')
  ///   .findIds();  // O(log n) time
  /// ```
  ///
  /// Performance: 10-100x speedup on multi-field AND queries.
  /// Storage: Additional memory proportional to distinct value combinations.
  void addCompositeIndex(List<String> fieldNames) {
    if (fieldNames.isEmpty) throw ArgumentError('fieldNames cannot be empty');
    if (fieldNames.length == 1) {
      addIndex(fieldNames.first);
      return;
    }

    final compositeKey = fieldNames.join('+');
    _db._secondaryIndexes.putIfAbsent(
      compositeKey,
      () => CompositeIndex(fieldNames),
    );
  }

  /// Creates a Full-Text Search (FTS) index on [fieldName].
  ///
  /// FTS indexes enable fast text searching with tokenization and inverted indexing.
  /// Supports exact word search, prefix matching, and multi-word AND queries.
  ///
  /// Performance: 100-1000x faster than `contains()` on large text fields.
  ///
  /// Example:
  /// ```dart
  /// db.addFtsIndex('description');
  /// final results = await db.query()
  ///   .where('description').fts('london')
  ///   .find();
  /// ```
  void addFtsIndex(String fieldName) {
    _db._secondaryIndexes.putIfAbsent(
      '_fts_$fieldName',
      () => FtsIndex(fieldName),
    );
  }

  /// Rebuilds secondary indexes from live documents.
  ///
  /// Pass [field] to rebuild only that index; omit to rebuild all.
  /// Deduplicates IDs from rangeSearch to guard against B-Tree structural
  /// inconsistencies from pre-0.0.24 versions.
  ///
  /// Uses concurrent batch I/O ([batchSize] reads in parallel via Future.wait)
  /// to dramatically reduce total wall-clock time compared to serial reads.
  Future<void> reindex({String? field, int batchSize = 5000}) async {
    if (field != null) {
      final idx = _db._secondaryIndexes[field];
      if (idx == null) throw ArgumentError('No index registered for field "$field"');
      idx.clear();
      final entries = await _db._primaryIndex.rangeSearchEntries(1, _db._nextId - 1);
      final seen = <int>{};
      final uniqueEntries = <MapEntry<int, int>>[];
      for (final e in entries) {
        if (seen.add(e.key)) uniqueEntries.add(e);
      }
      await _reindexField(idx, uniqueEntries, field, batchSize: batchSize);
      _db._queryCache.clear();
    } else {
      await rebuildSecondaryIndexes(batchSize: batchSize);
      _db._queryCache.clear();
    }
  }

  Future<void> _reindexField(
    SecondaryIndex idx,
    List<MapEntry<int, int>> docEntries,
    String field, {
    int batchSize = 5000,
  }) async {
    final effectiveBatchSize = batchSize > 0 ? batchSize : 5000;
    final extractedMap = <int, dynamic>{};

    for (int i = 0; i < docEntries.length; i += effectiveBatchSize) {
      final end = (i + effectiveBatchSize < docEntries.length) ? i + effectiveBatchSize : docEntries.length;
      final batch = docEntries.sublist(i, end);

      final rawResults = await Future.wait(
        batch.map((e) => _db._readRawAt(e.value)),
      );

      final rawDocs = <MapEntry<int, Uint8List>>[];
      for (int j = 0; j < batch.length; j++) {
        final raw = rawResults[j];
        if (raw != null) {
          rawDocs.add(MapEntry(batch[j].key, raw));
        }
      }

      final extractedDocs = await runParallelExtraction(rawDocs, [field]);

      for (final doc in extractedDocs) {
        final val = doc.fields[field];
        if (val != null) {
          extractedMap[doc.docId] = val;
        }
      }

      await Future.delayed(Duration.zero);
    }

    idx.addAll(extractedMap);
  }

  /// Indexes a single document into all secondary indexes.
  void indexDocument(int id, Map doc) {
    for (final idx in _db._secondaryIndexes.values) {
      if (idx is CompositeIndex) {
        final values = idx.fieldNames.map((f) => _extractField(doc, f)).toList();
        // Only index if at least one field is present (to allow partial composites)
        if (values.any((v) => v != null)) {
          idx.add(id, values);
        }
      } else {
        final val = _extractField(doc, idx.fieldName);
        if (val != null) idx.add(id, val);
      }
    }
  }

  /// Removes a document from all secondary indexes.
  void removeDocument(int id, Map doc) {
    for (final idx in _db._secondaryIndexes.values) {
      if (idx is CompositeIndex) {
        final values = idx.fieldNames.map((f) => _extractField(doc, f)).toList();
        if (values.any((v) => v != null)) {
          idx.remove(id, values);
        }
      } else {
        final val = _extractField(doc, idx.fieldName);
        if (val != null) idx.remove(id, val);
      }
    }
  }

  dynamic _extractField(Map doc, String fieldPath) {
    if (!fieldPath.contains('.')) return doc[fieldPath];
    
    final parts = fieldPath.split('.');
    dynamic current = doc;
    for (final part in parts) {
      if (current is! Map) return null;
      current = current[part];
    }
    return current;
  }

  /// Rebuilds all secondary indexes from live documents using concurrent
  /// batch reads and background Isolate field extraction.
  /// [batchSize] controls how many documents are read in parallel per iteration (default 5000).
  ///
  /// Deduplicates IDs to prevent index corruption from B-Tree structural issues.
  Future<void> rebuildSecondaryIndexes({
    void Function(double)? onProgress,
    int batchSize = 5000,
  }) async {
    if (_db._secondaryIndexes.isEmpty) return;
    for (final idx in _db._secondaryIndexes.values) idx.clear();

    final entries = await _db._primaryIndex.rangeSearchEntries(1, 0x7FFFFFFF);
    final seen = <int>{};
    final uniqueEntries = <MapEntry<int, int>>[];
    for (final e in entries) {
      if (seen.add(e.key)) uniqueEntries.add(e);
    }

    final fieldPathsSet = <String>{};
    for (final idx in _db._secondaryIndexes.values) {
      if (idx is CompositeIndex) {
        fieldPathsSet.addAll(idx.fieldNames);
      } else {
        fieldPathsSet.add(idx.fieldName);
      }
    }
    final fieldPaths = fieldPathsSet.toList();

    final effectiveBatchSize = batchSize > 0 ? batchSize : 5000;

    final fieldValuesPerIndex = <SecondaryIndex, Map<int, dynamic>>{
      for (final idx in _db._secondaryIndexes.values) idx: <int, dynamic>{}
    };

    for (int i = 0; i < uniqueEntries.length; i += effectiveBatchSize) {
      final end = (i + effectiveBatchSize < uniqueEntries.length) ? i + effectiveBatchSize : uniqueEntries.length;
      final batch = uniqueEntries.sublist(i, end);

      final rawResults = await Future.wait(
        batch.map((e) => _db._readRawAt(e.value)),
      );

      final rawDocs = <MapEntry<int, Uint8List>>[];
      for (int j = 0; j < batch.length; j++) {
        final raw = rawResults[j];
        if (raw != null) {
          rawDocs.add(MapEntry(batch[j].key, raw));
        }
      }

      final extractedDocs = await runParallelExtraction(rawDocs, fieldPaths);

      for (final doc in extractedDocs) {
        for (final idx in _db._secondaryIndexes.values) {
          if (idx is CompositeIndex) {
            final values = idx.fieldNames.map((f) => doc.fields[f]).toList();
            if (values.any((v) => v != null)) {
              idx.add(doc.docId, values);
            }
          } else {
            final val = doc.fields[idx.fieldName];
            if (val != null) {
              fieldValuesPerIndex[idx]![doc.docId] = val;
            }
          }
        }
      }

      if (onProgress != null) onProgress((end / uniqueEntries.length).clamp(0.0, 1.0));
      await Future.delayed(Duration.zero);
    }

    for (final entry in fieldValuesPerIndex.entries) {
      entry.key.addAll(entry.value);
    }

    if (onProgress != null) onProgress(1.0);
  }
}
