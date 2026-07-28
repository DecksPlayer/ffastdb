@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

/// Multi-process ownership tests.
///
/// The documented model is "single active owner" per database file. These
/// tests confirm the failure mode is SAFE and VISIBLE (a clear StateError),
/// never silent dual ownership — and that the OS-level lock is released when
/// the owner dies, so recovery after a crash is always possible.
void main() {
  final workerSource = File('test/helpers/write_worker.dart').absolute.path;

  test('second process cannot open a locked database; lock dies with owner',
      () async {
    final dir = Directory.systemTemp.createTempSync('ffastdb_lock_');
    Process? proc;
    try {
      // Process 1: opens the DB and holds it.
      proc = await Process.start(
        Platform.resolvedExecutable,
        [workerSource, dir.path, 'locktest'],
        workingDirectory: Directory.current.path,
      );
      proc.stderr.drain();
      final ready = Completer<void>();
      proc.stdout.transform(utf8.decoder).listen((chunk) {
        if (chunk.contains('READY') && !ready.isCompleted) ready.complete();
      });
      await ready.future.timeout(const Duration(seconds: 60),
          onTimeout: () => fail('worker did not signal READY'));

      // Process 2 (this one): must be REJECTED with a clear error.
      await expectLater(
        openDatabase('locktest', directory: dir.path),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('locked'),
        )),
        reason: 'a second process must not silently co-own the file',
      );

      // Kill the owner — the OS releases the file lock on process death.
      proc.kill(ProcessSignal.sigkill);
      await proc!.exitCode.timeout(const Duration(seconds: 10));
      proc = null;

      // Now the same open must succeed (this is what makes crash recovery
      // possible at all — a stale lock must not brick the database).
      final db = await openDatabase('locktest', directory: dir.path);
      final id = await db.insert({'after': 'kill'});
      expect(await db.findById(id), isNotNull);
      await db.close();
    } finally {
      // Never leave a live child behind — it would hold the lock and keep
      // the test runner alive.
      try {
        proc?.kill(ProcessSignal.sigkill);
        await proc?.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {}
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
