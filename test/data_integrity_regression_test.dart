import 'dart:math';

import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

/// Regression tests for data-loss bugs found in the 0.3.5 audit.
/// Each test failed (lost or corrupted documents) before its fix.
void main() {
  group('B-Tree delete (B+ separators)', () {
    late FastDB db;

    setUp(() async {
      db = FastDB.forTesting(MemoryStorageStrategy());
      await db.open();
    });

    tearDown(() => db.close());

    test('deleting a leaf-separator id removes THAT document only', () async {
      // bulkLoad fills leaves with 229 keys (sentinel 0 + ids), so ids 229,
      // 458 and 687 are the first key of a leaf — i.e. internal separators.
      final ids = await db.insertAll(List.generate(1000, (i) => {'n': i}));
      const separators = [229, 458, 687];
      for (final id in separators) {
        expect(await db.delete(id), isTrue);
        expect(await db.findById(id), isNull, reason: 'id $id still present');
      }
      for (final id in ids) {
        if (separators.contains(id)) continue;
        final doc = await db.findById(id);
        expect(doc, isNotNull, reason: 'id $id lost');
        expect(doc['n'], id - 1);
      }
      expect(await db.count(), 1000 - separators.length);
    });

    test('random deletes after insertAll match a Map model', () async {
      final rnd = Random(42);
      final model = <int, int>{};
      final ids = await db.insertAll(List.generate(3000, (i) => {'n': i}));
      for (int i = 0; i < ids.length; i++) {
        model[ids[i]] = i;
      }
      final toDelete = model.keys.toList()..shuffle(rnd);
      for (final id in toDelete.take(2000)) {
        await db.delete(id);
        model.remove(id);
      }
      expect(await db.count(), model.length);
      for (final id in ids) {
        final doc = await db.findById(id);
        if (model.containsKey(id)) {
          expect(doc?['n'], model[id], reason: 'id $id');
        } else {
          expect(doc, isNull, reason: 'deleted id $id still present');
        }
      }
    });
  });

  group('secondary-index blob persistence', () {
    test('a smaller index blob does not truncate documents written after it',
        () async {
      final storage = MemoryStorageStrategy();
      Future<FastDB> reopen() async {
        final db = FastDB.forTesting(storage)..addIndex('status');
        await db.open();
        return db;
      }

      var db = await reopen();
      for (int i = 0; i < 50; i++) {
        await db.insert({'status': 'active_long_value_$i', 'i': i});
      }
      await db.close();

      // Next session: the index shrinks (deletes + short values) while new
      // documents are appended AFTER the previously persisted blob.
      db = await reopen();
      for (int id = 1; id <= 10; id++) {
        await db.delete(id);
      }
      final newIds = [
        for (int i = 0; i < 5; i++) await db.insert({'status': 'x', 'i': 100 + i}),
      ];
      await db.close();

      db = await reopen();
      for (final id in newIds) {
        expect(await db.findById(id), isNotNull, reason: 'id $id lost');
      }
      for (int id = 11; id <= 50; id++) {
        expect((await db.findById(id))?['i'], id - 1);
      }
      expect(await db.query().where('status').equals('x').count(), 5);
      await db.close();
    });
  });

  group('dual-file mode (dataStorage)', () {
    late FastDB db;

    setUp(() async {
      db = FastDB.forTesting(MemoryStorageStrategy(),
          dataStorage: MemoryStorageStrategy())
        ..addIndex('k');
      await db.open();
    });

    tearDown(() => db.close());

    test('insert after insertAll does not overwrite existing documents',
        () async {
      await db.insertAll(
          List.generate(2000, (i) => {'k': 'v$i', 'pad': 'x' * 50}));
      final id = await db.insert({'k': 'new'});
      for (int i = 1; i <= 2000; i++) {
        expect((await db.findById(i))?['k'], 'v${i - 1}', reason: 'id $i');
      }
      expect((await db.findById(id))?['k'], 'new');
    });

    test('compact after an update keeps every document intact', () async {
      for (int i = 0; i < 20; i++) {
        await db.insert({'n': i, 'pad': 'y' * 40});
      }
      // id 1 is relocated to the END of the data file; compact used to visit
      // it first and overwrite ids 2..n before reading them.
      await db.update(1, {'n': 1000});
      await db.update(7, {'n': 7000});
      await db.delete(20);
      await db.compact();
      for (int id = 1; id <= 19; id++) {
        final expected = id == 1 ? 1000 : (id == 7 ? 7000 : id - 1);
        final doc = await db.findById(id);
        expect(doc?['n'], expected, reason: 'id $id');
        expect(doc?['ffdbID'], id);
      }
      expect(await db.findById(20), isNull);
      expect(await db.count(), 19);
    });
  });

  group('index persistence', () {
    final local = DateTime(2024, 3, 4, 5, 6, 7, 8, 9);
    final utc = DateTime.utc(2023, 1, 2, 3, 4, 5, 6, 7);
    final values = <dynamic>[-5, -2147483648, 3, -9000000000, local, utc];

    test('SortedIndex round-trips negative ints and DateTimes', () {
      final idx = SortedIndex('f');
      for (int i = 0; i < values.length; i++) {
        idx.add(i + 1, values[i]);
      }
      final back = SortedIndex.deserialize(idx.serialize());
      for (int i = 0; i < values.length; i++) {
        expect(back.lookup(values[i]), [i + 1], reason: '${values[i]}');
        expect(back.valueOf(i + 1), values[i]);
      }
      expect(back.range(utc, local), [6, 5]);
    });

    test('HashIndex round-trips DateTimes (keeping isUtc)', () {
      final idx = HashIndex('f');
      for (int i = 0; i < values.length; i++) {
        idx.add(i + 1, values[i]);
      }
      final back = HashIndex.deserialize(idx.serialize());
      for (int i = 0; i < values.length; i++) {
        expect(back.lookup(values[i]), [i + 1], reason: '${values[i]}');
      }
      expect((back.valueOf(5) as DateTime).isUtc, isFalse);
      expect((back.valueOf(6) as DateTime).isUtc, isTrue);
    });

    test('BitmaskIndex round-trips negative ints and DateTimes', () {
      final idx = BitmaskIndex('f');
      for (int i = 0; i < values.length; i++) {
        idx.add(i + 1, values[i]);
      }
      final back = BitmaskIndex.deserialize(idx.serialize());
      for (int i = 0; i < values.length; i++) {
        expect(back.lookup(values[i]), [i + 1], reason: '${values[i]}');
      }
    });

    test('insertAll and close work with a SortedIndex on DateTime', () async {
      final db = FastDB.forTesting(MemoryStorageStrategy())
        ..addSortedIndex('createdAt');
      await db.open();
      final base = DateTime.utc(2024);
      await db.insertAll([
        for (int i = 0; i < 10; i++) {'createdAt': base.add(Duration(hours: i))},
      ]);
      final ids = await db
          .query()
          .where('createdAt')
          .between(base, base.add(const Duration(hours: 2)))
          .findIds();
      expect(ids, [1, 2, 3]);
      await db.close(); // persisting the index used to throw here
    });
  });

  test('deleting a document with a local DateTime clears every index',
      () async {
    final db = FastDB.forTesting(MemoryStorageStrategy())
      ..addIndex('h')
      ..addSortedIndex('s')
      ..addCompositeIndex(['h', 'k']);
    await db.open();
    addTearDown(db.close);
    final local = DateTime(2024, 1, 1); // read back from storage as UTC
    await db.insert({'h': local, 's': local, 'k': 1});
    await db.update(1, {'k': 2});
    expect(await db.query().where('h').equals(local).count(), 1);
    await db.delete(1);
    expect(await db.query().where('h').equals(local).count(), 0);
    expect(await db.query().where('s').equals(local).findIds(), isEmpty);
    expect(
        await db.query().where('h').equals(local).where('k').equals(2).findIds(),
        isEmpty);
  });

  test('auto-compaction fires exactly when the dead ratio reaches the threshold',
      () async {
    final storage = MemoryStorageStrategy();
    final db = FastDB.forTesting(storage, autoCompactThreshold: 0.3);
    await db.open();
    addTearDown(db.close);
    await db.insertAll([for (int i = 0; i < 100; i++) {'n': i, 'pad': 'x' * 64}]);
    // Interleaved inserts: the cheap estimate must not delay compaction.
    for (int i = 0; i < 20; i++) {
      await db.insert({'n': 100 + i, 'pad': 'x' * 64});
    }
    int deletes = 0;
    int? compactedAt;
    var size = await storage.size;
    for (int id = 1; id <= 80 && compactedAt == null; id++) {
      await db.delete(id);
      deletes++;
      final newSize = await storage.size;
      if (newSize < size) compactedAt = deletes;
      size = newSize;
    }
    // dead/(live+dead) with live = 120 - d and dead = d: d / 120 >= 0.3 → d = 36.
    expect(compactedAt, 36);
    expect(await db.count(), 120 - 36);
    expect((await db.findById(37))?['n'], 36);
    expect((await db.findById(120))?['n'], 119);
  });

  group('updateWhere', () {
    late FastDB db;

    setUp(() async {
      db = FastDB.forTesting(MemoryStorageStrategy());
      await db.open();
    });

    tearDown(() => db.close());

    test('condition on an unindexed field does not deadlock', () async {
      await db.insert({'v': 1});
      await db.insert({'v': 10});
      final updated = await db
          .updateWhere((q) => q.where('v').equals(10).findIds(), {'v': 11})
          .timeout(const Duration(seconds: 5));
      expect(updated, 1);
      final id = await db.insert({'after': true});
      expect((await db.findById(2))?['v'], 11);
      expect(await db.findById(id), isNotNull);
    });
  });

  group('transaction rollback', () {
    late FastDB db;

    setUp(() async {
      db = FastDB.forTesting(MemoryStorageStrategy());
      await db.open();
    });

    tearDown(() => db.close());

    test('rolled-back deletes do not leave live pages in the free list',
        () async {
      final base = await db.insertAll(List.generate(2000, (i) => {'n': i}));
      await expectLater(
        db.transaction(() async {
          // Deletes merge leaves and free their pages — pages of the tree
          // that the rollback makes live again.
          for (int id = 1; id <= 1600; id++) {
            await db.delete(id);
          }
          throw StateError('abort');
        }),
        throwsStateError,
      );
      expect(await db.count(), 2000);

      // New page allocations must not reuse the restored tree's pages.
      for (int i = 0; i < 2000; i++) {
        await db.insert({'n': 'after$i'});
      }
      for (final id in base) {
        expect((await db.findById(id))?['n'], id - 1, reason: 'id $id');
      }
      expect(await db.count(), 4000);
    });
  });
}
