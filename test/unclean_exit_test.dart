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
