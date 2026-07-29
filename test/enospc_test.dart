@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

/// A StorageStrategy that simulates a full disk: writes succeed until
/// [quota] bytes have been written, then throw — like ENOSPC on a real
/// mobile device with no space left.
class _QuotaStorage implements StorageStrategy {
  _QuotaStorage(this._inner, this.quota);

  final StorageStrategy _inner;

  /// Mutable so a test can let the DB fill up normally and then tighten the
  /// quota right before a specific operation (e.g. compact).
  int quota;
  int _written = 0;

  int get writtenBytes => _written;

  @override
  StorageStrategy get innerStorage => _inner;

  @override
  Future<void> write(int offset, Uint8List data) {
    if (_written + data.length > quota) {
      throw StateError('ENOSPC (simulated): no space left on device');
    }
    _written += data.length;
    return _inner.write(offset, data);
  }

  @override
  Future<void> open() => _inner.open();
  @override
  Future<Uint8List> read(int offset, int size) => _inner.read(offset, size);
  @override
  Future<void> flush() => _inner.flush();
  @override
  Future<void> close() => _inner.close();
  @override
  Future<int> get size => _inner.size;
  @override
  Future<void> truncate(int size) => _inner.truncate(size);
  @override
  int? get sizeSync => _inner.sizeSync;
  @override
  Uint8List? readSync(int offset, int size) => _inner.readSync(offset, size);
  @override
  bool get needsExplicitFlush => _inner.needsExplicitFlush;
  @override
  bool writeSync(int offset, Uint8List data) => _inner.writeSync(offset, data);
}

/// Disk-full (ENOSPC) durability test with real files + WAL.
///
/// A failed write mid-transaction must leave the database in a consistent
/// state: on reopen, recovery discards the torn tail and every surviving
/// document is complete and index-consistent.
void main() {
  test('write failure by full disk leaves a consistent database', () async {
    final dir = Directory.systemTemp.createTempSync('ffastdb_enospc_');
    try {
      final path = '${dir.path}/full.fdb';

      StorageStrategy walStack() => WalStorageStrategy(
            main: IoStorageStrategy(path),
            wal: IoStorageStrategy('$path.wal'),
          );

      // 64 KB quota — fills up after a few hundred documents.
      final db = FastDB(_QuotaStorage(walStack(), 64 * 1024));
      await db.open();
      db.addIndex('status');

      var inserted = 0;
      var failed = false;
      while (inserted < 10000) {
        try {
          await db.insert(
              {'n': inserted, 'status': inserted.isEven ? 'even' : 'odd'});
          inserted++;
        } on StateError {
          failed = true;
          break;
        }
      }
      expect(failed, isTrue, reason: 'quota should have been exhausted');
      expect(inserted, greaterThan(0),
          reason: 'quota too small — nothing was written');

      // Close may also fail on flush — the DB is mid-failure, swallow it.
      try {
        await db.close();
      } catch (_) {}

      // Reopen WITHOUT the quota wrapper: recovery must handle the torn tail.
      final db2 = FastDB(walStack());
      db2.addIndex('status'); // register BEFORE open (rebuilt on unclean open)
      await db2.open();

      final all = await db2.getAll();
      for (final doc in all) {
        final n = doc['n'];
        expect(n, isA<int>(), reason: 'corrupt doc after ENOSPC: $doc');
        expect(doc['status'], (n as int).isEven ? 'even' : 'odd',
            reason: 'torn doc after ENOSPC: $doc');
      }
      expect(await db2.count(), all.length);
      final even =
          (await db2.query().where('status').equals('even').find()).length;
      final odd =
          (await db2.query().where('status').equals('odd').find()).length;
      expect(even + odd, all.length,
          reason: 'index out of sync after ENOSPC');

      // Still writable after recovery.
      final id = await db2.insert({'n': -1, 'status': 'odd'});
      expect(await db2.findById(id), isNotNull);

      await db2.close();
    } finally {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('ENOSPC during compact leaves all documents intact', () async {
    final dir = Directory.systemTemp.createTempSync('ffastdb_enospc_compact_');
    try {
      final path = '${dir.path}/compact.fdb';

      StorageStrategy walStack() => WalStorageStrategy(
            main: IoStorageStrategy(path),
            wal: IoStorageStrategy('$path.wal'),
          );

      // Start with plenty of space so the DB fills up normally.
      final quota = _QuotaStorage(walStack(), 64 * 1024 * 1024);
      final db = FastDB(quota);
      await db.open();
      db.addIndex('status');

      await db.insertAll(List.generate(
          300,
          (i) => {
                'n': i,
                'status': i.isEven ? 'even' : 'odd',
                'pad': 'x' * 512,
              }));

      // Tighten the quota: the full-file rewrite of compact() must fail.
      quota.quota = quota.writtenBytes + 4096;

      await expectLater(
        db.compact(),
        throwsStateError,
        reason: 'compact must surface the disk-full error, not swallow it',
      );

      try {
        await db.close();
      } catch (_) {}

      // Reopen without quota: whatever compact managed to do, every document
      // must be present and index-consistent (pre- or post-compact state).
      final db2 = FastDB(walStack());
      db2.addIndex('status'); // register BEFORE open (rebuilt on unclean open)
      await db2.open();

      final all = await db2.getAll();
      expect(all.length, 300);
      final seen = <int>{};
      for (final doc in all) {
        final n = doc['n'];
        expect(n, isA<int>(), reason: 'corrupt doc after ENOSPC-compact');
        expect(doc['status'], (n as int).isEven ? 'even' : 'odd');
        expect(seen.add(n), isTrue, reason: 'duplicate doc after compact');
      }
      expect(await db2.count(), 300);
      final even =
          (await db2.query().where('status').equals('even').find()).length;
      final odd =
          (await db2.query().where('status').equals('odd').find()).length;
      expect(even + odd, 300,
          reason: 'index out of sync after ENOSPC during compact');

      await db2.close();
    } finally {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
