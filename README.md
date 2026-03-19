# FastDB 🚀

A high-performance, pure-Dart NoSQL database for Flutter & server-side Dart.

[![pub.dev](https://img.shields.io/pub/v/fastdb)](https://pub.dev/packages/fastdb)
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
| Web support | ✅ | ✅ | ❌ |

---

## Getting Started

```yaml
dependencies:
  fastdb: ^0.1.0
```

### Open a database

```dart
import 'package:fastdb/fastdb.dart';
import 'package:fastdb/src/storage/io/io_storage_strategy.dart';
import 'package:fastdb/src/storage/wal_storage_strategy.dart';

// Production setup: file on disk + WAL crash protection + file lock
final storage = IoStorageStrategy('/data/myapp/users.db');
final wal = WalStorageStrategy(
  main: storage,
  wal: IoStorageStrategy('/data/myapp/users.db.wal'),
);
final db = FastDB(wal, cacheCapacity: 512);
await db.open();

// Development / testing: in-memory (no persistence)
final db = FastDB(MemoryStorageStrategy());
await db.open();
```

### Insert documents

```dart
// Insert a JSON map
final id = await db.insert({
  'name': 'Alice',
  'age': 30,
  'city': 'London',
});

// Batch insert (9x faster for bulk loads)
final ids = await db.insertAll([
  {'name': 'Bob', 'city': 'Paris'},
  {'name': 'Clara', 'city': 'Tokyo'},
]);
```

### Query documents

```dart
// Add secondary index before inserting (or it won't be populated)
db.addIndex('city');
db.addIndex('age');

// Exact match — O(1)
final londonIds = db.query().where('city').equals('London').findIds();

// Range query
final adultIds = db.query().where('age').between(18, 65).findIds();

// Sorting + pagination
final pageIds = db.query()
    .where('city').equals('London')
    .sortBy('age')
    .limit(10)
    .skip(20)
    .findIds();

// Find by primary key — O(log n)
final alice = await db.findById(id);
```

### Update documents

```dart
// Partial update — only changes specified fields
await db.update(id, {'age': 31, 'city': 'Berlin'});
```

### Delete documents

```dart
await db.delete(id);

// Reclaim disk space after many deletes
await db.compact();
```

### Transactions

```dart
await db.transaction(() async {
  await db.insert({'name': 'Alice'});
  await db.insert({'name': 'Bob'});
  // If this throws, both inserts are rolled back (WAL-backed DBs)
});
```

### TypeAdapters (typed objects)

```dart
class User {
  final int id;
  final String name;
  User(this.id, this.name);
}

class UserAdapter extends TypeAdapter<User> {
  @override
  int get typeId => 1;

  @override
  User read(FastBinaryReader reader) {
    return User(reader.readInt(), reader.readString());
  }

  @override
  void write(FastBinaryWriter writer, User user) {
    writer.writeInt(user.id);
    writer.writeString(user.name);
  }
}

db.registerAdapter(UserAdapter());
db.addIndex('name');
await db.insert(User(1, 'Alice'));
```

### Reactive watchers

```dart
final stream = db.watch('city');
stream.listen((ids) => print('City index updated: $ids'));
```

---

## Architecture

```
FastDB
├── B-Tree primary index (O(log n) lookups)
├── HashIndex secondary indexes (O(1) lookups)
├── LRU Page Cache (configurable RAM budget)
│   └── Default: 256 pages = 1MB RAM
├── WAL (Write-Ahead Log)
│   ├── CRC32 checksums per entry
│   ├── Atomic COMMIT markers
│   └── Auto crash recovery on open()
├── BufferedStorageStrategy
│   └── Write coalescing (9x faster bulk inserts)
└── StorageStrategy (platform-specific)
    ├── IoStorageStrategy     (Mobile/Desktop + file lock)
    ├── MemoryStorageStrategy (Tests/Web fallback)
    └── WebStorageStrategy    (IndexedDB)
```

---

## Performance

Benchmarks on a mid-range device (in-memory storage):

| Operation | FastDB | Hive |
|---|---|---|
| Single insert | ~0.3ms | ~0.1ms |
| Batch 5k inserts | **89ms** | N/A |
| Lookup by ID (B-Tree) | ~1.8ms | O(n) |
| Query by index (1667/5k) | ~3ms | O(n) |
| LRU cache hit rate | **100%** | N/A |

---

## File Structure

For a database at path `/data/users.db`, FastDB creates:

```
/data/users.db      ← Main database file
/data/users.db.wal  ← Write-Ahead Log (deleted after checkpoint)
/data/users.db.lock ← Process lock file (deleted on close)
```

---

## License

MIT © 2025
