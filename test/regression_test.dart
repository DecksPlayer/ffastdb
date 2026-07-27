import 'dart:async';
import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

void main() {
  group('Regression and API Enhancements Tests', () {
    late FastDB db;

    setUp(() async {
      db = FastDB.forTesting(MemoryStorageStrategy());
      await db.open();
    });

    tearDown(() async {
      await db.close();
    });

    test('deleteImpl and mutaciones notifican watchers correctamente (BUG-1 & BUG-3)', () async {
      db.addIndex('status');
      await db.insert({'status': 'active', 'name': 'Item 1'});
      
      final events = <List<int>>[];
      final subscription = db.watch('status').listen(events.add);
      await Future.delayed(Duration.zero); // yield for initial event
      
      await db.delete(1);
      await Future.delayed(Duration.zero); // yield for delete event

      expect(events.length, 2); // initial + delete
      expect(events.first, equals([1]));
      expect(events.last, isEmpty);
      
      await subscription.cancel();
    });

    test('isNull retorna documentos sin el campo (BUG-2)', () async {
      db.addIndex('email');
      await db.insert({'name': 'Alice', 'email': 'alice@test.com'});
      await db.insert({'name': 'Bob'}); // sin email
      await db.insert({'name': 'Charlie'}); // sin email
      
      final results = await db.query().where('email').isNull().find();
      expect(results.length, 2);
      final names = results.map((d) => d['name']).toList();
      expect(names, containsAll(['Bob', 'Charlie']));
    });

    test('FTS retainAll correcto con AND multi-token (BUG-4)', () async {
      db.addFtsIndex('text');
      await db.insert({'text': 'hello world foo'});
      await db.insert({'text': 'hello bar'});
      await db.insert({'text': 'world baz'});
      
      final results = await db.query().where('text').fts('hello world').find();
      expect(results.length, 1);
      expect(results.first['text'], 'hello world foo');
    });

    test('Nested fields indexing and query dot-notation (API-6)', () async {
      db.addIndex('user.city');
      db.addSortedIndex('user.age');
      
      await db.insert({
        'user': {'city': 'Buenos Aires', 'age': 30}
      });
      await db.insert({
        'user': {'city': 'London', 'age': 25}
      });

      final results1 = await db.query().where('user.city').equals('Buenos Aires').find();
      expect(results1.length, 1);
      expect(results1.first['user']['city'], 'Buenos Aires');

      final results2 = await db.query().where('user.age').lessThan(28).find();
      expect(results2.length, 1);
      expect(results2.first['user']['city'], 'London');
    });

    test('upsert y upsertWhere (API-1)', () async {
      // Test upsert insert
      final id1 = await db.upsert(10, {'name': 'Alice', 'role': 'admin'});
      expect(id1, 10);
      final doc1 = await db.findById(10);
      expect(doc1['name'], 'Alice');

      // Test upsert update
      final id2 = await db.upsert(10, {'role': 'superadmin'});
      expect(id2, 10);
      final doc2 = await db.findById(10);
      expect(doc2['name'], 'Alice'); // preserved
      expect(doc2['role'], 'superadmin'); // updated

      // Test upsertWhere insert
      db.addIndex('email');
      final id3 = await db.upsertWhere('email', 'bob@test.com', {'name': 'Bob'});
      expect(id3, 11);
      final doc3 = await db.findById(11);
      expect(doc3['name'], 'Bob');
      expect(doc3['email'], 'bob@test.com');

      // Test upsertWhere update
      final id4 = await db.upsertWhere('email', 'bob@test.com', {'role': 'user'});
      expect(id4, 11);
      final doc4 = await db.findById(11);
      expect(doc4['name'], 'Bob');
      expect(doc4['role'], 'user');
    });

    test('findByIds y findByIdsCast (API-2)', () async {
      await db.insert({'name': 'Item A'});
      await db.insert({'name': 'Item B'});
      await db.insert({'name': 'Item C'});

      final docs = await db.findByIds([1, 3, 5]); // 5 doesn't exist
      expect(docs.length, 2);
      expect(docs[0]['name'], 'Item A');
      expect(docs[1]['name'], 'Item C');

      final casted = await db.findByIdsCast<Map<String, dynamic>>([2]);
      expect(casted.length, 1);
      expect(casted[0]['name'], 'Item B');
    });

    test('Nested transactions join transaction outer (API-7)', () async {
      await db.transaction(() async {
        await db.insert({'name': 'Item 1'});
        
        // This would throw StateError before the fix
        await db.transaction(() async {
          await db.insert({'name': 'Item 2'});
        });
      });

      final all = await db.getAll();
      expect(all.length, 2);
    });

    test('watchDocs y QueryBuilder.watch() streams (API-3 & API-4)', () async {
      db.addIndex('status');
      
      final docsEvents = <List<dynamic>>[];
      final qEvents = <List<dynamic>>[];

      final sub1 = db.watchDocs('status').listen(docsEvents.add);
      final sub2 = db.query().where('status').equals('pending').watch().listen(qEvents.add);

      await Future.delayed(Duration.zero); // Yield for initial emissions
      
      await db.insert({'status': 'pending', 'name': 'Task 1'});
      await Future.delayed(Duration.zero);

      await db.insert({'status': 'completed', 'name': 'Task 2'});
      await Future.delayed(Duration.zero);

      // docsEvents should receive: 
      // 1. Initial (empty)
      // 2. After insert of Task 1
      // 3. After insert of Task 2
      expect(docsEvents.length, 3);
      
      // qEvents should receive:
      // 1. Initial (empty)
      // 2. After insert of Task 1 (has Task 1)
      // 3. After insert of Task 2 (still only has Task 1)
      expect(qEvents.length, 3);
      expect(qEvents[1].length, 1);
      expect(qEvents[1].first['name'], 'Task 1');
      expect(qEvents[2].length, 1);
      expect(qEvents[2].first['name'], 'Task 1');

      await sub1.cancel();
      await sub2.cancel();
    });

    test('Aggregations index valueOf fast path (PERF-2)', () async {
      db.addIndex('category');
      db.addSortedIndex('score');

      await db.insert({'category': 'A', 'score': 10});
      await db.insert({'category': 'A', 'score': 20});
      await db.insert({'category': 'B', 'score': 30});
      await db.insert({'category': 'B', 'score': 40});

      // sumWhere
      final sumA = await db.sumWhere((q) => q.where('category').equals('A').findIds(), 'score');
      expect(sumA, 30);

      // avgWhere
      final avgB = await db.avgWhere((q) => q.where('category').equals('B').findIds(), 'score');
      expect(avgB, 35);

      // minWhere & maxWhere
      final minA = await db.minWhere((q) => q.where('category').equals('A').findIds(), 'score');
      expect(minA, 10);
      final maxB = await db.maxWhere((q) => q.where('category').equals('B').findIds(), 'score');
      expect(maxB, 40);
    });
  });
}
