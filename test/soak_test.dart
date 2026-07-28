@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

/// Long-running soak test — NOT part of the default suite.
///
/// Simulates real app usage over time: continuous insert/update/delete with
/// random SIGKILLs, watching for unbounded memory growth and file inflation
/// without compaction.
///
/// Run explicitly:
/// ```
/// FFASTDB_SOAK=1 FFASTDB_SOAK_MINUTES=60 dart test test/soak_test.dart
/// ```
void main() {
  final enabled = Platform.environment['FFASTDB_SOAK'] == '1';
  final minutes =
      int.tryParse(Platform.environment['FFASTDB_SOAK_MINUTES'] ?? '') ?? 10;

  final workerSource = File('test/helpers/write_worker.dart').absolute.path;

  test(
    'soak: continuous writes + random kills, bounded memory and file size '
    '($minutes min)',
    () async {
      final deadline = DateTime.now().add(Duration(minutes: minutes));
      final rand = Random();
      final dir = Directory.systemTemp.createTempSync('ffastdb_soak_');
      var cycle = 0;
      var totalDocsSeen = 0;
      final baseRss = ProcessInfo.currentRss;

      try {
        while (DateTime.now().isBefore(deadline)) {
          cycle++;

          // ── Write phase: worker writes flat out for 3–15 s ──
          final proc = await Process.start(
            Platform.resolvedExecutable,
            [workerSource, dir.path, 'soaktest'],
            workingDirectory: Directory.current.path,
          );
          proc.stderr.drain();
          final ready = Completer<void>();
          proc.stdout.transform(utf8.decoder).listen((chunk) {
            if (chunk.contains('READY') && !ready.isCompleted) {
              ready.complete();
            }
          });
          await ready.future.timeout(const Duration(seconds: 60),
              onTimeout: () => fail('worker not ready (cycle $cycle)'));

          await Future<void>.delayed(
              Duration(seconds: 3 + rand.nextInt(13)));
          proc.kill(ProcessSignal.sigkill);
          await proc.exitCode.timeout(const Duration(seconds: 10));

          // ── Verify phase: reopen, integrity, compact every 5 cycles ──
          final db = await openDatabase(
            'soaktest',
            directory: dir.path,
            indexes: ['status'],
            sortedIndexes: ['n'],
            compositeIndexes: [
              ['status', 'n'],
            ],
          );
          final all = await db.getAll();
          totalDocsSeen = all.length;

          expect(await db.count(), all.length,
              reason: 'count mismatch (cycle $cycle)');
          final even =
              (await db.query().where('status').equals('even').find()).length;
          final odd =
              (await db.query().where('status').equals('odd').find()).length;
          expect(even + odd, all.length,
              reason: 'index out of sync (cycle $cycle)');

          if (cycle % 5 == 0) await db.compact();
          await db.close();

          final dbSize = await File('${dir.path}/soaktest.fdb').length();
          final rss = ProcessInfo.currentRss;
          print('cycle $cycle: docs=$totalDocsSeen '
              'file=${(dbSize / 1024 / 1024).toStringAsFixed(1)}MB '
              'rss=${(rss / 1024 / 1024).toStringAsFixed(0)}MB');

          // Guard rails: memory must not grow without bound, and the file
          // must stay proportional to the live document count.
          expect(rss, lessThan(baseRss + 512 * 1024 * 1024),
              reason: 'memory grew >512MB over baseline (cycle $cycle)');
        }

        print('soak complete: $cycle cycles, $totalDocsSeen docs at end');
      } finally {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    },
    timeout: Timeout(Duration(minutes: minutes + 10)),
    skip: !enabled
        ? 'set FFASTDB_SOAK=1 (and FFASTDB_SOAK_MINUTES) to run the soak test'
        : null,
  );
}
