@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

import 'helpers/write_worker.dart' show blobPayload;

/// Physical durability test: kills a real OS process with SIGKILL in the
/// middle of continuous writes, then reopens the database and verifies
/// integrity.
///
/// This complements the in-process failure tests (exceptions, spy storages):
/// those test rollback *logic*; this tests physical *durability* — what
/// happens when the whole process disappears mid-`write()` and the kernel
/// leaves a torn write on the filesystem.
///
/// Modes (worker write patterns): insert, batch (bulk insertAll), update,
/// compact (full file rewrite), reindex, blob (large Uint8List payloads),
/// and encrypted storage.
///
/// Scale up in CI / before releases:
/// `FFASTDB_KILL_RUNS=100 FFASTDB_KILL_MODE_RUNS=50 dart test test/kill_recovery_test.dart`
void main() {
  final insertRuns =
      int.tryParse(Platform.environment['FFASTDB_KILL_RUNS'] ?? '') ?? 50;
  final modeRuns =
      int.tryParse(Platform.environment['FFASTDB_KILL_MODE_RUNS'] ?? '') ?? 15;

  final workerSource = File('test/helpers/write_worker.dart').absolute.path;
  late Directory compileDir;
  String? workerExe;

  setUpAll(() async {
    // Compile the worker once — spawning `dart run` per run would recompile
    // from source every time (several seconds per spawn on Windows).
    compileDir = Directory.systemTemp.createTempSync('ffastdb_kill_worker_');
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
    } on TimeoutException {
      // Fall back to running from source below.
    }
  });

  tearDownAll(() {
    if (workerExe != null) {
      try {
        compileDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Future<Process> spawnWorker(String directory, String name,
      [String mode = 'insert', String? encryptionKey]) {
    final args = [directory, name, mode, if (encryptionKey != null) encryptionKey];
    if (workerExe != null) return Process.start(workerExe!, args);
    return Process.start(
      Platform.resolvedExecutable,
      [workerSource, ...args],
      workingDirectory: Directory.current.path,
    );
  }

  /// Recomputes sample positions of the deterministic blob payload and
  /// compares them against the stored bytes — catches torn blob writes.
  void verifyBlob(int n, dynamic payload, int run) {
    expect(payload, isA<Uint8List>(),
        reason: 'blob payload missing/wrong type (run $run, n=$n)');
    final p = payload as Uint8List;
    expect(p.length, 64 * 1024,
        reason: 'blob truncated (run $run, n=$n): ${p.length} bytes');
    final expected = blobPayload(n);
    // Sample: first 64 bytes, every 4093rd byte, last 64 bytes.
    for (var j = 0; j < p.length; j += 4093) {
      expect(p[j], expected[j],
          reason: 'blob corrupted at byte $j (run $run, n=$n)');
    }
    for (var j = p.length - 64; j < p.length; j++) {
      expect(p[j], expected[j],
          reason: 'blob tail corrupted at byte $j (run $run, n=$n)');
    }
  }

  /// One kill cycle: spawn → READY → random delay → SIGKILL → reopen → verify.
  Future<void> runKillCycle(
    String mode,
    int run, {
    String? encryptionKey,
    Random? rand,
  }) async {
    final dir = Directory.systemTemp.createTempSync('ffastdb_kill_');
    try {
      final proc = await spawnWorker(dir.path, 'killtest', mode, encryptionKey);
      proc.stderr.drain();

      // Wait until the worker has the DB open and is writing.
      final ready = Completer<void>();
      proc.stdout.transform(utf8.decoder).listen((chunk) {
        if (chunk.contains('READY') && !ready.isCompleted) ready.complete();
      });
      await ready.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => fail('worker did not signal READY ($mode run $run)'),
      );

      // Random kill point: sweeps different moments of the write cycle
      // (mid-WAL write, post-commit pre-checkpoint, mid-B-Tree update...).
      await Future.delayed(
          Duration(milliseconds: 20 + (rand ?? Random()).nextInt(480)));

      // SIGKILL, not SIGTERM — no chance of a clean shutdown masking bugs.
      proc.kill(ProcessSignal.sigkill);
      await proc.exitCode.timeout(const Duration(seconds: 10));

      // ── Reopen in THIS process and verify integrity ──
      final db = await openDatabase(
        'killtest',
        directory: dir.path,
        indexes: ['status'],
        sortedIndexes: ['n'],
        compositeIndexes: [
          ['status', 'n'],
        ],
        encryptionKey: encryptionKey,
      );

      // 1. It opens at all — recovery must not throw on torn writes.
      final all = await db.getAll();

      // 2. Every doc is complete, internally consistent, and not duplicated
      //    (a double WAL replay would surface here as a repeated `n`).
      final seen = <int>{};
      for (final doc in all) {
        final n = doc['n'];
        expect(n, isA<int>(),
            reason: 'corrupt doc after kill ($mode run $run): $doc');
        final v = n as int;
        expect(doc['status'], v.isEven ? 'even' : 'odd',
            reason: 'torn doc after kill ($mode run $run): $doc');
        expect(seen.add(v), isTrue,
            reason:
                'duplicate doc n=$v after kill ($mode run $run) — double replay?');
        if (mode == 'blob') verifyBlob(v, doc['payload'], run);
      }

      // 3. count() agrees with the real number of docs.
      expect(await db.count(), all.length);

      // 4. Hash index is not out of sync with the primary store.
      final even =
          (await db.query().where('status').equals('even').find()).length;
      final odd =
          (await db.query().where('status').equals('odd').find()).length;
      expect(even + odd, all.length,
          reason:
              'status index lost/duplicated docs after kill ($mode run $run)');

      // 5. Sorted index covers every doc.
      final ranged =
          (await db.query().where('n').between(-1, 1 << 62).find()).length;
      expect(ranged, all.length,
          reason: 'sorted index lost docs after kill ($mode run $run)');

      // 6. The DB keeps accepting writes after recovery.
      final id = await db.insert({'n': -1, 'status': 'odd', 'payload': 'post'});
      expect(await db.findById(id), isNotNull);

      await db.close();
    } finally {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  const killTimeout = Timeout(Duration(minutes: 15));

  test('survives SIGKILL mid-insert ($insertRuns runs)', () async {
    final rand = Random();
    for (var run = 0; run < insertRuns; run++) {
      await runKillCycle('insert', run, rand: rand);
    }
  }, timeout: killTimeout);

  test('survives SIGKILL mid-batch insertAll ($modeRuns runs)', () async {
    final rand = Random();
    for (var run = 0; run < modeRuns; run++) {
      await runKillCycle('batch', run, rand: rand);
    }
  }, timeout: killTimeout);

  test('survives SIGKILL mid-update ($modeRuns runs)', () async {
    final rand = Random();
    for (var run = 0; run < modeRuns; run++) {
      await runKillCycle('update', run, rand: rand);
    }
  }, timeout: killTimeout);

  test('survives SIGKILL mid-compact ($modeRuns runs)', () async {
    final rand = Random();
    for (var run = 0; run < modeRuns; run++) {
      await runKillCycle('compact', run, rand: rand);
    }
  }, timeout: killTimeout);

  test('survives SIGKILL mid-reindex ($modeRuns runs)', () async {
    final rand = Random();
    for (var run = 0; run < modeRuns; run++) {
      await runKillCycle('reindex', run, rand: rand);
    }
  }, timeout: killTimeout);

  test('survives SIGKILL mid-blob-write ($modeRuns runs)', () async {
    final rand = Random();
    for (var run = 0; run < modeRuns; run++) {
      await runKillCycle('blob', run, rand: rand);
    }
  }, timeout: killTimeout);

  test('survives SIGKILL with encrypted storage ($modeRuns runs)', () async {
    final rand = Random();
    for (var run = 0; run < modeRuns; run++) {
      await runKillCycle('insert', run,
          encryptionKey: 'kill-test-key', rand: rand);
    }
  }, timeout: killTimeout);
}
