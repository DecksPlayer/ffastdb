import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

/// Index edge cases that are silent-corruption prone:
/// - composite keys containing null / missing fields
/// - sorted indexes under massive value duplication
void main() {
  late FastDB db;

  tearDown(() => db.close());

  group('CompositeIndex with null/missing fields', () {
    setUp(() async {
      db = FastDB.forTesting(MemoryStorageStrategy());
      await db.open();
      db.addCompositeIndex(['city', 'status']);

      await db.insert({'city': 'London', 'status': 'active'});
      await db.insert({'city': null, 'status': 'active'});
      await db.insert({'status': 'active'}); // missing city entirely
      await db.insert({'city': 'London', 'status': 'inactive'});
    });

    test('composite query matches only exact docs', () async {
      final res = await db
          .query()
          .where('city')
          .equals('London')
          .where('status')
          .equals('active')
          .find();
      expect(res.length, 1);
      expect(res.first['city'], 'London');
      expect(res.first['status'], 'active');
    });

    test('docs with null/missing key fields do not break or poison the index',
        () async {
      // Full set still reachable via single-field query.
      final active =
          await db.query().where('status').equals('active').find();
      expect(active.length, 3);

      // A composite query for a null-ish city must not return the
      // null/missing-city docs under a wrong key.
      final paris = await db
          .query()
          .where('city')
          .equals('Paris')
          .where('status')
          .equals('active')
          .find();
      expect(paris, isEmpty);
    });

    test('total count unaffected by null keys', () async {
      expect(await db.count(), 4);
      expect((await db.getAll()).length, 4);
    });
  });

  group('SortedIndex with massive duplicate values', () {
    setUp(() async {
      db = FastDB.forTesting(MemoryStorageStrategy());
      await db.open();
      db.addSortedIndex('age');

      // 2000 docs with the SAME value + 100 spread values.
      await db.insertAll([
        for (var i = 0; i < 2000; i++) {'age': 30, 'tag': 'dup'},
        for (var i = 0; i < 100; i++) {'age': i, 'tag': 'spread'},
      ]);
    });

    test('equals on duplicated value returns all of them', () async {
      // 2000 dups + the spread doc with age == 30.
      final res = await db.query().where('age').equals(30).find();
      expect(res.length, 2001);
    });

    test('range covering the duplicated value returns all of them', () async {
      // 2000 dups + spread docs with ages 29, 30, 31.
      final res = await db.query().where('age').between(29, 31).find();
      expect(res.length, 2003);
    });

    test('range excluding the duplicated value returns only spread docs',
        () async {
      final res = await db.query().where('age').between(0, 29).find();
      expect(res.length, 30); // ages 0..29
    });

    test('sortBy over duplicates stays correct at boundaries', () async {
      final res = await db
          .query()
          .where('age')
          .between(0, 100)
          .sortBy('age')
          .limit(50)
          .find();
      expect(res.length, 50);
      for (var i = 1; i < res.length; i++) {
        expect((res[i]['age'] as num) >= (res[i - 1]['age'] as num), isTrue,
            reason: 'sort order broken at position $i');
      }
    });
  });
}
