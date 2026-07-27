# ffastdb — Claude Development Rules

> Rules for AI-assisted development of `ffastdb`.  
> These apply to every change made in this repository.

---

## What is ffastdb?

A **pure-Dart, high-performance, cross-platform embedded NoSQL database** for Flutter and Dart applications.

- **Platforms:** Web, Android, iOS, Windows, Linux, macOS
- **Package:** `ffastdb` on pub.dev
- **Version:** 0.2.7+
- **Main entry:** `lib/ffastdb.dart`

---

## ⚡ Core Rule: Speed First, No Over-Engineering

> The entire purpose of ffastdb is to be **fast**. Every change must preserve or improve performance.

**DO:**
- Separate code into focused classes and helper files (like `_crud_operations.dart`, `_index_manager.dart`)
- Write direct, functional code with clear intent
- Add indexes for O(1)/O(log n) operations
- Benchmark before and after significant changes

**DO NOT:**
- Add DI containers, repository patterns, or extra abstraction layers on top of the DB
- Create wrapper classes that add indirection without performance benefit
- Add features that aren't explicitly requested
- Use `dart:io` directly in shared code (use `StorageStrategy` instead)

---

## Project Structure

```
lib/
├── ffastdb.dart                      ← barrel export (users import this)
└── src/
    ├── fastdb.dart                   ← FastDB class (core)
    ├── _crud_operations.dart         ← insert, update, delete (part file)
    ├── _query_operations.dart        ← find, getAll, count (part file)
    ├── _batch_operations.dart        ← insertAll, batch mode (part file)
    ├── _index_manager.dart           ← addIndex, reindex (part file)
    ├── _storage_manager.dart         ← compact, migrations (part file)
    ├── ffastdb_singleton.dart        ← top-level ffastdb singleton
    ├── annotations.dart
    ├── query/fast_query.dart         ← QueryBuilder with CBO + cache
    ├── index/                        ← HashIndex, SortedIndex, BitmaskIndex, FtsIndex, CompositeIndex, BTree
    ├── serialization/                ← TypeAdapter, FastSerializer, BinaryIO
    └── storage/
        ├── storage_strategy.dart     ← abstract interface
        ├── io/io_storage_strategy.dart
        └── web/indexed_db_strategy.dart
```

---

## Cross-Platform Rules

| Platform | Storage | Import Gate |
|----------|---------|-------------|
| Native (Android/iOS/Windows/Linux/macOS) | `IoStorageStrategy` + WAL | `dart.library.io` |
| Web | `IndexedDbStorageStrategy` | `dart.library.js_interop` |
| Tests | `MemoryStorageStrategy` | always |

- **NEVER** use `dart:io` in shared code. Use the `StorageStrategy` abstraction.
- **ALWAYS** use conditional imports (`if (dart.library.js_interop)`) for platform-specific code.
- The entry point for platform selection is `lib/src/platform/open_database.dart`.
- Web: `directory` parameter is ignored — storage is in `IndexedDB`.

---

## API Patterns to Follow

### Initialization

```dart
// Singleton (Flutter apps)
await ffastdb.init('myapp', directory: dir.path);

// Direct (tests, advanced)
final db = FastDB.forTesting(MemoryStorageStrategy());
await db.open();

// With indexes declared upfront (recommended — loads from disk on clean shutdown)
final db = await FastDB.init(
  IoStorageStrategy('${dir.path}/myapp.fdb'),
  indexes: ['status', 'userId'],
  sortedIndexes: ['createdAt', 'amount'],
  ftsIndexes: ['description'],
  compositeIndexes: [['city', 'status']],
  version: 2,
  migrations: { 2: (doc) => {...doc, 'v': 2} },
);
```

### CRUD

```dart
final id  = await db.insert({'name': 'Alice', 'status': 'active'});
final doc = await db.findById(id);
await db.update(id, {'status': 'inactive'});
await db.delete(id);
final ids = await db.insertAll([...]);
```

### Query Builder (fluent API)

```dart
// Preferred: fluent .find() — resolves documents directly
final docs = await db.query()
  .where('status').equals('active')
  .where('age').between(18, 65)
  .sortBy('createdAt', descending: true)
  .limit(20)
  .find();

// Count — O(1) fast path for simple equals
final n = await db.query().where('status').equals('active').count();

// FTS search
final docs = await db.query().where('description').fts('payment failed').find();

// OR conditions
final docs = await db.query()
  .where('city').equals('London').or().where('city').equals('Paris')
  .find();

// Explain (development only — print query plan)
print(db.query().where('status').equals('active').explain());
```

### Indexes

```dart
db.addIndex('field');                        // HashIndex — O(1) equals
db.addSortedIndex('field');                  // SortedIndex — O(log n) range/sort
db.addBitmaskIndex('field');                 // BitmaskIndex — boolean/enum
db.addCompositeIndex(['city', 'status']);    // CompositeIndex — multi-field AND
db.addFtsIndex('field');                     // FTS — text search

// IMPORTANT: register indexes BEFORE open() (or use FastDB.init(indexes: [...]))
// If added after open: await db.reindex('fieldName');
```

### Reactive Watchers

```dart
db.watch('status').listen((ids) async {
  final docs = await Future.wait(ids.map(db.findById));
  // update UI
});
```

---

## TypeAdapters

When writing a `TypeAdapter<T>`:
1. `typeId` must be unique and **never changed** once persisted.
2. Field slot numbers (the `uint8` written before each value) must be **stable** — add new slots, never reuse old ones.
3. Use `reader.readDynamic()` with fallbacks for optional/new fields.
4. Register BEFORE first use: `ffastdb.registerAdapter(MyAdapter())` or `db.registerAdapter(MyAdapter())`.

```dart
class PersonAdapter extends TypeAdapter<Person> {
  @override int get typeId => 1;

  @override
  Person read(BinaryReader reader) {
    final n = reader.readUint8();
    final f = <int, dynamic>{for (int i = 0; i < n; i++) reader.readUint8(): reader.readDynamic()};
    return Person()
      ..name = f[0] as String
      ..age  = f[1] as int? ?? 0;
  }

  @override
  void write(BinaryWriter writer, Person obj) {
    writer.writeUint8(2);
    writer.writeUint8(0); writer.writeDynamic(obj.name);
    writer.writeUint8(1); writer.writeDynamic(obj.age);
  }
}
```

---

## Testing Rules

- **Always** use `MemoryStorageStrategy()` in tests (no temp files, no `dart:io`).
- Use `FastDB.forTesting(...)` constructor.
- Always `await db.close()` in `tearDown`.
- Do NOT use `FastDB.init()` (singleton) in tests — it leaves global state.

```dart
late FastDB db;

setUp(() async {
  db = FastDB.forTesting(MemoryStorageStrategy());
  await db.open();
  db.addIndex('status');
});

tearDown(() => db.close());
```

Run tests:
```bash
dart test test/
dart test test/fastdb_test.dart
dart test test/ --name "batch insert"
dart analyze
```

---

## Known Bugs — Do NOT Work Around These, Fix at Source

> **Resueltos (2026-07-27):** los 4 bugs de esta tabla ya están corregidos en el código
> (deleteImpl notifica watchers, isNull usa complemento, FTS retainAll usa Set, QueryCache
> es por instancia). La auditoría completa y el estado de todas las correcciones están en
> [`FIX_PLAN.md`](FIX_PLAN.md).

| Bug | Location | Estado |
|-----|----------|--------|
| `deleteImpl` no llamaba `_notifyWatchers` | `_crud_operations.dart` | ✅ Corregido |
| `isNull()` devolvía `[]` | `fast_query.dart` | ✅ Corregido |
| `FtsIndex.retainAll(List)` era O(n×m) | `fts_index.dart` | ✅ Corregido (Set postings) |
| `QueryCache` era `static` (global) | `fast_query.dart` | ✅ Corregido (instancia por FastDB) |

See `BUGS.md` for full reproduction and fix details.

---

## Performance Guidelines

1. **Index every queried field** — unindexed queries do a full B-Tree scan.
2. **`insertAll()` over individual `insert()`** — uses batch mode, 5-10x faster.
3. **`compositeIndex`** for multi-field AND — eliminates intersection cost.
4. **`sortedIndex`** is required for efficient `.sortBy()`.
5. **Run `explain()`** during development to verify index usage.
6. **`autoCompactThreshold: 0.3`** for delete-heavy workloads.
7. Never call `reindex()` on every app start — trust clean-shutdown index persistence.

---

## Adding New Code — Checklist

When adding a new feature to ffastdb:

- [ ] Does it work on ALL platforms? (Web, Android, iOS, Windows, Linux)
- [ ] Does it use `StorageStrategy` (not `dart:io`) for any file access?
- [ ] Is it added as a `part` file if it's a new section of `FastDB`?
- [ ] Does it have a test in `test/`?
- [ ] Is it exported in `lib/ffastdb.dart` if it's public API?
- [ ] Is performance acceptable? (check with `dart run benchmark/main.dart`)

---

## Exported Public API (lib/ffastdb.dart)

Classes available to users:
- `FastDB`, `FFastDbSingleton`, `ffastdb` (singleton instance)
- `TypeAdapter<T>`, `BinaryReader`, `BinaryWriter`
- `QueryBuilder`, `FieldCondition`
- `StorageStrategy`, `MemoryStorageStrategy`, `WalStorageStrategy`
- `BufferedStorageStrategy`, `EncryptedStorageStrategy`
- `WebStorageStrategy` (web in-memory)
- `IoStorageStrategy` (native) / `IndexedDbStorageStrategy` (web) — conditional
- `SecondaryIndex`, `HashIndex`, `SortedIndex`, `FtsIndex`, `BitmaskIndex`, `CompositeIndex`
- `@FFastDB`, `@FFastId`, `@FFastField`, `@FFastIndex` (annotations)

---

## Analysis Documents

- `ANALYSIS.md` — Executive summary and roadmap
- `BUGS.md` — Confirmed bugs with reproduction and fixes
- `PERFORMANCE.md` — Bottlenecks and optimization opportunities
- `ARCHITECTURE.md` — Architectural issues and proposals
- `API_IMPROVEMENTS.md` — Non-breaking API enhancements
- `SUPPORTED_DATA_TYPES.md` — All serializable types
- `CHANGELOG.md` — Version history
