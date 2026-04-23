## 0.1.0

### Stable Public API Release

- **BREAKING — Public index types**: Removed `@internal` from `SecondaryIndex`, `HashIndex`, `SortedIndex`, `FtsIndex`, `BitmaskIndex`, and `CompositeIndex`. These are now part of the stable public API.
- **BREAKING — `IndexManager` is now public**: The `db.indexes` getter previously returned a private `_IndexManager` type. It now returns the public `IndexManager` class, enabling proper static typing in user code.
- **FIX — `SortedIndex.startsWith` is now O(log n)**: Replaced the O(n) `_reverse` scan with a true binary prefix search using `_lowerBound(prefix)` / `_lowerBound(nextPrefix)`. Prefix queries on `addSortedIndex` fields are now as fast as range queries.
- **FIX — `HashIndex.startsWith` was broken (returned `[]`)**: Added `startsWith` and `contains` support to `HashIndex.search()`. O(n) scan as expected for a hash structure — use `addSortedIndex` for prefix-heavy workloads.
- **CLEANUP — 0 `dart analyze` warnings**: Removed all unused imports, dead code (`_readAtSync`), unnecessary null assertions, and redundant type checks.

---

## 0.0.27

### Bug Fixes (B-Tree Stability & Indexing)

- **CRITICAL — Data corruption in single-file mode fixed**: Resolved a critical issue where document data could overwrite B-Tree index pages. Implemented `_syncDataOffset()` to ensure the document write pointer is always synchronized with the underlying storage size after every structural index operation. This prevents structural corruption under high load.

- **MODERATE — Fixed Indexing Type Strictness**: Corrected a bug where documents were silently skipped during indexing because of strict `Map<String, dynamic>` runtime type checks. The library now correctly supports all `Map` variants (including `Map<String, Object>` literals used in common application code).

- **MODERATE — Fixed Composite Index Population**: Fixed a bug where `CompositeIndex` fields were not being correctly extracted and indexed during standard `insert()` and `put()` operations.

- **CRITICAL — Fixed Index Persistence & Hot Restart failures**: Fixed an issue where `FtsIndex` and `CompositeIndex` instances were left empty in memory if they were registered manually after opening the database, causing searches to fail after a Flutter Hot Restart. `_StorageManager.loadIndexes` was updated to properly restore complex indexes and map them correctly to the query engine.

- **MODERATE — Missing indexes automatically rebuilt**: `FastDB.open()` now actively checks if any registered secondary indexes are missing from the loaded storage payload. If missing indexes are detected (e.g. after a schema update), FastDB automatically triggers a background rebuild.

- **MODERATE — Fixed `FtsIndex` search signature**: Updated `FtsIndex` to correctly implement the `SecondaryIndex.search(String operator, dynamic value)` interface, preventing runtime `Too few positional arguments` errors.

### New Features & Improvements

- **NEW — Declarative Index Registration**: Extended `openDatabase` and `FfastDb.init` to directly accept `indexes`, `sortedIndexes`, `ftsIndexes`, and `compositeIndexes`. This declarative approach guarantees that indexes are fully initialized before disk loading, resolving schema state issues during app restarts.
- **IMPROVED — Case-Insensitive Search**: The `contains()` and `startsWith()` operators are now **case-insensitive by default**. This provides a much more intuitive user experience for string-based filtering.
- **NEW — Index Diagnostics API**: Exposed `db.indexes.all` to allow developers to inspect active indexes, check their sizes, and retrieve internal statistics (useful for debugging and performance tuning).
- **NEW — Public Index Types**: Exported `HashIndex`, `SortedIndex`, `FtsIndex`, `BitmaskIndex`, and `CompositeIndex` as public types.

---

## 0.0.26

### Bug Fixes (Index Rebuild Corruption on Startup)

- **CRITICAL — `reindex()` and `rebuildSecondaryIndexes()` caused duplicate index entries**: When a database from pre-0.0.24 versions opened in 0.0.23+, if the header was not marked "clean", `open()` automatically called `rebuildSecondaryIndexes()`. However, this method called `rangeSearch()` without deduplication. If `rangeSearch()` returned IDs multiple times due to B-Tree structural inconsistencies from old versions, each ID would be indexed multiple times. This corrupted secondary indexes, causing subsequent `getAll()` calls to return duplicate documents. Fixed by deduplicating `rangeSearch()` results using `LinkedHashSet` in both `reindex([field])` and `rebuildSecondaryIndexes()`.

- **Test Results**: All 94 tests pass. Databases created in 0.0.22 or earlier that were opened in 0.0.23-0.0.25 should now be cleaned up by running `reindex()` or closing/reopening in 0.0.26.

---

## 0.0.25

### Bug Fixes (Out-of-Memory on Large Batch Inserts)

- **CRITICAL — `bulkLoad` with large existing trees caused OOM**: When inserting 5000+ documents into a database that already had data, the code extracted all existing entries into memory at once via `_extractLeafEntries()`, then merged and rebuilt. With 10,000+ total entries in RAM simultaneously, Dart's memory allocator was overwhelmed. Fixed by implementing a threshold strategy: trees with <500 entries use the extract-merge-rebuild approach (memory safe), while trees ≥500 entries fall back to individual inserts (no OOM, and now safe because the median-key bug from 0.0.24 is fixed). This trades some speed for memory safety on large existing datasets.

- **Test Results**: All 94 tests pass including the critical "large batch insert with write-behind does not OOM" test. Batch operations of 5000+ documents now work reliably.

---

## 0.0.24

### Bug Fixes (B-Tree Duplicate IDs)

- **CRITICAL — `insertAll` / `commitBatch` after existing data caused duplicate IDs**: `bulkLoad` was replacing the B-Tree root with a freshly-built tree containing only the new entries, orphaning all previously-written pages on disk. On subsequent `getAll()` / `rangeSearch()` the old pages could still be reached via stale page references, returning IDs 3–5× duplicated. Fixed by extracting all existing leaf entries, O(N+M) merging them with the new batch, and rebuilding a single correct tree from the full combined set.

- **CRITICAL — Median key data loss during leaf splits in individual inserts**: When `bulkLoad` fell back to individual `insert` calls on a non-empty tree, B-Tree leaf splits moved the median key up to the internal node and discarded its document offset. Every 128th document was silently lost. Resolved by the merge-and-rebuild strategy above which eliminates leaf splits entirely for batch operations.

- **MODERATE — `rangeSearch` could return duplicate IDs on structurally inconsistent trees**: Added a `seenIds` `Set<int>` guard inside `_rangeNode` so each ID is emitted at most once regardless of tree state.

- **MODERATE — `getAllImpl` did not deduplicate IDs from range scan**: `getAllImpl` now passes IDs through a `LinkedHashSet` before fetching documents, providing a second safety net against duplicates reaching the caller.

- **MINOR — WAL recovery was not idempotent**: `_recover()` now compares the WAL entry bytes against what is already on disk and skips writes where the data already matches, preventing double-application of committed transactions after a crash-and-reopen cycle.

- **Test Results**: All 94 tests pass; 4 new regression tests added covering all duplicate-ID scenarios.

---

## 0.0.23

### Bug Fixes (Query Cache & Reindex)

- **CRITICAL — Query Cache Key Bug**: Fixed query cache key generation that only included condition field types, not actual values. This caused different queries on the same field (e.g., `equals('London')` and `equals('NoCity')`) to share the same cache entry, returning stale results. Affected operations:
  - `sumWhere()`, `avgWhere()`, `maxWhere()`: returned wrong aggregated values
  - `updateWhere()`, `deleteWhere()`: returned wrong update/delete counts
  - `findStream()`: yielded stale cached documents
  - **Fix**: Cache key now includes condition values for all condition types (equals, range, contains, startsWith, isIn, isNull, fts)

- **MODERATE — Reindex Cache Invalidation**: Fixed `reindex()` not clearing query cache after rebuilding indexes, causing queries to return stale cached results. Added `QueryBuilder.clearCache()` call after index rebuild.

- **MODERATE — Test Cross-Contamination**: Fixed global static query cache causing test cross-contamination (one test's cached results affecting another test). Added `QueryBuilder.clearCache()` call at start of `FastDB.open()`.

- **Test Results**: All 90 tests now pass (previously 11 were failing due to cache issues)

## 0.0.22

### Performance Optimizations (Batch Reads & Cache)

- **Default LRU cache size increased**: `cacheCapacity` default raised from `256` (1 MB) to `2048` (8 MB) in `FfastDb.init()`. This dramatically improves performance on datasets with working sets larger than 1 MB, reducing disk I/O from repeated page cache evictions.

- **New method: `findByIdBatch(List<int> ids, {int concurrency = 50})`**: Parallelizes document reads up to a controlled concurrency limit. For queries returning many IDs, this is 10–100× faster than sequential `findById` calls. Automatically processes results in batches to prevent memory spikes on large result sets. Example:
  ```dart
  final ids = await db.query().where('status').equals('active').findIds();
  final docs = await db.findByIdBatch(ids);  // Parallel reads, 10–100x faster
  ```

- **New method: `stream<dynamic> stream()`**: Returns a lazy stream that yields documents one by one without loading the entire result set into memory. Ideal for exporting large datasets, pagination, or processing documents as they arrive. Example:
  ```dart
  await for (final doc in db.stream()) {
    print(doc);  // Process one doc at a time
  }
  ```

- **`getAll()` optimized**: Now uses `findByIdBatch()` internally instead of sequential reads, providing automatic 10–100× speedup on large databases with no code changes.

## 0.0.21

### Bug Fixes (Index Corruption & Startup Reliability)

- **CRITICAL — Bug #1**: Fixed `addSortedIndex` and `addBitmaskIndex` overwriting already-loaded indexes with empty instances. Both methods now use `putIfAbsent` so that a persisted index loaded from disk by `_loadIndexes()` is preserved. The direct assignment caused every startup after the first to return empty query results and permanently corrupt the on-disk index.
- **GRAVE — Bug #2**: Fixed race condition in `openDatabase` where `FfastDb.instance` became accessible before secondary indexes were registered. Indexes are now passed into `FfastDb.init()` and registered before `open()` is called, so `_loadIndexes()` can match serialized blobs to the correct type and the singleton is never exposed in a half-initialized state.
- **GRAVE — Bug #3**: Fixed `_loadIndexes()` silently ignoring an index-type change between startups (e.g. `HashIndex` → `SortedIndex`). If the on-disk type differs from the pre-registered type the blob is now discarded; the index is rebuilt with the correct type via `_rebuildSecondaryIndexes()`, preventing silent O(n log n) degradation of range queries.
- **MODERATE — Bug #4**: Fixed a single corrupt document aborting the entire startup. `_rebuildSecondaryIndexes()` now wraps each `findById` call in a try/catch; corrupt documents are skipped and will be cleaned up on the next `compact()`.
- **GRAVE — Bug #5a**: Fixed O(n) memory allocation on every `startsWith` query with `HashIndex`. `_StartsWithCondition` now calls the new `HashIndex.filterKeys()` method, which iterates buckets without sorting or copying the full index, reducing per-query allocation from O(n) to O(k) where k is the number of matching documents.
- **GRAVE — Bug #5b**: Changed the default `autoCompactThreshold` from `0` (never compact) to `double.minPositive` (compact as soon as any dead document exists). This prevents the WAL file from growing unboundedly and eliminates the associated RAM spike on startup caused by replaying months of historical writes.

## 0.0.20

### Bug Fixes (Web Memory Crash)
- **CRITICAL (Web/IndexedDB)**: Rewrote `IndexedDbStorageStrategy` with **chunked incremental flush**. Data is now stored as 64 KB chunks in IndexedDB; `flush()` only writes the chunks modified since the last flush. Previously every `insert()`/`update()`/`delete()` copied the **entire** database buffer (e.g. 50 MB) from Dart to JavaScript, causing peak memory of ~3× the DB size per flush and OOM crashes on large databases. Peak memory per flush is now O(64 KB) instead of O(DB size).
- **Web/IndexedDB**: Backward-compatible migration — databases stored in the old single-key format (`<name>_buffer`) are loaded transparently and migrated to the chunked format on the next `flush()`.
- **Web/IndexedDB**: `truncate()` now cleans up orphan chunk keys in IndexedDB on the next flush, preventing stale data after `compact()`.
- **MemoryStorageStrategy**: `truncate()` now reclaims the backing `Uint8List` when the used size shrinks by more than 512 KB (matching the existing fix in `WebStorageStrategy` and `IndexedDbStorageStrategy`). Previously a database that grew to 64 MB and was compacted to 5 MB still held the 64 MB buffer in RAM.
- **Core**: Eliminated redundant `storage.flush()` calls in `_insertImpl()` and `_updateImpl()` when `dataStorage` is null (single-file mode). On web this avoided creating an unnecessary second IndexedDB transaction per operation.
- **Web**: Reduced default `cacheCapacity` in `openDatabase()` from 256 to 64 pages (1 MB → 256 KB). On web the entire database is already in RAM, so a large LRU page cache is redundant overhead.

## 0.0.19

### Bug Fixes (Memory)
- **OOM fix - `insertAll`**: Documents are now serialized and written to storage one at a time instead of accumulating all serialized `Uint8List` objects in RAM before writing. For large batches (e.g. 100K × 1KB docs) this eliminates ~100MB of peak heap usage.
- **B-Tree node cache**: Reduced `_nodeCacheCapacity` from 4096 to 512 deserialized nodes, cutting the in-memory node object overhead from ~16MB to ~2MB. Hot nodes remain fast via the underlying LRU page cache.
- **BitmaskIndex**: Default `maxDocId` reduced from 1,048,576 (128KB per bitset) to 65,536 (8KB per bitset). The index still grows automatically via `_grow()` when document IDs exceed the initial capacity, so behaviour is unchanged for large datasets.
- **`_BatchState` enum**: Removed the now-unused state-machine enum that was part of the old two-pass `insertAll` implementation.

## 0.0.18

### Bug Fixes & Code Quality
- **Web/LocalStorage**: Fixed `Uint8List` not found compile error by adding missing `dart:typed_data` import (caused incomplete package analysis and 0/50 static analysis score on pub.dev).
- **Static analysis**: Resolved all `lib/` warnings and infos: removed unused `dart:js_interop` import, fixed `return null` in `void` method, replaced `LinkedHashMap()` with collection literal, added `library;` directive to `open_database.dart`, made `FieldCondition` public (was `_FieldCondition`), fixed doc-comment angle brackets, and improved `prefer_is_empty` usage.

## 0.0.17

### Bug Fixes (Web Memory)
- **Web/IndexedDB**: `flush()` now skips the IndexedDB put when no data has changed since the last flush (`_dirty` flag). Eliminates redundant writes that fired 2-3× per `insert()`/`update()`/`delete()` when `needsExplicitFlush` is true.
- **Web/IndexedDB**: `flush()` no longer creates an intermediate Dart `sublist()` copy of the buffer. A zero-copy typed-data view (`buffer.asUint8List`) is used instead, reducing the peak RAM during flush from 3× to 2× the database size.
- **Web/IndexedDB & WebStorageStrategy**: `truncate()` now releases the backing `Uint8List` when the used size shrinks by more than 512 KB (e.g. after `compact()`). Previously the oversized buffer was retained in RAM until the page reloaded.
- **Web/LocalStorage**: Added `_dirty` flag (same flush-deduplication as IndexedDB) and overrides for both `write()` and `writeSync()`.
- **Web/LocalStorage**: `flush()` now catches `QuotaExceededError` (the ~5 MB `localStorage` limit) and throws a descriptive `StateError` that suggests switching to `useIndexedDb: true`, instead of silently losing data.

## 0.0.16
### Bug Fixes
- **WASM**: The runtime failure in wasm is fixed
## 0.0.15

### Bug Fixes
- **Web**: Fixed `Function converted via 'toJS' contains invalid types` compiler error in `IndexedDbStorageStrategy` by removing an invalid `async` keyword from a JS interop closure.

## 0.0.14

### Critical Bug Fixes
- **CRITICAL**: Fixed `openDatabase()` unconditionally calling `FfastDb.disposeInstance()` at the start
  of every call. This caused `"Bad state: Cannot perform operations on a closed database"` errors
  when multiple code paths (e.g., a BLoC and a repository) called `ffastdb.init()` concurrently
  during app startup. The function now reuses the live instance if one is already open.
- **CRITICAL (Web)**: Fixed `IndexedDbStorageStrategy` using the hardcoded key `'db_buffer'` for all
  database instances. Opening two databases (e.g., `'users'` and `'products'`) caused their data to
  collide in the same IndexedDB slot. Each database name now gets its own isolated key
  (`'${name}_buffer'`).

### New Features
- `QueryBuilder.find()` — executes a query and returns the full document list directly.
  No more manual `findById` loop. Use via `db.query().where('field').equals('value').find()`.
- `QueryBuilder.findFirst()` — returns the first matching document or `null`, resolving only
  one document ID for efficiency.
- `QueryBuilder.count()` — returns the count of matching documents with an O(1) hot path
  for simple equality queries on indexed fields (reads the index bucket size directly).
- `FastDB.isOpen` getter — exposes whether the database instance is currently usable.

### Improvements
- Improved error message for closed-database operations: now explains the three most common
  causes and how to recover, instead of the previous generic `"Cannot perform operations..."`.
- `EncryptedStorageStrategy` doc comment updated with a clear security warning: it uses a
  Vigenère-style XOR cipher (obfuscation, not cryptographic-grade encryption). Guidance for
  using AES-256-GCM via `encrypt` / `pointycastle` is included.
- Barrel export (`package:ffastdb/ffastdb.dart`) now includes `EncryptedStorageStrategy` and
  the platform-appropriate storage strategy (`IoStorageStrategy` on native,
  `IndexedDbStorageStrategy` on web) — no more imports of internal `src/` paths.

## 0.0.13
- solve wasm issues
## 0.0.12
- Fig minors issues
## 0.0.11 (unreleased)

### Critical Bug fixes
- **CRITICAL**: Fixed database corruption on Android/iOS caused by using `FileMode.append`. 
  On mobile platforms, `FileMode.append` ignores `setPosition()` calls and forces all writes 
  to the end of the file, corrupting B-tree nodes that need to be updated at specific offsets.
  Now uses `FileMode.write` which correctly respects random-access writes.

### API Changes
- Restored public `FastDB()` constructor for non-singleton use cases (benchmarks, multiple instances).
  For most applications, continue using `FfastDb.init()` with the singleton pattern.

## 0.0.10
- fix package compatibility
## 0.0.9
- add meta
- fix library versions
## 0.0.8
- Fix Garbage collector issue
- Fix Firebase problems

## 0.0.7
- fix unsupported type fallbacks
## 0.0.6
- add serializable
## 0.0.5
- fix firebase bugs

## 0.0.4
- Fix persistence bug
## 0.0.3
- Fixed web bug 
## 0.0.2

### Bug fixes
- Fixed corrupted documents being read silently from disk without checksum validation.
- Fixed database getting stuck when a batch insert fails halfway through.
- Fixed `compact()` not actually freeing disk space in single-file mode.
- Fixed index values greater than 2 billion being corrupted after a restart.
- Fixed memory growing unboundedly after many deletes or updates.
- Fixed nested `transaction()` calls silently corrupting rollback state — now throws a clear error.
- Fixed calling `beginTransaction()` twice discarding pending writes silently — now throws a clear error.
- Fixed `watch()` streams accumulating in memory after all listeners are gone.
- Fixed registering two adapters with the same `typeId` silently overwriting the first one — now throws an error.

### New features
- `DateTime` is now supported natively — no more manual conversion needed.

### Improvements
- Queries are noticeably faster: the query planner no longer runs each condition twice to estimate cost.
- `startsWith()` is now much faster on sorted indexes (uses a range scan instead of scanning everything).

## 0.0.1
 - Pure Dart DB
 - Type Adapters
 - B-Tree primary index
 - Multiplatform storage
 - Index persistence
 - Hash Index
 - Sorted Index
 - Bitmask Index
 - CRUD Operations
 - WAL crash recovery
 - Transactions
 - Schema migrations
 - Fluent query builder
 - Aggregations
 - Reactive watchers
 - Auto-compact
 - First version

