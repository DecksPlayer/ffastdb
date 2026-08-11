@TestOn('browser')
library;

import 'package:test/test.dart';
import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/web/indexed_db_strategy.dart';

void main() {
  test('IndexedDb: insert -> clear -> insert -> reopen (same session)', () async {
    final storage = IndexedDbStorageStrategy('clear_web_test_db_1');
    var db = FastDB.forTesting(storage);
    await db.open();
    db.addIndex('type');

    await db.insertAll([
      {'type': 'user', 'name': 'A'},
      {'type': 'post', 'title': 'B'},
    ]);
    final id1 = await db.insert({'type': 'user', 'name': 'C'});
    print('inserted id=$id1, count=${await db.count()}');
    expect(await db.count(), 3);

    await db.clear();
    print('count after clear: ${await db.count()}');
    expect(await db.count(), 0);
    expect(await db.getAll(), isEmpty);
    expect(await db.findById(1), isNull);

    final newId = await db.insert({'type': 'user', 'name': 'D'});
    print('new id after clear: $newId, count=${await db.count()}');
    expect(newId, 1, reason: 'IDs should restart from 1 after clear()');
    expect(await db.count(), 1);
    final doc = await db.findById(newId);
    print('doc after clear+insert: $doc');
    expect(doc, isNotNull);
    expect(doc!['name'], 'D');

    await db.close();
  });

  test('IndexedDb: insert -> clear -> CLOSE -> reopen (persistence across sessions)', () async {
    final dbName = 'clear_web_test_db_2';
    {
      final storage = IndexedDbStorageStrategy(dbName);
      final db = FastDB.forTesting(storage);
      await db.open();
      await db.insertAll([
        {'type': 'user', 'name': 'A'},
        {'type': 'post', 'title': 'B'},
        {'type': 'user', 'name': 'C'},
      ]);
      expect(await db.count(), 3);
      await db.clear();
      expect(await db.count(), 0);
      await db.close();
    }

    // Reopen a fresh FastDB instance against the same IndexedDB database name,
    // simulating a page reload after clear().
    {
      final storage2 = IndexedDbStorageStrategy(dbName);
      final db2 = FastDB.forTesting(storage2);
      await db2.open();
      final count = await db2.count();
      final all = await db2.getAll();
      print('after reopen: count=$count all=$all');
      expect(count, 0, reason: 'clear() must persist across a close+reopen cycle');
      expect(all, isEmpty);

      final newId = await db2.insert({'type': 'user', 'name': 'E'});
      expect(newId, 1);
      expect(await db2.count(), 1);
      await db2.close();
    }
  });

  test('IndexedDb: clear() with large dataset removes orphan chunks', () async {
    final dbName = 'clear_web_test_db_3';
    final storage = IndexedDbStorageStrategy(dbName);
    final db = FastDB.forTesting(storage);
    await db.open();

    // Insert enough data to span multiple 64KB chunks.
    final docs = List.generate(500, (i) => {
      'type': 'item',
      'payload': 'x' * 500,
      'i': i,
    });
    await db.insertAll(docs);
    expect(await db.count(), 500);

    await db.clear();
    expect(await db.count(), 0);
    await db.close();

    // Reopen and verify no stale data resurfaces and no leftover chunk data
    // causes issues on next writes.
    final storage2 = IndexedDbStorageStrategy(dbName);
    final db2 = FastDB.forTesting(storage2);
    await db2.open();
    expect(await db2.count(), 0);
    expect(await db2.getAll(), isEmpty);

    final newDocs = List.generate(10, (i) => {'type': 'item', 'i': i});
    final ids = await db2.insertAll(newDocs);
    expect(ids.length, 10);
    expect(await db2.count(), 10);
    final all = await db2.getAll();
    print('after clear+reopen+reinsert: ${all.length} docs, ids=$ids');
    await db2.close();
  });
}
