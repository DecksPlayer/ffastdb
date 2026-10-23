# FFastDB 🚀 `v0.3.5`

A fast, crash-safe, pure-Dart NoSQL database for Flutter & server-side Dart.

[![pub.dev](https://img.shields.io/pub/v/ffastdb)](https://pub.dev/packages/ffastdb)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

---

## Features

| Feature | FastDB | Hive | Isar |
|---|---|---|---|
| Pure Dart | ✅ | ✅ | ❌ (native) |
| No code generation | ✅ | ❌ | ❌ |
| B-Tree primary index | ✅ | ❌ | ✅ |
| Secondary indexes | ✅ | ❌ | ✅ |
| Write-Ahead Log (WAL) | ✅ | ❌ | ✅ |
| Crash recovery | ✅ | ❌ | ✅ |
| File locking | ✅ | ❌ | ✅ |
| Fluent QueryBuilder | ✅ | ✅ | ✅ |
| Reactive watchers | ✅ | ✅ | ✅ |
| Transactions | ✅ | ❌ | ✅ |
| `DateTime` support | ✅ | ✅ | ✅ |
| Web support | ✅ | ✅ | ❌ |
| WASM support | ✅ | ❌ | ❌ |

Also built in: full-text search, composite indexes, authenticated encryption,
JSON export/import, schema migrations and a compact binary document format.

---

## Getting Started

```yaml
dependencies:
  ffastdb: ^0.3.5
```

### Open a database (Flutter — mobile, desktop, web, WASM)

```dart
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:ffastdb/ffastdb.dart';
import 'package:path_provider/path_provider.dart'; // add to YOUR app's pubspec

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Native: a persistent directory. Web: ignored (data lives in IndexedDB).
  final dir = kIsWeb ? '' : (await getApplicationDocumentsDirectory()).path;

  final db = await openDatabase(
    'myapp',
    directory: dir,
    indexes: ['status'],                         // HashIndex: O(1) equals
    sortedIndexes: ['createdAt', 'age'],         // SortedIndex: ranges, sorting
    ftsIndexes: ['description'],                 // full-text search
    compositeIndexes: [['status', 'createdAt']], // multi-field AND
    encryptionKey: 'your_secret_key',            // optional
  );
  runApp(MyApp(db: db));
}
```

- `openDatabase()` returns the open database when called again for the same
  database (e.g. from several places at startup) and replaces it when you ask
  for a different one.
- `path_provider` is **not** a dependency of `ffastdb`.
- One process (isolate) owns a database file at a time; a second opener gets a
  clear "locked" error.

### Persist indexes when the app goes to the background

```dart
class _AppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) widget.db.flush();
  }
  // ... addObserver / removeObserver in initState / dispose
}
```

`flush()` makes every write durable and saves the secondary indexes. If the OS
then kills the app, the next start loads the indexes instead of rebuilding them
from every document.

### Server-side Dart / manual setup

```dart
import 'package:ffastdb/ffastdb.dart';

// File on disk + WAL + file lock
final db = await FfastDb.init(
  WalStorageStrategy(
    main: IoStorageStrategy('/data/myapp/users.fdb'),
    wal:  IoStorageStrategy('/data/myapp/users.fdb.wal'),
    durability: Durability.full,
  ),
  indexes: ['status'],
);
final same = FfastDb.instance;       // the singleton, anywhere in your app
await FfastDb.disposeInstance();     // at shutdown

// Tests / in-memory (no persistence)
final mem = FastDB(MemoryStorageStrategy());
await mem.open();
```

---

## Durability

| Mode | Each write | Survives app crash / OS killing the app | Survives power loss / OS crash |
|---|---|---|---|
| `Durability.normal` (default for `openDatabase`) | no fsync | ✅ | may lose the **latest** writes — never corrupts |
| `Durability.full` | fsynced before `await` returns | ✅ | ✅ |

```dart
final db = await openDatabase('bank', directory: dir, durability: Durability.full);
```

`normal` works like SQLite's `synchronous=NORMAL`: the main file is only
written after the WAL is fsynced, so a power loss can roll back to an earlier
state but never leaves a half-applied one. `db.flush()` and `db.close()` make
everything durable in both modes. Single writes are ~4-7x faster in `normal`.
On the web every write is committed to IndexedDB; the option is ignored.

---

## Encryption

```dart
// Password (stretched with PBKDF2-HMAC-SHA256, 100k iterations by default):
final db = await openDatabase('secure', directory: dir, encryptionKey: 'passphrase');

// Strongest: a random 32-byte key kept in the platform's secure storage
final secure = FastDB(EncryptedStorageStrategy.withRawKey(storage, key32Bytes));
```

- AES-256 with a fresh nonce every time a 1 KB sector is rewritten, plus an
  HMAC-SHA256 tag per sector: tampered or corrupted data fails on read.
- A wrong key is rejected by `open()`.
- Opening costs ~0.2 s with a password (PBKDF2); a raw key opens instantly.
  Tune with `EncryptedStorageStrategy(base, password, pbkdf2Iterations: ...)`.
- Files encrypted by ffastdb ≤ 0.3.5 keep working in their legacy format
  (`isLegacyFormat`). To upgrade one, `exportJson()` it and `importJson()` into
  a new database.

---

## Documents

### Insert, update, delete

```dart
final id = await db.insert({
  'name': 'Alice',
  'age': 30,
  'city': 'London',
  'createdAt': DateTime.now(),
});

await db.put(42, {'name': 'Bob'});                // manual id
await db.upsert(42, {'age': 26});                 // update or insert by id
await db.upsertWhere('email', 'a@b.c', {'name': 'Ann'}); // by unique field

final ids = await db.insertAll([                  // bulk: much faster
  {'name': 'Clara', 'city': 'Tokyo', 'age': 28},
  {'name': 'Dana',  'city': 'London', 'age': 35},
]);

await db.update(id, {'age': 31});                 // merges fields
await db.delete(id);

// Atomic bulk operations (all or nothing)
await db.updateWhere((q) => q.where('city').equals('London').findIds(), {'country': 'UK'});
await db.deleteWhere((q) => q.where('active').equals(false).findIds());
```

### Read

```dart
final doc  = await db.findById(id);     // O(log n)
final docs = await db.findByIds(ids);   // one batched read, keeps order
final all  = await db.getAll();
final n    = await db.count();          // O(1)
final has  = await db.exists(id);

// Lazy: one document at a time
await for (final d in db.findStream((q) => q.where('city').equals('London').findIds())) {
  print(d);
}
```

### Supported data types

`int` (64-bit), `double` (incl. NaN/±Infinity), `String`, `bool`, `null`,
`DateTime` (UTC microseconds, read back with `isUtc: true`), `Uint8List`,
nested `List` / `Map`, and Firebase types by duck-typing (`Timestamp` →
`DateTime`, `GeoPoint` → `{latitude, longitude}`, `DocumentReference` → path,
`Blob` → `Uint8List`). Other objects are stored via `toJson()` (as a document)
or `toString()` (nested). See [SUPPORTED_DATA_TYPES.md](SUPPORTED_DATA_TYPES.md).

Documents are stored in a compact binary format. Databases written by older
versions (JSON format) are read without any migration step.

### Export / import JSON

```dart
final json = await db.exportJson();        // JSON array, ascending id order
final ids  = await other.importJson(json); // inserted as new documents
```

Export maps values onto plain JSON (`DateTime` → ISO-8601 UTC, `Uint8List` →
base64, NaN/±Infinity → `null`) and keeps each document's `ffdbID`; import drops
`ffdbID` (the database assigns ids) and keeps plain JSON types.

---

## Queries

All query methods return Futures.

```dart
// Exact match — O(1) with a HashIndex
final ids = await db.query().where('city').equals('London').findIds();

// Ranges — O(log n) with a SortedIndex
await db.query().where('age').between(18, 65).findIds();
await db.query().where('age').greaterThan(60).findIds();
await db.query().where('age').lessThanOrEqualTo(25).findIds();

// AND (most selective index first), OR, NOT, isIn, null checks
await db.query().where('city').equals('London').where('age').between(25, 40).findIds();
await db.query().where('city').equals('London').or().where('city').equals('Paris').findIds();
await db.query().where('city').not().equals('London').findIds();
await db.query().where('city').isIn(['London', 'Tokyo']).findIds();
await db.query().where('email').isNull().findIds();

// Strings (case-sensitive) and full-text search (case-insensitive tokens)
await db.query().where('name').startsWith('Al').findIds();
await db.query().where('name').contains('ice').findIds();
await db.query().where('description').fts('payment failed').find();

// Sorting + pagination (sortBy needs a SortedIndex)
await db.query().where('city').equals('London').sortBy('age', descending: true).skip(20).limit(10).findIds();

// Documents instead of ids
final docs  = await db.query().where('city').equals('London').find();
final first = await db.query().where('name').startsWith('Al').findFirst();
final count = await db.query().where('city').equals('London').count(); // O(1) for one equals

// Aggregations
await db.sumWhere((q) => q.where('active').equals(true).findIds(), 'age');
await db.avgWhere((q) => q.where('active').equals(true).findIds(), 'age');
await db.maxWhere((q) => q.where('city').equals('London').findIds(), 'age');

// Why is a query slow? Print the plan.
print(db.query().where('city').equals('London').where('age').between(18, 65).explain());
```

Conditions on fields without an index still work (in-memory filter); inside an
AND they only scan the candidates left by the indexed conditions.

---

## Indexes

Declare them in `openDatabase()` / `FfastDb.init()`, or register them **before**
`open()`:

```dart
final db = FastDB(storage);
db.addIndex('city');                       // HashIndex — equals
db.addSortedIndex('age');                  // SortedIndex — ranges, sortBy, startsWith
db.addBitmaskIndex('active');              // booleans / small enums
db.addCompositeIndex(['city', 'status']);  // multi-field AND
db.addFtsIndex('description');             // full-text search
await db.open();
```

An index added after `open()` needs `await db.reindex(field: 'city')`
(`await db.reindex()` rebuilds all). Indexes are persisted, so there is no
reason to reindex on every start.

---

## Transactions

```dart
await db.transaction(() async {
  final id = await db.insert({'name': 'Alice', 'balance': 100});
  await db.update(id, {'balance': 80});
  if (somethingWrong) throw Exception('abort'); // everything above is undone
});
```

- Atomic: all or nothing (fully crash-safe with a `WalStorageStrategy`, the
  default on native).
- Isolated: other callers' reads and writes wait until it finishes; calls made
  inside it — including nested `transaction()` calls — join it.

---

## Reactive watchers

```dart
db.watch('status').listen((ids) => print('status index: $ids'));
db.watchDocs('status').listen((docs) => print(docs));
db.query().where('status').equals('pending').watch().listen((docs) => print(docs));
```

A burst of writes produces one emission with the final state.

---

## TypeAdapters (typed objects)

```dart
class User {
  final String name;
  final int age;
  User(this.name, this.age);
}

class UserAdapter extends TypeAdapter<User> {
  @override
  int get typeId => 1; // unique, never change it once data exists (256 and 512 are reserved)

  @override
  User read(BinaryReader reader) {
    final n = reader.readUint8();
    final f = {for (int i = 0; i < n; i++) reader.readUint8(): reader.readDynamic()};
    return User(f[0] as String, f[1] as int? ?? 0); // tolerate missing slots
  }

  @override
  void write(BinaryWriter writer, User user) {
    writer.writeUint8(2);                                // number of slots
    writer.writeUint8(0); writer.writeDynamic(user.name);
    writer.writeUint8(1); writer.writeDynamic(user.age);
  }
}

db.registerAdapter(UserAdapter()); // before inserting/reading Users
final id = await db.insert(User('Alice', 30));
final user = await db.findById(id) as User;
```

Numbered slots keep old data readable when you add fields: add new slot
numbers, never reuse old ones.

---

## Schema migrations

```dart
final db = await openDatabase(
  'myapp',
  directory: dir,
  version: 2,
  migrations: {
    1: (doc) => {...doc as Map<String, dynamic>, 'country': 'unknown'}, // v1 → v2
  },
);
```

Migrations run once, atomically, when the stored version is lower.

---

## Compaction

Updates and deletes leave dead space behind; `compact()` reclaims it (atomic
with the WAL):

```dart
await db.compact();
final db = FastDB(storage, autoCompactThreshold: 0.3); // auto when >30% dead (off by default)
```

---

## Performance

Measured on a Windows desktop (Dart VM). Run them yourself with
`dart run benchmark/<name>.dart`.

**In-memory storage, 1M documents** (`benchmark/million_benchmark.dart`):

| Operation | Throughput |
|---|---|
| Batch insert (`insertAll`) | ~200k docs/s |
| Sequential `insert` | ~180k ops/s |
| `findById` | ~520k ops/s |
| HashIndex query | ~1.1M ops/s |
| SortedIndex range query | ~660k ops/s |

**On disk with the WAL** (20k documents, `openDatabase` defaults):

| Operation | Throughput |
|---|---|
| `insertAll` | ~59k docs/s |
| `insert` — `Durability.normal` / `Durability.full` | ~4.5k / ~650 ops/s |
| `update` — `normal` / `full` | ~2.2k / ~600 ops/s |
| `findById` | ~15k ops/s |
| `getAll` | ~170k docs/s |

**Flutter comparison** (`flutter_benchmark/`, real disk, 10k docs — measured
with ffastdb 0.3.5, before the optimizations in the current version):

| Operation | `ffastdb` | `isar_community` | `sembast` |
|---|---|---|---|
| `insertAll` (bulk) | 39.7k ops/s | 153.8k ops/s | 15.3k ops/s |
| single insert (fsync per write) | 382 ops/s | 498 ops/s | 97 ops/s |
| indexed query (2k queries) | 151 ops/s | 583 ops/s | 245 ops/s |
| `findById` (5k lookups) | 13.9k ops/s | 9.2k ops/s | 333.3k ops/s |

```bash
cd flutter_benchmark && dart run bin/run_benchmark.dart 10000
```

---

## Architecture

```
FastDB
├── B-Tree primary index (O(log n), bulk-load O(n))
├── Secondary indexes: Hash · Sorted · Bitmask · Composite · Full-text
├── Binary document codec (CRC32 per document)
├── LRU page cache
├── WAL (WalStorageStrategy)
│   ├── per-transaction COMMIT markers, CRC32 per entry
│   ├── Durability.full / Durability.normal
│   └── automatic crash recovery on open()
└── StorageStrategy
    ├── IoStorageStrategy        (mobile / desktop / server — file lock)
    ├── IndexedDbStorageStrategy (web — default)
    ├── LocalStorageStrategy     (web — localStorage)
    ├── MemoryStorageStrategy    (tests)
    ├── EncryptedStorageStrategy (wrapper — AES-256 + HMAC-SHA256)
    └── BufferedStorageStrategy  (wrapper — write coalescing)
```

### Files on disk

For `openDatabase('users', directory: '/data')`:

```
/data/users.fdb       ← main database file
/data/users.fdb.wal   ← write-ahead log (emptied at checkpoints)
/data/users.fdb.lock  ← process lock (removed on close)
```

---

## License

MIT © 2026
