@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

/// Reactive watcher stress tests:
/// - mass subscribe/cancel churn (StreamController leak / zombie emissions)
/// - watcher coherence after a real crash (kill → reopen → initial emission)
void main() {
  group('watcher churn', () {
    late FastDB db;

    setUp(() async {
      db = FastDB.forTesting(MemoryStorageStrategy());
      await db.open();
      db.addIndex('status');
    });

    tearDown(() => db.close());

    test('500 subscribe/cancel cycles: no leaks, no duplicate emissions',
        () async {
      await db.insert({'status': 'active'});

      for (var i = 0; i < 500; i++) {
        final sub = db.watch('status').listen((_) {});
        await sub.cancel();
      }

      // A fresh watcher must see the initial state and then exactly ONE
      // emission per insert — any zombie controller would multiply events.
      final events = <List<int>>[];
      final sub = db.watch('status').listen(events.add);
      // Let the initial emission land.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await db.insert({'status': 'active'});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(events.length, 2,
          reason:
              'expected [initial, one update] but got ${events.length} events '
              '— leaked StreamControllers from the churn?');
      expect(events.first.length, 1);
      expect(events.last.length, 2);

      await sub.cancel();
    });

    test('cancelled watcher receives nothing further', () async {
      final events = <List<int>>[];
      final sub = db.watch('status').listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();

      await db.insert({'status': 'active'});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Only the initial emission (empty set), nothing after cancel.
      expect(events.length, 1);
    });
  });

  group('watcher after crash', () {
    final workerSource = File('test/helpers/write_worker.dart').absolute.path;

    test('initial emission after kill+reopen matches recovered state',
        () async {
      final dir = Directory.systemTemp.createTempSync('ffastdb_watch_');
      Process? proc;
      try {
        // Worker writes docs; we kill it — recovery replays committed ops.
        proc = await Process.start(
          Platform.resolvedExecutable,
          [workerSource, dir.path, 'watchtest'],
          workingDirectory: Directory.current.path,
        );
        proc.stderr.drain();
        final ready = Completer<void>();
        proc.stdout.transform(utf8.decoder).listen((chunk) {
          if (chunk.contains('READY') && !ready.isCompleted) ready.complete();
        });
        await ready.future
            .timeout(const Duration(seconds: 60), onTimeout: () => fail('no READY'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        proc.kill(ProcessSignal.sigkill);
        await proc.exitCode.timeout(const Duration(seconds: 10));
        proc = null;

        final db = await openDatabase(
          'watchtest',
          directory: dir.path,
          indexes: ['status'],
          sortedIndexes: ['n'],
          compositeIndexes: [
            ['status', 'n'],
          ],
        );

        final all = await db.getAll();
        final expectedIds = all.map((d) => d['ffdbID'] as int).toSet();

        // The watcher's FIRST emission must be coherent with the recovered
        // state — not empty, not stale, not duplicated.
        final firstIds =
            await db.watch('status').first.timeout(const Duration(seconds: 10));
        expect(firstIds.toSet(), expectedIds);

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
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
