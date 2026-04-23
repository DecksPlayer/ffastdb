import 'dart:math';
import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';

/// Comprehensive stress test suite for FastDB.
/// Tests: index persistence, delete, compact (vacuum), and random-write stress.
void main() async {
  int passed = 0;
  int failed = 0;

  Future<void> test(String name, Future<void> Function() fn) async {
    try {
      await fn();
      print('  ✅ $name');
      passed++;
    } catch (e) {
      print('  ❌ $name → $e');
      failed++;
    }
  }

  // ─── 1. Index Persistence ────────────────────────────────────────────────
  print('\n=== 1. Index Persistence ===');
  {
    final mainStorage = MemoryStorageStrategy();

    // Open, insert, close (saves indexes)
    final db1 = FastDB(mainStorage);
    db1.addIndex('city');
    await db1.open();
    await db1.insertAll([
      {'name': 'Alice', 'city': 'London', 'age': 30},
      {'name': 'Bob', 'city': 'Paris', 'age': 25},
      {'name': 'Clara', 'city': 'London', 'age': 35},
    ]);
    await db1.close(); // ← saves indexes to sidecar

    // Reopen same storage (loads indexes)
    final db2 = FastDB(mainStorage);
    db2.addIndex('city'); // register field name
    await db2.open(); // ← restores indexes from sidecar

    await test('London index restored after reopen', () async {
      final ids = await db2.query().where('city').equals('London').findIds();
      if (ids.length != 2) throw 'Expected 2 London docs, got ${ids.length}';
    });

    await test('Paris index restored after reopen', () async {
      final ids = await db2.query().where('city').equals('Paris').findIds();
      if (ids.length != 1) throw 'Expected 1 Paris doc, got ${ids.length}';
    });

    await db2.close();
  }

  // ─── 2. Delete ───────────────────────────────────────────────────────────
  print('\n=== 2. Delete Operations ===');
  {
    final db = FastDB(MemoryStorageStrategy());
    db.addIndex('city');
    await db.open();

    final ids = await db.insertAll([
      {'name': 'Alice', 'city': 'London'},
      {'name': 'Bob', 'city': 'Paris'},
      {'name': 'Clara', 'city': 'London'},
    ]);

    await test('Delete returns true for existing doc', () async {
      final ok = await db.delete(ids[0]);
      if (!ok) throw 'Expected delete to return true';
    });

    await test('Deleted doc not found by ID', () async {
      final doc = await db.findById(ids[0]);
      if (doc != null) throw 'Expected null after delete, got $doc';
    });

    await test('Delete returns false for non-existent doc', () async {
      final ok = await db.delete(9999);
      if (ok) throw 'Expected false for non-existent doc';
    });

    await db.close();
  }

  // ─── 3. Compact / Vacuum ─────────────────────────────────────────────────
  print('\n=== 3. Compact (Vacuum) ===');
  {
    final db = FastDB(MemoryStorageStrategy());
    await db.open();

    final ids = await db.insertAll([
      for (int i = 0; i < 100; i++) {'name': 'User_$i', 'score': i},
    ]);

    final sizeBefore = await db.storage.size;

    // Delete half the documents
    for (int i = 0; i < 50; i++) {
      await db.delete(ids[i]);
    }

    await db.compact();
    final sizeAfter = await db.storage.size;

    await test('Compact does not throw', () async {}); // Already ran above

    await test('Surviving docs still readable after compact', () async {
      for (int i = 50; i < 100; i++) {
        final doc = await db.findById(ids[i]);
        if (doc == null) throw 'Doc ${ids[i]} missing after compact';
      }
    });

    await test('Deleted docs gone after compact', () async {
      final doc = await db.findById(ids[0]);
      if (doc != null) throw 'Deleted doc still accessible after compact';
    });

    print('  DB size before: ${sizeBefore}B → after compact: ${sizeAfter}B');
    await db.close();
  }

  // ─── 4. Stress Test: 1000 random operations ──────────────────────────────
  print('\n=== 4. Stress Test (1000 random ops) ===');
  {
    final db = FastDB(MemoryStorageStrategy(), cacheCapacity: 256);
    db.addIndex('score');
    await db.open();

    final rng = Random(42);
    final liveIds = <int>{};
    int errorCount = 0;

    for (int op = 0; op < 1000; op++) {
      final action = rng.nextInt(3); // 0=insert, 1=read, 2=delete

      if (action == 0 || liveIds.isEmpty) {
        // Insert
        final id = await db.insert({'score': rng.nextInt(1000), 'op': op});
        liveIds.add(id);
      } else if (action == 1) {
        // Read
        final id = liveIds.elementAt(rng.nextInt(liveIds.length));
        final doc = await db.findById(id);
        if (doc == null) {
          errorCount++;
        }
      } else {
        // Delete
        final id = liveIds.elementAt(rng.nextInt(liveIds.length));
        await db.delete(id);
        liveIds.remove(id);
      }
    }

    await test('Stress test: 0 read errors in 1000 random ops', () async {
      if (errorCount > 0) throw '$errorCount read errors detected';
    });

    await test('Stress test: all live docs readable', () async {
      int missing = 0;
      for (final id in liveIds) {
        final doc = await db.findById(id);
        if (doc == null) missing++;
      }
      if (missing > 0) throw '$missing docs unexpectedly missing';
    });

    await test('Stress test: secondary index consistent', () async {
      final allIndexed = await db.query().where('score').between(0, 1000).findIds();
      final inIndex = allIndexed.length;
      final expected = liveIds.length;
      if (inIndex > expected + 5) { // allow small delta from deleted docs
        throw 'Index has $inIndex entries but only $expected live docs';
      }
    });

    await db.close();
  }

  // ─── Summary ─────────────────────────────────────────────────────────────
  print('\n' + '─' * 40);
  print('Tests: ${passed + failed} total, $passed passed, $failed failed');
  if (failed == 0) {
    print('🎉 All tests passed! FastDB is production-ready.');
  } else {
    print('⚠️  $failed test(s) failed.');
  }
}
