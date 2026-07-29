@TestOn('vm')
library;

import 'dart:io';

import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

/// Write-side concurrency tests against REAL native storage.
///
/// A sibling bug on the read side (concurrent `setPosition`/`read` on one
/// RandomAccessFile) was caught by `kill_recovery_test.dart` and fixed by
/// serializing handle ops in `IoStorageStrategy`. These tests confirm the
/// write side behaves correctly under real parallelism too — the in-memory
/// suite cannot exercise these paths.
void main() {
  late Directory dir;
  late String path;

  FastDB openDb() => FastDB(
        WalStorageStrategy(
          main: IoStorageStrategy(path),
          wal: IoStorageStrategy('$path.wal'),
        ),
      );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ffastdb_concurrent_');
    path = '${dir.path}/conc.fdb';
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('concurrent insertAll batches lose/overwrite nothing', () async {
    final db = openDb();
    await db.open();

    // 4 batches of 250 docs fired in parallel, with disjoint `n` ranges.
    await Future.wait([
      for (var b = 0; b < 4; b++)
        db.insertAll(List.generate(250, (i) => {'n': b * 1000 + i})),
    ]);

    final all = await db.getAll();
    expect(all.length, 1000);
    expect(all.map((d) => d['n'] as int).toSet().length, 1000,
        reason: 'concurrent batches overwrote or duplicated docs');
    expect(await db.count(), 1000);

    await db.close();
  });

  test('concurrent updates on the same id stay consistent', () async {
    final db = openDb();
    await db.open();

    final id = await db.insert({'v': -1});

    // 50 concurrent writers on the SAME document.
    await Future.wait([
      for (var k = 0; k < 50; k++) db.update(id, {'v': k}),
    ]);

    // Whatever won the race, the stored value must be one of the written
    // values — never a torn/corrupt merge of two writes.
    final doc = await db.findById(id);
    expect(doc!['v'], isIn(List.generate(50, (k) => k)),
        reason: 'concurrent updates produced a corrupt value: ${doc['v']}');

    // And a final solo update must stick deterministically.
    await db.update(id, {'v': 999});
    expect((await db.findById(id))!['v'], 999);

    await db.close();
  });

  test('concurrent readers and writers complete without errors', () async {
    final db = openDb();
    await db.open();
    db.addIndex('status');

    var writesDone = 0;
    final writers = [
      for (var w = 0; w < 3; w++)
        () async {
          for (var i = 0; i < 100; i++) {
            await db.insert({'w': w, 'status': 'active'});
            writesDone++;
          }
        }(),
    ];
    final readers = [
      for (var r = 0; r < 5; r++)
        () async {
          for (var i = 0; i < 20; i++) {
            // Must never throw mid-write — reads see a consistent snapshot.
            await db.getAll();
            await db.query().where('status').equals('active').count();
          }
        }(),
    ];

    await Future.wait([...writers, ...readers]);

    expect(writesDone, 300);
    expect(await db.count(), 300);
    expect((await db.getAll()).length, 300);

    await db.close();
  });

  test('parallel transactions on the same doc are isolated', () async {
    final db = openDb();
    await db.open();

    final id = await db.insert({'v': 0});

    // Two transactions fired in parallel, each doing read-modify-write
    // cycles on the SAME document. If they interleaved, updates would be
    // lost (both read v, both write v+1).
    Future<void> bump(int times) => db.transaction(() async {
          for (var i = 0; i < times; i++) {
            final d = await db.findById(id);
            await db.update(id, {'v': d['v'] + 1});
          }
        });

    await Future.wait([bump(25), bump(25)]);

    expect((await db.findById(id))['v'], 50,
        reason: 'lost update — parallel transactions interleaved');

    await db.close();
  });

  test('one parallel transaction rolling back does not undo the other',
      () async {
    final db = openDb();
    await db.open();

    final id = await db.insert({'v': 0});

    final failing = db.transaction(() async {
      for (var i = 0; i < 10; i++) {
        final d = await db.findById(id);
        await db.update(id, {'v': d['v'] + 1});
      }
      throw StateError('boom — roll me back');
    });
    final succeeding = db.transaction(() async {
      for (var i = 0; i < 10; i++) {
        final d = await db.findById(id);
        await db.update(id, {'v': d['v'] + 1});
      }
    });

    await expectLater(failing, throwsStateError);
    await succeeding;

    // The rolled-back tx contributed nothing; the committed one added 10.
    expect((await db.findById(id))['v'], 10,
        reason: 'rollback of one tx clobbered the other');

    await db.close();
  });
}
