import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';
import 'package:test/test.dart';

void main() {
  group('Chunked InsertAll', () {
    late FastDB db;

    setUp(() async {
      db = FastDB(MemoryStorageStrategy());
      db.addIndex('val');
      await db.open();
    });

    tearDown(() => db.close());

    test('insertAll processes > 5000 records correctly', () async {
      final docs = List.generate(6000, (i) => {'val': i, 'desc': 'Doc $i'});
      
      final ids = await db.insertAll(docs);
      expect(ids.length, 6000);
      expect(await db.count(), 6000); 

      final doc1 = await db.findById(1);
      expect(doc1!['val'], 0);
      
      final doc100 = await db.findById(100);
      expect(doc100!['val'], 99);

      final doc5500 = await db.findById(5500);
      expect(doc5500!['val'], 5499);
      
      final doc6000 = await db.findById(6000);
      expect(doc6000!['val'], 5999);

      // Verify index
      final found = await db.query().where('val').equals(5999).findIds();
      expect(found, [6000]);
    });

    test('insertAll handles empty list', () async {
      final ids = await db.insertAll([]);
      expect(ids, isEmpty);
    });
  });
}
