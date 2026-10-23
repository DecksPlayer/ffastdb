@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

/// After a process exits without close(), reopening must yield exactly the
/// committed state. The removed operation log replayed stale single-document
/// operations on top of the WAL-recovered state (transactions and batch
/// writes were never logged), resurrecting deleted documents and reverting
/// updates — and it stored documents in plaintext next to encrypted files.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('ffastdb_unclean_'));

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> runWorker(String name, [String? key]) async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'test/helpers/unclean_exit_worker.dart',
      dir.path,
      name,
      ?key,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  }

  test('reopen after unclean exit keeps transactional and batch writes',
      () async {
    await runWorker('replay');

    final db = await openDatabase('replay', directory: dir.path);
    addTearDown(db.close);
    expect(await db.findById(1), isNull,
        reason: 'doc removed by deleteWhere was resurrected');
    expect(await db.findById(2), isNull);
    expect((await db.findById(3))?['v'], 11,
        reason: 'updateWhere result was reverted');
    expect(await db.count(), 41);
  });

  group('index persistence across unclean exits', () {
    /// Seeds a cleanly closed database, runs the worker in [mode], reopens
    /// and reports whether open() had to rebuild the indexes.
    Future<({bool rebuilt, FastDB db})> scenario(String mode) async {
      final seed = await openDatabase('flag', directory: dir.path, indexes: ['status']);
      await seed.insertAll([for (int i = 0; i < 20; i++) {'status': 'a'}]);
      await seed.close();

      final result = await Process.run(Platform.resolvedExecutable,
          ['test/helpers/clean_flag_worker.dart', dir.path, 'flag', mode]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

      var rebuilt = false;
      final db = await openDatabase('flag',
          directory: dir.path,
          indexes: ['status'],
          onProgress: (_) => rebuilt = true);
      addTearDown(db.close);
      return (rebuilt: rebuilt, db: db);
    }

    test('a read-only session that is killed needs no rebuild', () async {
      final r = await scenario('read');
      expect(r.rebuilt, isFalse);
      expect(await r.db.query().where('status').equals('a').count(), 20);
    });

    test('writes followed by flush() need no rebuild', () async {
      final r = await scenario('write-flush');
      expect(r.rebuilt, isFalse);
      expect(await r.db.query().where('status').equals('new').count(), 1);
    });

    test('unflushed writes force a (correct) rebuild', () async {
      final r = await scenario('write');
      expect(r.rebuilt, isTrue);
      expect(await r.db.query().where('status').equals('new').count(), 1);
      expect(await r.db.count(), 21);
    });
  });

  test('encrypted database leaves no plaintext on disk', () async {
    // A leftover log from ffastdb <= 0.3.5 must be deleted on open.
    File('${dir.path}/enc.fdb.log').writeAsStringSync('SECRET-PAYLOAD');
    await runWorker('enc', 'k3y');

    final db =
        await openDatabase('enc', directory: dir.path, encryptionKey: 'k3y');
    expect(await db.count(), 41);
    await db.close();

    expect(File('${dir.path}/enc.fdb.log').existsSync(), isFalse);
    for (final f in dir.listSync().whereType<File>()) {
      expect(latin1.decode(f.readAsBytesSync()).contains('SECRET-PAYLOAD'),
          isFalse,
          reason: 'plaintext found in ${f.path}');
    }
  });
}
