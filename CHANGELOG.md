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

