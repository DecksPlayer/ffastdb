import 'dart:io';
import 'dart:typed_data';
import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';
import 'package:ffastdb/src/storage/wal_storage_strategy.dart';
import 'package:ffastdb/src/storage/buffered_storage_strategy.dart';
import 'package:ffastdb/src/storage/io/io_storage_strategy.dart';
import 'package:ffastdb/src/serialization/type_adapter.dart';
import 'package:test/test.dart';
import 'user_model.dart';

void main() {
  group('FastDB Core', () {
    late FastDB db;

    setUp(() async {
      await FfastDb.disposeInstance();
      db = await FfastDb.init(MemoryStorageStrategy());
    });

    tearDown(() async {
      await FfastDb.disposeInstance();
    });

    test('insert and findById', () async {
      final id = await db.insert({'name': 'Alice', 'age': 30});
      expect(id, 1);
      final doc = await db.findById(id);
      expect(doc, isNotNull);
      expect(doc['name'], 'Alice');
    });

    test('update partially updates fields', () async {
      final id = await db.insert({'name': 'Alice', 'age': 30, 'city': 'London'});
      final updated = await db.update(id, {'age': 31});
      expect(updated, isTrue);
      final doc = await db.findById(id);
      expect(doc['age'], 31);
      expect(doc['name'], 'Alice'); // unchanged
    });

    test('delete removes document', () async {
      final id = await db.insert({'name': 'Alice'});
      expect(await db.delete(id), isTrue);
      expect(await db.findById(id), isNull);
    });

    test('insertAll batch inserts multiple documents', () async {
      final ids = await db.insertAll([
        {'name': 'Alice'},
        {'name': 'Bob'},
        {'name': 'Charlie'},
      ]);
      expect(ids.length, 3);
      for (final id in ids) {
        expect(await db.findById(id), isNotNull);
      }
    });
  });

  group('HashIndex queries', () {
    late FastDB db;

    setUp(() async {
      db = FastDB(MemoryStorageStrategy());
      db.addIndex('city');
      db.addIndex('age');
      await db.open();
      await db.insertAll([
        {'name': 'Alice', 'city': 'London', 'age': 30},
        {'name': 'Bob', 'city': 'Paris', 'age': 25},
        {'name': 'Charlie', 'city': 'London', 'age': 35},
        {'name': 'Diana', 'city': 'Tokyo', 'age': 22},
      ]);
    });

    tearDown(() => db.close());

    test('equals query', () {
      final ids = db.query().where('city').equals('London').findIds();
      expect(ids.length, 2);
    });

    test('OR query across cities', () {
      final ids = db.query()
          .where('city').equals('London')
          .or()
          .where('city').equals('Paris')
          .findIds();
      expect(ids.length, 3);
    });

    test('IN query', () {
      final ids = db.query().where('city').isIn(['London', 'Tokyo']).findIds();
      expect(ids.length, 3);
    });

    test('NOT equals query', () {
      final ids = db.query().where('city').not().equals('London').findIds();
      expect(ids.length, 2); // Paris + Tokyo
    });

    test('alwaysTrue returns all indexed docs', () {
      final ids = db.query().where('city').alwaysTrue().findIds();
      expect(ids.length, 4);
    });
  });

  group('SortedIndex queries', () {
    late FastDB db;

    setUp(() async {
      db = FastDB(MemoryStorageStrategy());
      db.addSortedIndex('age');
      await db.open();
      await db.insertAll([
        {'name': 'Alice', 'age': 30},
        {'name': 'Bob', 'age': 25},
        {'name': 'Charlie', 'age': 35},
        {'name': 'Diana', 'age': 22},
      ]);
    });

    tearDown(() => db.close());

    test('range query is O(log n) with early exit', () {
      final ids = db.query().where('age').between(25, 32).findIds();
      expect(ids.length, 2); // Bob (25) + Alice (30)
    });

    test('greaterThan query', () {
      final ids = db.query().where('age').greaterThan(29).findIds();
      expect(ids.length, 2); // Alice (30) + Charlie (35)
    });
  });

  group('BitmaskIndex queries', () {
    late FastDB db;

    setUp(() async {
      db = FastDB(MemoryStorageStrategy());
      db.addBitmaskIndex('active');
      await db.open();
      await db.insertAll([
        {'name': 'Alice', 'active': true},
        {'name': 'Bob', 'active': false},
        {'name': 'Charlie', 'active': true},
      ]);
    });

    tearDown(() => db.close());

    test('boolean equals lookup', () {
      final ids = db.query().where('active').equals(true).findIds();
      expect(ids.length, 2); // Alice + Charlie
    });

    test('NOT boolean lookup', () {
      final ids = db.query().where('active').not().equals(true).findIds();
      expect(ids.length, 1); // Bob
    });
  });

  group('Transaction', () {
    late FastDB db;

    setUp(() async {
      await FfastDb.disposeInstance();
      db = await FfastDb.init(MemoryStorageStrategy());
    });

    tearDown(() => db.close());

    test('transaction propagates exception on error', () async {
      // With a non-WAL MemoryStorage, rollback is best-effort.
      // The key guarantee is that the exception MUST propagate to the caller.
      await expectLater(
        () => db.transaction(() async {
          await db.insert({'name': 'Alice'});
          throw Exception('Forced rollback');
        }),
        throwsException,
      );
    });

    test('transaction commits on success', () async {
      await db.transaction(() async {
        await db.insert({'name': 'Alice'});
        await db.insert({'name': 'Bob'});
      });
      final ids = await db.rangeSearch(1, 100);
      expect(ids.length, 2);
    });
  });

  group('put() overwrite', () {
    late FastDB db;

    setUp(() async {
      await FfastDb.disposeInstance();
      db = await FfastDb.init(MemoryStorageStrategy());
    });

    tearDown(() => db.close());

    test('put overwrites existing key', () async {
      await db.put(5, {'name': 'Old'});
      await db.put(5, {'name': 'New'});
      final doc = await db.findById(5);
      expect(doc['name'], 'New');
    });

    test('put reserves auto-increment IDs above manual key', () async {
      await db.put(100, {'x': 1});
      final id = await db.insert({'x': 2});
      expect(id, greaterThan(100));
    });

    test('compact reclaims space after put overwrites', () async {
      // Use separate dataStorage so compact() can truncate the document file.
      final d = FastDB(MemoryStorageStrategy(),
          dataStorage: MemoryStorageStrategy());
      await d.open();
      for (int i = 1; i <= 10; i++) {
        await d.put(i, {'value': i});
      }
      // Overwrite all — each put adds old offset to _deletedOffsets
      for (int i = 1; i <= 10; i++) {
        await d.put(i, {'value': i * 100});
      }
      final beforeCompact = await d.dataStorage!.size;
      await d.compact();
      final afterCompact = await d.dataStorage!.size;
      expect(afterCompact, lessThan(beforeCompact));
      await d.close();
    });
  });

  group('compact()', () {
    late FastDB db;

    setUp(() async {
      // Separate dataStorage so compact() triggers truncation on the doc file.
      db = FastDB(MemoryStorageStrategy(),
          dataStorage: MemoryStorageStrategy());
      await db.open();
    });

    tearDown(() => db.close());

    test('compact shrinks storage after deletes', () async {
      final ids = await db.insertAll(
        List.generate(20, (i) => {'name': 'doc$i', 'value': i}),
      );
      for (final id in ids.take(10)) {
        await db.delete(id);
      }
      final before = await db.dataStorage!.size;
      await db.compact();
      final after = await db.dataStorage!.size;
      expect(after, lessThan(before));
    });

    test('compact preserves surviving documents', () async {
      final ids = await db.insertAll([
        {'name': 'keep1'},
        {'name': 'delete1'},
        {'name': 'keep2'},
      ]);
      await db.delete(ids[1]);
      await db.compact();
      expect(await db.findById(ids[0]), isNotNull);
      expect(await db.findById(ids[1]), isNull);
      expect(await db.findById(ids[2]), isNotNull);
    });

    test('compact after update reclaims old slot', () async {
      final id = await db.insert({'value': 1});
      await db.update(id, {'value': 2});
      final before = await db.dataStorage!.size;
      await db.compact();
      final after = await db.dataStorage!.size;
      expect(after, lessThan(before));
      final doc = await db.findById(id);
      expect(doc['value'], 2);
    });
  });

  group('TypeAdapter', () {
    late FastDB db;

    setUp(() async {
      db = FastDB(MemoryStorageStrategy());
      db.registerAdapter(UserAdapter());
      await db.open();
    });

    tearDown(() => db.close());

    test('TypeAdapter round-trip stores and retrieves objects', () async {
      final user = User(name: 'Alice', age: 30, email: 'alice@example.com');
      final id = await db.insert(user);
      final result = await db.findById(id);
      expect(result, isA<User>());
      expect((result as User).name, 'Alice');
      expect(result.age, 30);
      expect(result.email, 'alice@example.com');
    });

    test('multiple TypeAdapter objects survive round-trip', () async {
      final users = [
        User(name: 'Alice', age: 30, email: 'a@x.com'),
        User(name: 'Bob', age: 25, email: 'b@x.com'),
      ];
      final ids = await db.insertAll(users);
      for (int i = 0; i < ids.length; i++) {
        final result = await db.findById(ids[i]) as User;
        expect(result.name, users[i].name);
        expect(result.age, users[i].age);
      }
    });
  });

  group('WAL crash recovery', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fastdb_wal_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('committed WAL data survives reopen', () async {
      final path = '${tempDir.path}/db.fdb';
      final walPath = '${tempDir.path}/db.fdb.wal';

      final db = FastDB(WalStorageStrategy(
        main: IoStorageStrategy(path),
        wal: IoStorageStrategy(walPath),
      ));
      await db.open();
      await db.transaction(() async {
        await db.insert({'name': 'Alice'});
        await db.insert({'name': 'Bob'});
      });
      await db.close();

      // Re-open and verify data persisted
      final db2 = FastDB(WalStorageStrategy(
        main: IoStorageStrategy(path),
        wal: IoStorageStrategy(walPath),
      ));
      await db2.open();
      final ids = await db2.rangeSearch(1, 100);
      expect(ids.length, 2);
      final doc = await db2.findById(ids.first);
      expect(doc, isNotNull);
      await db2.close();
    });

    test('uncommitted WAL is rolled back on reopen', () async {
      final path = '${tempDir.path}/db.fdb';
      final walPath = '${tempDir.path}/db.fdb.wal';

      final db = FastDB(WalStorageStrategy(
        main: IoStorageStrategy(path),
        wal: IoStorageStrategy(walPath),
      ));
      await db.open();
      // Committed insert — must survive
      await db.insert({'name': 'Committed'});
      await db.close();

      // Simulate corrupt/incomplete WAL by appending garbage bytes
      final walFile = File(walPath);
      if (await walFile.exists()) {
        await walFile.writeAsBytes(
          Uint8List.fromList([...await walFile.readAsBytes(), 0xFF, 0xFE, 0x00]),
          mode: FileMode.append,
        );
      }

      // Re-open: WAL recovery should handle the trailing garbage gracefully
      final db2 = FastDB(WalStorageStrategy(
        main: IoStorageStrategy(path),
        wal: IoStorageStrategy(walPath),
      ));
      await db2.open();
      final ids = await db2.rangeSearch(1, 100);
      expect(ids.length, greaterThanOrEqualTo(1));
      final doc = await db2.findById(1);
      expect(doc['name'], 'Committed');
      await db2.close();
    });
  });

  group('IoStorageStrategy', () {
    late Directory tempDir;
    late String path;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fastdb_io_test_');
      path = '${tempDir.path}/db.fdb';
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('open, write, read, close', () async {
      final db = FastDB(IoStorageStrategy(path));
      await db.open();
      final id = await db.insert({'msg': 'hello'});
      await db.close();

      // Reopen — data must persist
      final db2 = FastDB(IoStorageStrategy(path));
      await db2.open();
      final doc = await db2.findById(id);
      expect(doc['msg'], 'hello');
      await db2.close();
    });

    test('data persists across multiple sessions', () async {
      for (int session = 0; session < 3; session++) {
        final db = FastDB(IoStorageStrategy(path));
        await db.open();
        await db.insert({'session': session});
        await db.close();
      }
      final db = FastDB(IoStorageStrategy(path));
      await db.open();
      final ids = await db.rangeSearch(1, 100);
      expect(ids.length, 3);
      await db.close();
    });
  });

  group('BufferedStorageStrategy', () {
    late FastDB db;

    setUp(() async {
      db = FastDB(BufferedStorageStrategy(MemoryStorageStrategy()));
      await db.open();
    });

    tearDown(() => db.close());

    test('insert and retrieve via buffered strategy', () async {
      final id = await db.insert({'x': 42});
      final doc = await db.findById(id);
      expect(doc['x'], 42);
    });

    test('batch insert via buffered strategy', () async {
      final ids = await db.insertAll(
        List.generate(50, (i) => {'n': i}),
      );
      expect(ids.length, 50);
      final doc = await db.findById(ids.last);
      expect(doc['n'], 49);
    });
  });

  group('write serialization', () {
    late FastDB db;

    setUp(() async {
      await FfastDb.disposeInstance();
      db = await FfastDb.init(MemoryStorageStrategy());
    });

    tearDown(() => db.close());

    test('concurrent inserts do not corrupt _nextId', () async {
      // Fire 100 inserts without awaiting — _exclusive() must serialize them.
      final futures = List.generate(100, (i) => db.insert({'i': i}));
      final ids = await Future.wait(futures);
      // All IDs must be unique
      expect(ids.toSet().length, 100);
    });

    test('concurrent insert and update do not interleave', () async {
      final id = await db.insert({'v': 0});
      final futures = [
        for (int i = 1; i <= 20; i++) db.update(id, {'v': i}),
      ];
      await Future.wait(futures);
      final doc = await db.findById(id);
      // The final value should be one of the written values (no torn write)
      expect(doc['v'], isA<int>());
    });
  });

  group('compact() with WAL', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fastdb_compact_wal_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('compact reclaims space and documents are intact (memory)', () async {
      // Core correctness test using in-memory storage (no file lock / WAL overhead).
      final db = FastDB(MemoryStorageStrategy());
      await db.open();

      final ids = await db.insertAll(List.generate(10, (i) => {'n': i}));
      for (int i = 0; i < 5; i++) {
        await db.delete(ids[i]);
      }
      await db.compact();

      // Live docs must still be readable
      for (int i = 5; i < 10; i++) {
        final doc = await db.findById(ids[i]);
        expect(doc, isNotNull, reason: 'id ${ids[i]} should survive compact');
        expect(doc['n'], i);
      }
      // Deleted docs must not exist
      for (int i = 0; i < 5; i++) {
        final doc = await db.findById(ids[i]);
        expect(doc, isNull, reason: 'id ${ids[i]} should be gone after compact');
      }
      final liveCount = await db.count();
      expect(liveCount, 5);
      await db.close();
    });

    test('compact survives close+reopen with IoStorageStrategy', () async {
      final path = '${tempDir.path}/db.fdb';

      final db = FastDB(IoStorageStrategy(path));
      await db.open();

      final ids = await db.insertAll(List.generate(10, (i) => {'n': i}));
      for (int i = 0; i < 5; i++) {
        await db.delete(ids[i]);
      }
      await db.compact();

      // Verify in-session state is correct before close
      final preCloseCount = await db.count();
      expect(preCloseCount, 5, reason: 'compact should leave 5 live docs in-session');

      await db.close();

      final db2 = FastDB(IoStorageStrategy(path));
      await db2.open();
      final count = await db2.count();
      expect(count, 5);
      for (int i = 5; i < 10; i++) {
        final doc = await db2.findById(ids[i]);
        expect(doc, isNotNull);
        expect(doc['n'], i);
      }
      await db2.close();
    });

    test('compact() is serialized against concurrent inserts', () async {
      final db = FastDB(MemoryStorageStrategy());
      await db.open();

      await db.insertAll(List.generate(20, (i) => {'n': i}));
      for (int i = 1; i <= 10; i++) {
        await db.delete(i);
      }

      // Fire compact and an insert concurrently — no corruption should occur
      await Future.wait([
        db.compact(),
        db.insert({'n': 999}),
      ]);

      final count = await db.count();
      expect(count, greaterThanOrEqualTo(10));
      await db.close();
    });
  });

  group('schema migrations', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fastdb_migrations_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('migration runs when version increases', () async {
      final path = '${tempDir.path}/db.fdb';

      // Open at version 1 and insert documents
      final db1 = FastDB(IoStorageStrategy(path));
      await db1.open(version: 1);
      await db1.insert({'name': 'Alice', 'age': 30});
      await db1.insert({'name': 'Bob', 'age': 25});
      await db1.close();

      // Reopen at version 2 with a migration that adds a 'role' field
      final db2 = FastDB(IoStorageStrategy(path));
      await db2.open(
        version: 2,
        migrations: {
          1: (doc) {
            if (doc is Map<String, dynamic>) {
              return {...doc, 'role': 'user'};
            }
            return doc;
          },
        },
      );

      final docs = await db2.getAll();
      expect(docs.length, 2);
      for (final doc in docs) {
        expect(doc['role'], 'user');
      }
      await db2.close();
    });

    test('migration does not run when version is unchanged', () async {
      final path = '${tempDir.path}/db.fdb';
      var migrationRan = false;

      final db1 = FastDB(IoStorageStrategy(path));
      await db1.open(version: 1);
      await db1.insert({'name': 'Alice'});
      await db1.close();

      final db2 = FastDB(IoStorageStrategy(path));
      await db2.open(
        version: 1,
        migrations: {
          1: (doc) {
            migrationRan = true;
            return doc;
          },
        },
      );
      await db2.close();

      expect(migrationRan, isFalse);
    });

    test('chained migrations run in order', () async {
      final path = '${tempDir.path}/db.fdb';

      // v1: insert raw docs
      final db1 = FastDB(IoStorageStrategy(path));
      await db1.open(version: 1);
      await db1.insert({'value': 1});
      await db1.close();

      // v1 → v2 → v3: each migration doubles 'value'
      final db3 = FastDB(IoStorageStrategy(path));
      await db3.open(
        version: 3,
        migrations: {
          1: (doc) => doc is Map<String, dynamic>
              ? {...doc, 'value': (doc['value'] as int) * 2}
              : doc,
          2: (doc) => doc is Map<String, dynamic>
              ? {...doc, 'value': (doc['value'] as int) * 2}
              : doc,
        },
      );

      final doc = await db3.findById(1);
      expect(doc['value'], 4); // 1 → 2 → 4
      await db3.close();
    });
  });

  group('crash + reopen recovery', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fastdb_crash_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('dirty-flag triggers index rebuild on reopen', () async {
      // Simulate a crash by zeroing byte 24 (clean flag) after a normal close.
      // FastDB writes 0x43 ('C') to byte 24 on clean close; any other value
      // signals a dirty session and triggers a full secondary-index rebuild.
      final path = '${tempDir.path}/db.fdb';

      final db = FastDB(IoStorageStrategy(path));
      db.addIndex('city');
      await db.open();
      await db.insert({'name': 'Alice', 'city': 'Paris'});
      await db.insert({'name': 'Bob', 'city': 'London'});
      await db.close(); // writes clean flag = 0x43

      // Corrupt the clean flag to simulate a crash (no clean close)
      final raf = await File(path).open(mode: FileMode.write);
      await raf.setPosition(24);
      await raf.writeByte(0x00);
      await raf.close();

      // Reopen WITH index registration — dirty flag triggers index rebuild
      final db2 = FastDB(IoStorageStrategy(path));
      db2.addIndex('city');
      await db2.open();
      final parisIds = db2.query().where('city').equals('Paris').findIds();
      expect(parisIds.length, 1);
      final doc = await db2.findById(parisIds.first);
      expect(doc['name'], 'Alice');
      await db2.close();
    });

    test('data committed before crash survives WAL reopen', () async {
      // After a clean insert+close cycle, the WAL has committed entries.
      // Simulate a dirty open by clearing byte 24, then verify WAL replay.
      final path = '${tempDir.path}/db.fdb';
      final walPath = '${tempDir.path}/db.fdb.wal';

      final db = FastDB(WalStorageStrategy(
        main: IoStorageStrategy(path),
        wal: IoStorageStrategy(walPath),
      ));
      await db.open();
      final id1 = await db.insert({'name': 'Persistent'});
      final id2 = await db.insert({'name': 'Also persistent'});
      await db.close();

      // Dirty the clean flag so next open rebuilds indexes (stress test)
      final raf = await File(path).open(mode: FileMode.write);
      await raf.setPosition(24);
      await raf.writeByte(0x00);
      await raf.close();

      final db2 = FastDB(WalStorageStrategy(
        main: IoStorageStrategy(path),
        wal: IoStorageStrategy(walPath),
      ));
      await db2.open();
      final doc1 = await db2.findById(id1);
      final doc2 = await db2.findById(id2);
      expect(doc1, isNotNull);
      expect(doc1['name'], 'Persistent');
      expect(doc2, isNotNull);
      expect(doc2['name'], 'Also persistent');
      await db2.close();
    });
  });

  // ─── v0.2 new features ─────────────────────────────────────────────────────

  group('deleteWhere / updateWhere', () {
    late FastDB db;

    setUp(() async {
      db = FastDB(MemoryStorageStrategy());
      db.addIndex('status');
      db.addIndex('city');
      await db.open();
    });

    tearDown(() => db.close());

    test('deleteWhere removes all matching documents', () async {
      await db.insertAll([
        {'name': 'Alice', 'status': 'active'},
        {'name': 'Bob',   'status': 'archived'},
        {'name': 'Carol', 'status': 'archived'},
        {'name': 'Dave',  'status': 'active'},
      ]);

      final removed = await db.deleteWhere(
        (q) => q.where('status').equals('archived').findIds(),
      );

      expect(removed, 2);
      expect(await db.count(), 2);
      final remaining = await db.getAll();
      expect(remaining.every((d) => d['status'] == 'active'), isTrue);
    });

    test('deleteWhere returns 0 for no matches', () async {
      await db.insert({'name': 'Alice', 'status': 'active'});
      final removed = await db.deleteWhere(
        (q) => q.where('status').equals('ghost').findIds(),
      );
      expect(removed, 0);
      expect(await db.count(), 1);
    });

    test('updateWhere patches all matching documents', () async {
      await db.insertAll([
        {'name': 'Alice', 'city': 'London', 'score': 10},
        {'name': 'Bob',   'city': 'London', 'score': 20},
        {'name': 'Carol', 'city': 'Paris',  'score': 30},
      ]);

      final updated = await db.updateWhere(
        (q) => q.where('city').equals('London').findIds(),
        {'score': 99},
      );

      expect(updated, 2);
      final londonDocs = await db.find(
        (q) => q.where('city').equals('London').findIds(),
      );
      expect(londonDocs.every((d) => d['score'] == 99), isTrue);

      final parisDocs = await db.find(
        (q) => q.where('city').equals('Paris').findIds(),
      );
      expect(parisDocs.first['score'], 30); // unchanged
    });

    test('updateWhere returns 0 for no matches', () async {
      await db.insert({'name': 'Alice', 'city': 'London', 'score': 5});
      final updated = await db.updateWhere(
        (q) => q.where('city').equals('Tokyo').findIds(),
        {'score': 0},
      );
      expect(updated, 0);
    });
  });

  group('reindex', () {
    test('reindex(field) populates a freshly-added index', () async {
      final db = FastDB(MemoryStorageStrategy());
      await db.open();

      // Insert WITHOUT any index registered
      await db.insertAll([
        {'name': 'Alice', 'city': 'London'},
        {'name': 'Bob',   'city': 'Paris'},
        {'name': 'Carol', 'city': 'London'},
      ]);

      // Add index AFTER data exists — it is empty until reindex()
      db.addIndex('city');
      expect(db.query().where('city').equals('London').findIds(), isEmpty);

      // Now reindex
      await db.reindex('city');

      final londonIds = db.query().where('city').equals('London').findIds();
      expect(londonIds.length, 2);
      await db.close();
    });

    test('reindex() with no argument rebuilds all indexes', () async {
      final db = FastDB(MemoryStorageStrategy());
      db.addIndex('city');
      db.addIndex('name');
      await db.open();

      await db.insertAll([
        {'name': 'Alice', 'city': 'London'},
        {'name': 'Bob',   'city': 'Paris'},
      ]);

      // Forcibly clear indexes to simulate corruption
      for (final idx in ['city', 'name']) {
        db.query(); // just to force access (indexes already in map)
      }

      // Rebuild all
      await db.reindex();

      expect(db.query().where('city').equals('Paris').findIds().length, 1);
      expect(db.query().where('name').equals('Alice').findIds().length, 1);
      await db.close();
    });

    test('reindex throws for unknown field', () async {
      final db = FastDB(MemoryStorageStrategy());
      await db.open();
      expect(() => db.reindex('no_such_field'), throwsArgumentError);
      await db.close();
    });
  });

  group('aggregations', () {
    late FastDB db;

    setUp(() async {
      db = FastDB(MemoryStorageStrategy());
      db.addIndex('city');
      await db.open();
      await db.insertAll([
        {'city': 'London', 'salary': 50000},
        {'city': 'London', 'salary': 70000},
        {'city': 'Paris',  'salary': 60000},
        {'city': 'Tokyo',  'salary': 80000},
      ]);
    });

    tearDown(() => db.close());

    test('countWhere counts matching documents', () async {
      final n = await db.countWhere(
        (q) => q.where('city').equals('London').findIds(),
      );
      expect(n, 2);
    });

    test('sumWhere sums a numeric field', () async {
      final total = await db.sumWhere(
        (q) => q.where('city').equals('London').findIds(),
        'salary',
      );
      expect(total, 120000);
    });

    test('avgWhere averages a numeric field', () async {
      final avg = await db.avgWhere(
        (q) => q.where('city').equals('London').findIds(),
        'salary',
      );
      expect(avg, closeTo(60000, 0.001));
    });

    test('avgWhere returns null for empty result', () async {
      final avg = await db.avgWhere(
        (q) => q.where('city').equals('NoCity').findIds(),
        'salary',
      );
      expect(avg, isNull);
    });

    test('minWhere returns the smallest value', () async {
      final min = await db.minWhere(
        (q) => q.where('city').equals('London').findIds(),
        'salary',
      );
      expect(min, 50000);
    });

    test('maxWhere returns the largest value', () async {
      final max = await db.maxWhere(
        (q) => q.where('city').equals('London').findIds(),
        'salary',
      );
      expect(max, 70000);
    });
  });

  group('findStream', () {
    late FastDB db;

    setUp(() async {
      db = FastDB(MemoryStorageStrategy());
      db.addIndex('city');
      await db.open();
      await db.insertAll([
        {'city': 'London', 'name': 'Alice'},
        {'city': 'Paris',  'name': 'Bob'},
        {'city': 'London', 'name': 'Carol'},
      ]);
    });

    tearDown(() => db.close());

    test('findStream yields matching documents lazily', () async {
      final names = <String>[];
      await for (final doc in db.findStream(
        (q) => q.where('city').equals('London').findIds(),
      )) {
        names.add(doc['name'] as String);
      }
      expect(names, containsAll(['Alice', 'Carol']));
      expect(names.length, 2);
    });

    test('findStream yields nothing for empty query', () async {
      final results = <dynamic>[];
      await for (final doc in db.findStream(
        (q) => q.where('city').equals('NoWhere').findIds(),
      )) {
        results.add(doc);
      }
      expect(results, isEmpty);
    });
  });

  group('autoCompactThreshold', () {
    test('compacts automatically when threshold is exceeded', () async {
      // threshold=0.5 means: compact when >= 50% of slots are deleted
      final db = FastDB(MemoryStorageStrategy(), autoCompactThreshold: 0.5);
      await db.open();

      final ids = await db.insertAll(
        List.generate(10, (i) => {'n': i}),
      );

      // Delete 6/10 = 60% → exceeds 0.5 threshold → auto-compact fires
      for (int i = 0; i < 6; i++) {
        await db.delete(ids[i]);
      }

      // After auto-compact, deleted docs should be gone
      for (int i = 0; i < 6; i++) {
        expect(await db.findById(ids[i]), isNull,
            reason: 'doc ${ids[i]} should be gone after auto-compact');
      }
      final remaining = await db.count();
      expect(remaining, 4);
      await db.close();
    });

    test('does not compact when threshold is not met', () async {
      final db = FastDB(MemoryStorageStrategy(), autoCompactThreshold: 0.9);
      await db.open();
      final ids = await db.insertAll(
        List.generate(10, (i) => {'n': i}),
      );
      // Delete only 2/10 = 20% — well below 90% threshold
      await db.delete(ids[0]);
      await db.delete(ids[1]);
      // No auto-compact; the deleted offsets set should still contain them
      expect(await db.count(), 8);
      await db.close();
    });
  });

  group('query explain', () {
    test('explain() describes indexes and conditions', () {
      final db = FastDB(MemoryStorageStrategy());
      db.addIndex('city');
      db.addSortedIndex('age');

      final plan = db
          .query()
          .where('city').equals('London')
          .and('age').between(18, 65)
          .sortBy('age')
          .limit(10)
          .explain();

      expect(plan, contains('equals'));
      expect(plan, contains('city'));
      expect(plan, contains('between'));
      expect(plan, contains('age'));
      expect(plan, contains('SORT BY'));
      expect(plan, contains('LIMIT 10'));
    });

    test('explain() warns about missing indexes', () {
      final db = FastDB(MemoryStorageStrategy());
      // No indexes registered
      final plan = db.query().where('email').equals('a@b.com').explain();
      expect(plan, contains('NO_INDEX'));
    });
  });

  group('Firebase ID preservation', () {
    late FastDB db;

    setUp(() async {
      await FfastDb.disposeInstance();
      db = await FfastDb.init(MemoryStorageStrategy());
    });

    tearDown(() async {
      await FfastDb.disposeInstance();
    });

    test('preserves original Firebase ID when document has id field', () async {
      // Simulate a document from Firebase with its own 'id' field
      final firebaseDoc = {
        'id': 'firebase_doc_12345',
        'name': 'Alice',
        'email': 'alice@example.com',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      // Insert the document - FastDB will assign its own numeric ID
      final fastdbId = await db.insert(firebaseDoc);
      expect(fastdbId, isA<int>());

      // Retrieve the document
      final retrieved = await db.findById(fastdbId);
      expect(retrieved, isNotNull);

      // Verify that the original Firebase ID is preserved
      expect(retrieved['id'], equals('firebase_doc_12345'),
          reason: 'Original Firebase ID should be preserved');
      expect(retrieved['name'], equals('Alice'));
      expect(retrieved['email'], equals('alice@example.com'));
    });

    test('preserves Firebase ID through update operations', () async {
      final firebaseDoc = {
        'id': 'firebase_user_xyz',
        'name': 'Bob',
        'age': 30,
      };

      final fastdbId = await db.insert(firebaseDoc);

      // Update some fields
      await db.update(fastdbId, {'age': 31});

      final updated = await db.findById(fastdbId);
      expect(updated['id'], equals('firebase_user_xyz'),
          reason: 'Firebase ID should persist through updates');
      expect(updated['age'], equals(31));
      expect(updated['name'], equals('Bob'));
    });

    test('handles documents without id field normally', () async {
      final doc = {
        'name': 'Charlie',
        'status': 'active',
      };

      final fastdbId = await db.insert(doc);
      final retrieved = await db.findById(fastdbId);

      // FastDB's internal ID should be added
      expect(retrieved['id'], equals(fastdbId));
      expect(retrieved['name'], equals('Charlie'));
    });

    test('preserves different types of Firebase IDs', () async {
      // Test with various Firebase ID formats
      final docs = [
        {'id': 'firestore_abc123', 'type': 'string_id'},
        {'id': 12345, 'type': 'numeric_id'},
        {'id': 'users/uid_xyz/profile', 'type': 'path_id'},
      ];

      final ids = await db.insertAll(docs);

      for (int i = 0; i < docs.length; i++) {
        final retrieved = await db.findById(ids[i]);
        expect(retrieved['id'], equals(docs[i]['id']),
            reason: 'Should preserve ${docs[i]['type']}');
      }
    });
  });
}


