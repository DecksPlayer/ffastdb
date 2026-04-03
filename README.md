# FastDB 🚀

A high-performance, pure-Dart NoSQL database for Flutter & server-side Dart.

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
| Fluent QueryBuilder | ✅ | ❌ | ✅ |
| Reactive watchers | ✅ | ✅ | ✅ |
| Transactions | ✅ | ❌ | ✅ |
| `DateTime` support | ✅ | ✅ | ✅ |
| Web support | ✅ | ✅ | ❌ |
| WASM support | ✅ | ❌ | ❌ |

---

## Getting Started

```yaml
dependencies:
  ffastdb: ^0.0.18
```

### Open a database

#### Flutter — mobile, desktop, web, and WASM (recommended)

```dart
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:ffastdb/ffastdb.dart';
import 'package:path_provider/path_provider.dart'; // add to your app's pubspec

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // On web/WASM the directory is ignored — openDatabase() uses localStorage.
  // On native, path_provider gives a suitable persistent directory.
  String dir = '';
  if (!kIsWeb) {
    final appDir = await getApplicationDocumentsDirectory();
    dir = appDir.path;
  }

final db = await openDatabase(
  'myapp', 
  directory: dir, 
  version: 1,
  encryptionKey: 'your_secret_key', // Optional: encrypts the entire DB
  useIndexedDb: true,              // Optional: use IndexedDB instead of localStorage (Web only)
);
runApp(MyApp(db: db));
}
```

> **Web / WASM Security & Storage:**
> - `useIndexedDb`: Defaults to `true`. Uses browser `IndexedDB` which is more robust and has higher limits than `localStorage`.
> - `encryptionKey`: If provided, the entire database buffer is obfuscated using a cyclic XOR cipher before being written to the browser storage. This prevents sensitive data from being easily visible in Chrome DevTools or other inspection tools.

> **Note:** `path_provider` is **not** a dependency of `ffastdb` itself — add
> it only to your app's own `pubspec.yaml` for native targets.

#### Server-side Dart / manual setup

```dart
import 'package:ffastdb/ffastdb.dart';

// Production: file on disk + WAL crash protection + file lock
final db = await FfastDb.init(
  WalStorageStrategy(
    main: IoStorageStrategy('/data/myapp/users.db'),
    wal:  IoStorageStrategy('/data/myapp/users.db.wal'),
  ),
  cacheCapacity: 512,
);

// Access the singleton later from anywhere in your app:
final db = FfastDb.instance;

// Development / testing: in-memory (no persistence)
final db = FastDB(MemoryStorageStrategy());
await db.open();

// Release resources at app shutdown:
await FfastDb.disposeInstance();
```

### Add secondary indexes

Indexes must be registered **before** `open()` / `init()` so they are populated
when the database loads existing data.

```dart
db.addIndex('city');           // HashIndex  — O(1) exact-match & isIn
db.addSortedIndex('age');      // SortedIndex — O(log n) range & sortBy
db.addBitmaskIndex('active');  // BitmaskIndex — bitwise AND for boolean/enum fields
```

### Insert documents

```dart
// Insert a JSON map — returns the auto-generated int ID
final id = await db.insert({
  'name': 'Alice',
  'age': 30,
  'city': 'London',
  'createdAt': DateTime.now(),   // DateTime is natively supported
});

// Manual key (Hive-style put)
await db.put(42, {'name': 'Bob', 'age': 25});

// Batch insert — write coalescing makes this ~9x faster than individual inserts
final ids = await db.insertAll([
  {'name': 'Bob',   'city': 'Paris',  'age': 25},
  {'name': 'Clara', 'city': 'Tokyo',  'age': 28},
  {'name': 'Dana',  'city': 'London', 'age': 35},
]);
```

### Supported Data Types

FastDB supports all common Dart and Firebase data types with automatic serialization:

- **Primitives**: `int`, `double`, `String`, `bool`, `null`
- **Date/Time**: `DateTime` (stored as milliseconds since epoch)
- **Collections**: `List`, `Map` (with any nesting level)
- **Binary**: `Uint8List`
- **Firebase types** (via duck-typing, no imports needed):
  - `Timestamp` → `DateTime`
  - `GeoPoint` → `Map<String, double>` with `latitude`/`longitude`
  - `DocumentReference` → `String` (path)
  - `Blob` → `Uint8List`

```dart
final doc = {
  'name': 'John Doe',           // String
  'age': 35,                    // int
  'salary': 75000.50,           // double
  'isActive': true,             // bool
  'createdAt': DateTime.now(),  // DateTime
  'location': {                 // GeoPoint / Location
    'latitude': 37.7749,
    'longitude': -122.4194,
  },
  'roles': ['admin', 'user'],   // List
  'metadata': {                 // Nested Map
    'department': 'Engineering',
    'level': 5,
  },
};
await db.insert(doc);
```

See [SUPPORTED_DATA_TYPES.md](SUPPORTED_DATA_TYPES.md) for detailed documentation and examples.

### Query documents

```dart
// ── Exact match — O(1) with HashIndex ─────────────────────────────────────
final ids = db.query().where('city').equals('London').findIds();

// ── Negation ───────────────────────────────────────────────────────────────
final notLondon = db.query().where('city').not().equals('London').findIds();

// ── Range query — O(log n) with SortedIndex ────────────────────────────────
final adultsIds = db.query().where('age').between(18, 65).findIds();
final seniorIds = db.query().where('age').greaterThan(60).findIds();
final youngIds  = db.query().where('age').lessThanOrEqualTo(25).findIds();

// ── Multi-field AND query (most selective index evaluated first) ───────────
final ids = db.query()
    .where('city').equals('London')
    .where('age').between(25, 40)
    .findIds();

// ── OR query ───────────────────────────────────────────────────────────────
final ids = db.query()
    .where('city').equals('London')
    .or()
    .where('city').equals('Paris')
    .findIds();

// ── isIn ───────────────────────────────────────────────────────────────────
final ids = db.query().where('city').isIn(['London', 'Tokyo']).findIds();

// ── String search ─────────────────────────────────────────────────────────
// startsWith uses O(log n) range scan on SortedIndex, O(n) scan on HashIndex
final ids = db.query().where('name').startsWith('Al').findIds();
final ids = db.query().where('name').contains('ice').findIds();

// ── Bitmask / boolean fields ───────────────────────────────────────────────
final activeIds = db.query().where('active').equals(true).findIds();

// ── Sorting + pagination ───────────────────────────────────────────────────
final pageIds = db.query()
    .where('city').equals('London')
    .sortBy('age')                // requires a SortedIndex on 'age'
    .limit(10)
    .skip(20)
    .findIds();

// ── Fetch full documents — direct API (new in 0.0.14) ───────────────────────
// db.query().find() resolves documents without a manual findById loop
final londonDocs = await db.query()
    .where('city').equals('London')
    .find();                           // Future<List<dynamic>>

// First match only — most efficient when you need a single document
final alice = await db.query()
    .where('name').startsWith('Al')
    .findFirst();                      // Future<dynamic> — null if no match

// Count only — O(1) for simple equals on indexed fields
final londonCount = db.query()
    .where('city').equals('London')
    .count();                          // int, synchronous

// ── Fetch full documents — classic API ────────────────────────────────────
final alice  = await db.findById(id);           // O(log n) by primary key
final people = await db.find((q) => q.where('city').equals('London').findIds());
final all    = await db.getAll();

// ── Lazy stream (one document at a time) ──────────────────────────────────
await for (final doc in db.findStream((q) => q.where('city').equals('London').findIds())) {
  print(doc);
}

// ── Range scan by primary key ─────────────────────────────────────────────
final ids = await db.rangeSearch(100, 200);

// ── Aggregations ──────────────────────────────────────────────────────────
final count  = await db.countWhere((q) => q.where('city').equals('London').findIds());
final total  = await db.sumWhere((q) => q.where('active').equals(true).findIds(), 'age');
final avg    = await db.avgWhere((q) => q.where('active').equals(true).findIds(), 'age');
final oldest = await db.maxWhere((q) => q.where('city').equals('London').findIds(), 'age');

// ── Query plan inspection (debugging slow queries) ─────────────────────────
print(db.query().where('city').equals('London').where('age').between(18, 65).explain());
// QueryPlan {
//   Group 0 (AND):
//     equals             city           → HashIndex (~3 docs)
//     between            age            → SortedIndex (~12 docs)
// }
```

### Update documents

```dart
// Partial update — merges specified fields, leaves the rest unchanged
await db.update(id, {'age': 31, 'city': 'Berlin'});

// Bulk update matching a query (single atomic transaction)
final updated = await db.updateWhere(
  (q) => q.where('city').equals('London').findIds(),
  {'country': 'UK'},
);
```

### Delete documents

```dart
await db.delete(id);

// Bulk delete matching a query (single atomic transaction)
final removed = await db.deleteWhere(
  (q) => q.where('active').equals(false).findIds(),
);

// Reclaim disk space after many deletes
await db.compact();

// Auto-compact: compact automatically when > 30% of slots are deleted
final db = FastDB(storage, autoCompactThreshold: 0.3);
```

### Transactions

> Transactions require a `WalStorageStrategy` for full atomicity and rollback.
> Without WAL, rollback is best-effort (in-memory state is restored but disk
> writes may not be undone).

```dart
await db.transaction(() async {
  final id = await db.insert({'name': 'Alice', 'balance': 100});
  await db.update(id, {'balance': 80});
  // If this throws, ALL operations above are rolled back automatically.
  if (someCondition) throw Exception('Abort!');
});

// Transactions do NOT support nesting — flatten concurrent work into one call.
```

### TypeAdapters (typed objects)

```dart
class User {
  final int    id;
  final String name;
  final int    age;
  User(this.id, this.name, this.age);
}

class UserAdapter extends TypeAdapter<User> {
  @override int get typeId => 1; // must be unique across all adapters

  @override
  User read(BinaryReader reader) {
    return User(
      reader.readUint32(),   // id
      reader.readString(),   // name
      reader.readUint32(),   // age
    );
  }

  @override
  void write(BinaryWriter writer, User user) {
    writer.writeUint32(user.id);
    writer.writeString(user.name);
    writer.writeUint32(user.age);
  }
}

// Register BEFORE open() — duplicate typeId throws ArgumentError
db.registerAdapter(UserAdapter());
db.addIndex('name');
await db.open();

final id = await db.insert(User(0, 'Alice', 30));
final user = await db.findById(id) as User;
```

### DateTime fields

`DateTime` is natively supported in both JSON map documents and binary TypeAdapters:

```dart
// In JSON maps — serialized as millisecondsSinceEpoch automatically
await db.insert({'name': 'Alice', 'createdAt': DateTime.now()});

// In TypeAdapters using writeDynamic / readDynamic
writer.writeDynamic(DateTime.now());  // stores as int64 ms-since-epoch
final dt = reader.readDynamic() as DateTime;
```

### Reactive watchers

```dart
// Returns a broadcast Stream — new events emitted after every write
// The stream is automatically cleaned up when all listeners unsubscribe.
final stream = db.watch('city');
final sub = stream.listen((ids) => print('city index now holds IDs: $ids'));

// Cancel when done — the StreamController is disposed automatically
await sub.cancel();
```

### Schema migrations

```dart
final db = await FfastDb.init(
  storage,
  version: 2,
  migrations: {
    // called for every document when upgrading from version 1 → 2
    1: (doc) {
      if (doc is Map<String, dynamic>) {
        return {...doc, 'country': 'unknown'}; // add new field with default
      }
      return doc;
    },
  },
);
```

### Rebuild indexes manually

```dart
// Rebuild a specific index (e.g. after adding a new one to existing data)
await db.reindex('city');

// Rebuild all indexes at once
await db.reindex();
```

---

## Architecture

```
FastDB
├── B-Tree primary index (O(log n) lookups, bulk-load O(N))
├── Secondary indexes
│   ├── HashIndex    — O(1) exact-match
│   ├── SortedIndex  — O(log n) range / sortBy
│   └── BitmaskIndex — bitwise AND for boolean / enum fields
├── LRU Page Cache (configurable RAM budget)
│   └── Default: 256 pages = 1 MB RAM
├── WAL (Write-Ahead Log)
│   ├── CRC32 checksums per entry AND per document
│   ├── Atomic COMMIT markers
│   └── Auto crash recovery on open()
├── BufferedStorageStrategy
│   └── Write coalescing (~9x faster bulk inserts)
└── StorageStrategy (platform-specific)
    ├── IoStorageStrategy      (Mobile / Desktop / Server — file lock + WAL)
    ├── MemoryStorageStrategy  (Tests / in-memory, zero persistence)
    ├── WebStorageStrategy     (In-memory base, no dart:io, safe for web)
    ├── LocalStorageStrategy   (Web JS / WASM — persists in browser localStorage)
    ├── IndexedDbStorageStrategy (Web JS / WASM — persists in browser IndexedDB)
    └── EncryptedStorageStrategy (Wrapper — XOR obfuscation; see docs for AES guidance)
```

---

## Performance

Benchmarks on a mid-range device (in-memory storage):

| Operation | FastDB | Hive |
|---|---|---|
| Single insert | ~0.3 ms | ~0.1 ms |
| Batch 5k inserts | **89 ms** | N/A |
| Lookup by ID (B-Tree) | ~1.8 ms | O(n) |
| Query by index (1 667/5 000) | ~3 ms | O(n) |
| LRU cache hit rate | **100 %** | N/A |

---

## File Structure

For a database at path `/data/users.db`, FastDB creates:

```
/data/users.db      ← Main database file (FDB2 format)
/data/users.db.wal  ← Write-Ahead Log (deleted after checkpoint)
/data/users.db.lock ← Process lock file (deleted on close)
```

---

## License

MIT © 2026
