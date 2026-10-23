import 'dart:io';
import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

void main() {
  group('FTS Persistence', () {
    const dbPath = 'test_fts_persist';
    // A fresh temp dir per test — NOT the working directory: the repo lives
    // in a synced folder (OneDrive) whose client briefly locks newly created
    // files, which made the old cwd-based cleanup fail intermittently.
    late Directory dir;

    setUp(() async {
      await FfastDb.disposeInstance();
      dir = Directory.systemTemp.createTempSync('ffastdb_persist_');
    });

    tearDown(() async {
      await FfastDb.disposeInstance();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('FTS index survives restart', () async {
      // 1. Open and populate
      {
        final db = await openDatabase(dbPath, directory: dir.path, ftsIndexes: ['content']);
        await db.insert({'content': 'The quick brown fox'});
        await db.insert({'content': 'Jumps over the lazy dog'});
        
        final results = await db.query().where('content').fts('quick').findIds();
        expect(results.length, 1);
        
        await db.close();
      }

      // 2. Reopen and query
      {
        // Registering it in openDatabase allows loadIndexes to populate it
        final db = await openDatabase(dbPath, directory: dir.path, ftsIndexes: ['content']);
        
        final results = await db.query().where('content').fts('lazy').findIds();
        expect(results.length, 1, reason: 'FTS data should have been loaded from disk');
        
        await db.close();
      }
    });

    test('Composite index survives restart', () async {
      {
        final db = await openDatabase(dbPath, directory: dir.path, compositeIndexes: [['city', 'status']]);
        await db.insert({'city': 'London', 'status': 'active'});
        
        final results = await db.query()
            .where('city').equals('London')
            .where('status').equals('active')
            .findIds();
        expect(results.length, 1);
        await db.close();
      }

      {
        final db = await openDatabase(dbPath, directory: dir.path, compositeIndexes: [['city', 'status']]);
        
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
