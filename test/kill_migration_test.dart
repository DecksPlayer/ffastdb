@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

import 'helpers/write_worker.dart' show counterMigration;

/// Kill-during-schema-migration test.
///
/// Scenario: 10.000 real users update the app; the new version opens their
/// v1 database with `version: 2` and starts migrating documents. The OS
/// kills the app mid-migration. What must NOT happen: already-migrated docs
/// getting the migration applied TWICE on the next open (the header is only
/// saved after migrations complete, so a naive implementation re-runs the
/// full migration and corrupts non-idempotent changes).
///
/// The migration used here is deliberately non-idempotent (`counter++`):
/// if it runs twice on any doc, `counter == 2` and the test fails.
void main() {
  final runs =
      int.tryParse(Platform.environment['FFASTDB_KILL_MODE_RUNS'] ?? '') ?? 15;

  final workerSource = File('test/helpers/write_worker.dart').absolute.path;
  late Directory compileDir;
  String? workerExe;

  setUpAll(() async {
    compileDir = Directory.systemTemp.createTempSync('ffastdb_km_worker_');
    final exePath =
        '${compileDir.path}/write_worker${Platform.isWindows ? '.exe' : ''}';
    try {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['compile', 'exe', workerSource, '-o', exePath],
      ).timeout(const Duration(minutes: 3));
      if (result.exitCode == 0 && File(exePath).existsSync()) {
        workerExe = exePath;
      }
    } on TimeoutException {}
  });

  tearDownAll(() {
    if (workerExe != null) {
      try {
        compileDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Future<Process> spawnWorker(String directory, String name) {
    final args = [directory, name, 'migrate'];
    if (workerExe != null) return Process.start(workerExe!, args);
    return Process.start(Platform.resolvedExecutable,
        [workerSource, ...args],
        workingDirectory: Directory.current.path);
  }

  test('kill mid-schema-migration never applies a migration twice ($runs runs)',
      () async {
    final rand = Random();

    for (var run = 0; run < runs; run++) {
      final dir = Directory.systemTemp.createTempSync('ffastdb_km_');
      Process? proc;
      try {
        // 1. Create a v1 database (current code), close cleanly.
        var db = await openDatabase(
          'migtest',
          directory: dir.path,
          version: 1,
          indexes: ['status'],
          sortedIndexes: ['n'],
        );
        await db.insertAll(List.generate(
            2000,
            (i) => {
                  'n': i,
                  'status': i.isEven ? 'even' : 'odd',
                  'counter': 0,
                }));
        await db.close();

        // 2. Worker reopens with version: 2 — READY fires from INSIDE the
        //    migration, then we SIGKILL at a random point mid-migration.
        proc = await spawnWorker(dir.path, 'migtest');
        proc.stderr.drain();
        final ready = Completer<void>();
        proc.stdout.transform(utf8.decoder).listen((chunk) {
          if (chunk.contains('READY') && !ready.isCompleted) ready.complete();
        });
        await ready.future.timeout(
          const Duration(seconds: 60),
          onTimeout: () => fail('worker did not start migrating (run $run)'),
        );
        await Future.delayed(Duration(milliseconds: rand.nextInt(200)));
        proc.kill(ProcessSignal.sigkill);
        await proc.exitCode.timeout(const Duration(seconds: 10));
        proc = null;

        // 3. Reopen with version: 2 + the same migration — it must complete
        //    exactly once per doc, however many times the process was killed.
        db = await openDatabase(
          'migtest',
          directory: dir.path,
          version: 2,
          indexes: ['status'],
          sortedIndexes: ['n'],
          migrations: {1: counterMigration},
        );

        final all = await db.getAll();
        expect(all.length, 2000);
        for (final doc in all) {
          expect(doc['counter'], 1,
              reason:
                  'doc n=${doc['n']} has counter=${doc['counter']} — migration '
                  'applied more than once or lost (run $run)');
        }
        await db.close();
      } finally {
        try {
          proc?.kill(ProcessSignal.sigkill);
          await proc?.exitCode.timeout(const Duration(seconds: 5));
        } catch (_) {}
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
