import 'dart:io';
import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';
import 'package:ffastdb/src/storage/wal_storage_strategy.dart';
import 'package:ffastdb/src/storage/io/io_storage_strategy.dart';
import 'package:glados/glados.dart';

// Custom glados generators for property-based testing of FastDB

extension JsonValueGenerator on Any {
  Generator<dynamic> get jsonValue => any.either(
        any.int,
        any.either(
          any.double,
          any.either(
            any.bool,
            any.either(any.letters, any.nullValue),
          ),
        ),
      );

  Generator<Map<String, dynamic>> get document {
    // Generate maps with string keys and random json values
    return any.map(any.letters, any.jsonValue).map((map) {
      // FastDB uses string keys. Ensure they are not empty just in case.
      final newMap = <String, dynamic>{};
      for (var entry in map.entries) {
        final key = entry.key.isEmpty ? 'empty_key' : entry.key;
        newMap[key] = entry.value;
      }
      return newMap;
    });
  }
}

extension NullGenerator on Any {
  Generator<Null> get nullValue => (random, size) => Shrinkable(null, () => []);
}

void main() {
  Any.setDefault<Map<String, dynamic>>(any.document);
  Any.setDefault<List<Map<String, dynamic>>>(any.list(any.document));
  Any.setDefault<String>(any.letters);

  group('FastDB Core Properties', () {
    Glados<Map<String, dynamic>>().test('Insert and findById should return identical document', (doc) async {
      final db = FastDB(MemoryStorageStrategy());
      await db.open();

      try {
        final id = await db.insert(doc);
        final retrieved = await db.findById(id);

        expect(retrieved, isNotNull);
        
        for (final key in doc.keys) {
          // Double NaN == NaN is false in Dart, handle this if Glados generates NaNs
          if (doc[key] is double && (doc[key] as double).isNaN) {
            expect((retrieved![key] as double).isNaN, isTrue);
          } else {
            expect(retrieved![key], doc[key]);
          }
        }
      } finally {
        await db.close();
      }
    });

    Glados2<Map<String, dynamic>, Map<String, dynamic>>().test('Update modifies document correctly', (doc1, updateDoc) async {
      final db = FastDB(MemoryStorageStrategy());
      await db.open();

      try {
        final id = await db.insert(doc1);
        final success = await db.update(id, updateDoc);
        expect(success, isTrue);

        final retrieved = await db.findById(id);
        expect(retrieved, isNotNull);

        // All keys from updateDoc should be present and updated in retrieved
        for (final key in updateDoc.keys) {
           if (updateDoc[key] is double && (updateDoc[key] as double).isNaN) {
             expect((retrieved![key] as double).isNaN, isTrue);
           } else {
             expect(retrieved![key], updateDoc[key]);
           }
        }

        // Keys from doc1 that are NOT in updateDoc should still be present
        for (final key in doc1.keys) {
          if (!updateDoc.containsKey(key)) {
            if (doc1[key] is double && (doc1[key] as double).isNaN) {
              expect((retrieved![key] as double).isNaN, isTrue);
            } else {
              expect(retrieved![key], doc1[key]);
            }
          }
        }
      } finally {
        await db.close();
      }
    });

    Glados<Map<String, dynamic>>().test('Delete removes the document completely', (doc) async {
      final db = FastDB(MemoryStorageStrategy());
      await db.open();

      try {
        final id = await db.insert(doc);
        final success = await db.delete(id);
        expect(success, isTrue);

        final retrieved = await db.findById(id);
        expect(retrieved, isNull);
      } finally {
        await db.close();
      }
    });
  });

  group('Transactions Edge Cases', () {
    Glados<List<Map<String, dynamic>>>().test('Transaction rollback leaves DB unchanged', (docs) async {
      // Deep copy to prevent mutating glados input
      final testDocs = docs.map((d) => Map<String, dynamic>.from(d)).toList();
      print('DEBUG: Testing rollback with ${testDocs.length} docs');
      
      final tempDir = await Directory.systemTemp.createTemp('fastdb_prop_test_');
      print('DEBUG: Temp Dir: ${tempDir.path}');
      final path = '${tempDir.path}/db.fdb';
      final walPath = '${tempDir.path}/db.fdb.wal';

      final db = FastDB(WalStorageStrategy(
        main: IoStorageStrategy(path),
        wal: IoStorageStrategy(walPath),
      ));
      await db.open();

      final initialIds = await db.insertAll(testDocs);
      
      try {
        await db.transaction(() async {
          if (initialIds.isNotEmpty) {
            await db.update(initialIds.first, {'rolled_back': true});
          }
          throw Exception('Rollback');
        });
      } catch (e) {
        // ignore
      }

      try {
        final newIds = await db.rangeSearch(1, 100000);
        expect(newIds.length, initialIds.length);
        
        if (initialIds.isNotEmpty) {
          final doc = await db.findById(initialIds.last);
          expect(doc, isNotNull);
          expect(doc!['rolled_back'], isNull);
        }
      } finally {
        await db.close();
        await tempDir.delete(recursive: true);
      }
    });
  });

  group('Query Invariants', () {
    Glados2<List<Map<String, dynamic>>, String>().test('HashIndex finds exact matches', (docs, searchWord) async {
      final db = FastDB(MemoryStorageStrategy());
      db.addIndex('field');
      await db.open();

      // Add the searchWord to some documents exactly
      for (var i = 0; i < docs.length; i++) {
        if (i % 2 == 0) {
          docs[i]['field'] = searchWord;
        }
      }

      await db.insertAll(docs);

      final resultIds = db.query().where('field').equals(searchWord).findIds();
      
      int actualCount = 0;
      for (final doc in docs) {
         if (doc['field'] == searchWord) actualCount++;
      }
      
      expect(resultIds.length, actualCount);

      await db.close();
    });
  });
}
