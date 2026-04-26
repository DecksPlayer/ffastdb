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
  Future<void> reindex([String? field]) async {
    if (field != null) {
      final idx = _db._secondaryIndexes[field];
      if (idx == null) throw ArgumentError('No index registered for field "$field"');
      idx.clear();
      final rawIds = await _db._primaryIndex.rangeSearch(1, _db._nextId - 1);
      // BUG FIX: Deduplicate IDs — rangeSearch may return same ID multiple times
      // from B-Tree structural inconsistencies in pre-0.0.24 databases.
      final allIds = LinkedHashSet<int>.from(rawIds).toList();
      for (int i = 0; i < allIds.length; i++) {
        final doc = await _db.findById(allIds[i]);
        if (doc is Map) {
          final castedDoc = Map<String, dynamic>.from(doc);
          final val = castedDoc[field];
          if (val != null) idx.add(allIds[i], val);
        }
        if (i > 0 && i % 250 == 0) await Future.delayed(Duration.zero);
      }
      // Invalidate query cache since the index was rebuilt
      QueryBuilder.clearCache();
    } else {
      await rebuildSecondaryIndexes();
      // Invalidate query cache since all indexes were rebuilt
      QueryBuilder.clearCache();
    }
  }

  /// Indexes a single document into all secondary indexes.
  void indexDocument(int id, Map<String, dynamic> doc) {
    for (final idx in _db._secondaryIndexes.values) {
      if (idx is CompositeIndex) {
        final values = idx.fieldNames.map((f) => doc[f]).toList();
        // Only index if at least one field is present (to allow partial composites)
        if (values.any((v) => v != null)) {
          idx.add(id, values);
        }
      } else {
        final val = doc[idx.fieldName];
        if (val != null) idx.add(id, val);
      }
    }
  }

  /// Removes a document from all secondary indexes.
  void removeDocument(int id, Map<String, dynamic> doc) {
    for (final idx in _db._secondaryIndexes.values) {
      if (idx is CompositeIndex) {
        final values = idx.fieldNames.map((f) => doc[f]).toList();
        if (values.any((v) => v != null)) {
          idx.remove(id, values);
        }
      } else {
        final val = doc[idx.fieldName];
        if (val != null) idx.remove(id, val);
      }
    }
  }

  /// Rebuilds all secondary indexes from live documents.
  /// Deduplicates IDs to prevent index corruption from B-Tree structural issues.
  Future<void> rebuildSecondaryIndexes({void Function(double)? onProgress}) async {
    if (_db._secondaryIndexes.isEmpty) return;
    for (final idx in _db._secondaryIndexes.values) idx.clear();
    final rawIds = await _db._primaryIndex.rangeSearch(1, 0x7FFFFFFF);
    // BUG FIX: Deduplicate IDs — rangeSearch may return same ID multiple times
    // from B-Tree structural inconsistencies in pre-0.0.24 databases.
    // This was exposed when 0.0.23 added implicit rebuildSecondaryIndexes() on startup.
    final allIds = LinkedHashSet<int>.from(rawIds).toList();
    for (int i = 0; i < allIds.length; i++) {
      final id = allIds[i];
      try {
        final doc = await _db.findById(id);
        if (doc is Map) {
          indexDocument(id, Map<String, dynamic>.from(doc));
        }
      } catch (_) {
        // Corrupt document — skip and continue indexing the rest.
        // It will be removed on the next compact().
      }
      if (i > 0 && i % 250 == 0) {
        if (onProgress != null) onProgress(i / allIds.length);
        await Future.delayed(Duration.zero);
      }
    }
    if (onProgress != null) onProgress(1.0);
  }
}
