import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';
import 'package:test/test.dart';

void main() {
  group('Data Duplication Regressions', () {
    late FastDB db;

    setUp(() async {
      db = FastDB(MemoryStorageStrategy());
      db.addIndex('name');
      db.addSortedIndex('age');
      await db.open();
    });

    tearDown(() => db.close());

    test('put() does not duplicate entries in HashIndex', () async {
      // 1. Initial insert
      await db.put(1, {'name': 'Alice'});
      
      // 2. Overwrite with same value
      await db.put(1, {'name': 'Alice'});
      
      // 3. Query
      final ids = await db.query().where('name').equals('Alice').findIds();
      expect(ids, [1], reason: 'HashIndex should not have duplicate IDs after put()');
      
      // 4. Overwrite with different value
      await db.put(1, {'name': 'Bob'});
      
      final aliceIds = await db.query().where('name').equals('Alice').findIds();
      expect(aliceIds, [], reason: 'Old value should be removed from HashIndex');
      
      final bobIds = await db.query().where('name').equals('Bob').findIds();
      expect(bobIds, [1], reason: 'New value should be indexed once');
    });

    test('put() does not duplicate entries in SortedIndex', () async {
      // 1. Initial insert
      await db.put(1, {'age': 30});
      
      // 2. Overwrite
      await db.put(1, {'age': 30});
      
      // 3. Query
      final ids = await db.query().where('age').equals(30).findIds();
      expect(ids, [1], reason: 'SortedIndex should not have duplicate IDs after put()');
      
      // 4. Update to different value
      await db.put(1, {'age': 31});
      expect(await db.query().where('age').equals(30).findIds(), [], reason: 'Old age should be removed');
      expect(await db.query().where('age').equals(31).findIds(), [1], reason: 'New age should be indexed once');
    });
  });
}
