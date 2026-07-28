@TestOn('vm')
library;

import 'dart:io';

import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

/// LRU page-cache pressure tests with a deliberately tiny cache.
///
/// With `cacheCapacity: 4` pages and a dataset of hundreds of pages, every
/// read evicts something. This catches stale-page bugs: an evicted page that
/// is reloaded must reflect the latest committed data, and an evicted DIRTY
/// page must have been written through — never silently dropped.
void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ffastdb_eviction_');
    path = '${dir.path}/cache.fdb';
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  FastDB openDb() => FastDB(
        WalStorageStrategy(
          main: IoStorageStrategy(path),
          wal: IoStorageStrategy('$path.wal'),
        ),
        cacheCapacity: 4, // pages — forces constant eviction
      );

  test('reads after eviction return current data, not stale pages', () async {
    var db = openDb();
    await db.open();

    // ~300 KB of docs — far exceeds 4 cache pages (16 KB).
    await db.insertAll(
      List.generate(300, (i) => {'n': i, 'v': 0, 'pad': 'x' * 1024}),
    );

    // Update every doc — each update dirties pages that will be evicted.
    for (var i = 0; i < 300; i++) {
      await db.update(i + 1, {'v': i * 2});
    }

    // Read everything back through the tiny cache.
    final all = await db.getAll();
    expect(all.length, 300);
    for (final doc in all) {
      final n = doc['n'] as int;
      expect(doc['v'], n * 2,
          reason: 'stale or lost update for doc n=$n after eviction');
    }
    await db.close();

    // Reopen: dirty evicted pages must have reached disk.
    db = openDb();
    await db.open();
    final persisted = await db.getAll();
    expect(persisted.length, 300);
    for (final doc in persisted) {
      final n = doc['n'] as int;
      expect(doc['v'], n * 2,
          reason: 'dirty page n=$n was evicted without reaching disk');
    }
    await db.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
