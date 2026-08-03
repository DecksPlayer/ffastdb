import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

void main() {
  group('FTS Integration Tests', () {
    late FastDB db;

    setUp(() async {
      db = FastDB(MemoryStorageStrategy());
      await db.open();
    });

    tearDown(() async {
      await db.close();
    });

    test('Basic FTS indexing and search', () async {
      await db.insert({'id': 1, 'text': 'Hello world from London'});
      await db.insert({'id': 2, 'text': 'Paris is beautiful'});
      await db.insert({'id': 3, 'text': 'London has big ben'});

      db.addFtsIndex('text');
      await db.reindex();

      final results = await db.query().where('text').fts('london').find();

      expect(results.length, equals(2));
      expect(results.any((doc) => doc['id'] == 1), isTrue);
      expect(results.any((doc) => doc['id'] == 3), isTrue);
    });

    test('Multi-word FTS (AND semantics)', () async {
      await db.insert({'id': 1, 'text': 'Hello world from London'});
      await db.insert({'id': 2, 'text': 'Paris is beautiful'});
      await db.insert({'id': 3, 'text': 'London has big ben'});

      db.addFtsIndex('text');
      await db.reindex();

      final results = await db.query().where('text').fts('london big').find();

      expect(results.length, equals(1));
      expect(results[0]['id'], equals(3));
    });

    test('Case-insensitive search', () async {
      await db.insert({'id': 1, 'text': 'Hello world from London'});
      await db.insert({'id': 2, 'text': 'Paris is beautiful'});
      await db.insert({'id': 3, 'text': 'London has big ben'});

      db.addFtsIndex('text');
      await db.reindex();

      final results = await db.query().where('text').fts('LONDON').find();

      expect(results.length, equals(2));
    });

    test('Token indexing and search', () async {
      await db.insert({'id': 1, 'text': 'I am here'});
      await db.insert({'id': 2, 'text': 'You are there'});

      db.addFtsIndex('text');
      await db.reindex();

      final results = await db.query().where('text').fts('am').find();

      expect(results.length, equals(1));
      expect(results[0]['id'], equals(1));
    });

    test('Empty/whitespace FTS query', () async {
      await db.insert({'id': 1, 'text': 'Some text'});

      db.addFtsIndex('text');
      await db.reindex();

      final results = await db.query().where('text').fts('').find();

      expect(results, isEmpty);
    });

    test('No matching documents', () async {
      await db.insert({'id': 1, 'text': 'Apple pie'});
      await db.insert({'id': 2, 'text': 'Banana split'});

      db.addFtsIndex('text');
      await db.reindex();

      final results = await db.query().where('text').fts('nonexistent').find();

      expect(results, isEmpty);
    });
  });
}
