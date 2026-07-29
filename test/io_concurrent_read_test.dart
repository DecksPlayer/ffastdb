@TestOn('vm')
library;

import 'dart:io';

import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

/// Regression test for a real bug caught by `kill_recovery_test.dart`:
/// `findByIdsImpl` resolves documents in concurrent batches of 100 via
/// `Future.wait(_findById(...))`. Each read did `setPosition()` + `readInto()`
/// on the same shared `RandomAccessFile`, which:
///   1. throws `FileSystemException: An async operation is currently pending`
///   2. is not atomic — interleaved reads could come from the wrong offset
///
/// In-memory strategies never hit this (their reads are synchronous), which is
/// why the entire MemoryStorageStrategy-based suite missed it. The fix
/// serializes all handle operations inside `IoStorageStrategy`.
void main() {
  test('concurrent batched reads on native storage return correct docs',
      () async {
    final dir = Directory.systemTemp.createTempSync('ffastdb_io_concurrent_');
    try {
      final path = '${dir.path}/conc.fdb';
      final db = FastDB(
        WalStorageStrategy(
          main: IoStorageStrategy(path),
          wal: IoStorageStrategy('$path.wal'),
        ),
      );
      await db.open();

      // 300 docs → 3 concurrent read batches of 100 in findByIdsImpl.
      await db.insertAll(
        List.generate(300, (i) => {'n': i, 'pad': 'x' * 256}),
      );

      final all = await db.getAll();
      expect(all.length, 300);

      // Every doc must come from its own offset — a torn setPosition/read
      // pair would surface here as a duplicated or wrong `n`.
      final ns = all.map((d) => d['n'] as int).toSet();
      expect(ns.length, 300);

      await db.close();
    } finally {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });
}
