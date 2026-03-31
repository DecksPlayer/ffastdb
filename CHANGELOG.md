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

