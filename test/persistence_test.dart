import 'dart:io';
import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

void main() {
  group('FTS Persistence', () {
    const dbPath = 'test_fts_persist';
    
    tearDown(() async {
      await FfastDb.disposeInstance();
      for (final ext in ['.fdb', '.fidx', '.fdb.wal', '.fdb.lock']) {
        final f = File('$dbPath$ext');
        if (f.existsSync()) f.deleteSync();
      }
    });

    setUp(() async {
      await FfastDb.disposeInstance();
      for (final ext in ['.fdb', '.fidx', '.fdb.wal', '.fdb.lock']) {
        final f = File('$dbPath$ext');
        if (f.existsSync()) f.deleteSync();
      }
    });

    test('FTS index survives restart', () async {
      // 1. Open and populate
      {
        final db = await openDatabase(dbPath, ftsIndexes: ['content']);
        await db.insert({'content': 'The quick brown fox'});
        await db.insert({'content': 'Jumps over the lazy dog'});
        
        final results = await db.query().where('content').fts('quick').findIds();
        expect(results.length, 1);
        
        await db.close();
      }

      // 2. Reopen and query
      {
        // Registering it in openDatabase allows loadIndexes to populate it
        final db = await openDatabase(dbPath, ftsIndexes: ['content']);
        
        final results = await db.query().where('content').fts('lazy').findIds();
        expect(results.length, 1, reason: 'FTS data should have been loaded from disk');
        
        await db.close();
      }
    });

    test('Composite index survives restart', () async {
      {
        final db = await openDatabase(dbPath, compositeIndexes: [['city', 'status']]);
        await db.insert({'city': 'London', 'status': 'active'});
        
        final results = await db.query()
            .where('city').equals('London')
            .where('status').equals('active')
            .findIds();
        expect(results.length, 1);
        await db.close();
      }

      {
        final db = await openDatabase(dbPath, compositeIndexes: [['city', 'status']]);
        
        final results = await db.query()
            .where('city').equals('London')
            .where('status').equals('active')
            .findIds();
        expect(results.length, 1, reason: 'Composite data should have been loaded from disk');
        await db.close();
      }
    });
  });
}
