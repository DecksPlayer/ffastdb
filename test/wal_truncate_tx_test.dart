@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

/// A StorageStrategy wrapper that injects ONE fault at a precise point:
/// - on the Nth truncate call
/// - on the Nth write call
/// - on the next write larger than a threshold
/// After firing once it disarms itself.
class _FailpointStorage implements StorageStrategy {
  _FailpointStorage(this._inner);

  final StorageStrategy _inner;

  int failOnTruncateCall = -1;
  int failOnWriteCall = -1;
  int failOnWriteLargerThan = -1;

  int _truncateCalls = 0;
  int _writeCalls = 0;

  @override
  StorageStrategy get innerStorage => _inner;

  @override
  Future<void> write(int offset, Uint8List data) {
    _writeCalls++;
    if (_writeCalls == failOnWriteCall) {
      failOnWriteCall = -1;
      throw StateError('injected fault (write)');
    }
    if (failOnWriteLargerThan >= 0 && data.length > failOnWriteLargerThan) {
      failOnWriteLargerThan = -1;
      throw StateError('injected fault (large write)');
    }
    return _inner.write(offset, data);
  }

  @override
  Future<void> truncate(int size) {
    _truncateCalls++;
    if (_truncateCalls == failOnTruncateCall) {
      failOnTruncateCall = -1;
      throw StateError('injected fault (truncate)');
    }
    return _inner.truncate(size);
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
  int? get sizeSync => _inner.sizeSync;
  @override
  Uint8List? readSync(int offset, int size) => _inner.readSync(offset, size);
  @override
  bool get needsExplicitFlush => _inner.needsExplicitFlush;
  @override
  bool writeSync(int offset, Uint8List data) => _inner.writeSync(offset, data);
}

/// Second-generation tests for the transactional compact:
/// kill the operation at every point of the NEW mechanism itself —
///
///   A. before the COMMIT marker reaches the WAL  → tx discarded, PRE state
///   B. after the marker, before main-file apply  → recovery replays, POST state
///   C. in the middle of the main-file apply      → replay must be idempotent
///
/// Scenario C is the nasty one: commit() already wrote the COMMIT marker
/// when the apply fails halfway. If rollback then checkpoints (truncates)
/// the WAL, the committed-but-unapplied transaction is destroyed together
/// with the already-truncated main file — total data loss.
void main() {
  late Directory dir;
  late String path;
  late _FailpointStorage mainFail;
  late _FailpointStorage walFail;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ffastdb_wtx_');
    path = '${dir.path}/t.fdb';
    mainFail = _FailpointStorage(IoStorageStrategy(path));
    walFail = _FailpointStorage(IoStorageStrategy('$path.wal'));
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  FastDB openWithFailpoints() =>
      FastDB(WalStorageStrategy(main: mainFail, wal: walFail));

  FastDB openPlain() => FastDB(
        WalStorageStrategy(
          main: IoStorageStrategy(path),
          wal: IoStorageStrategy('$path.wal'),
        ),
      );

  Future<void> seedDocs(int n) async {
    // Seed with the PLAIN stack so the failpoint counters stay at zero —
    // arming happens only around the compact() call itself.
    final db = openPlain();
    db.addIndex('status');
    await db.open();
    await db.insertAll(List.generate(
        n, (i) => {'n': i, 'status': i.isEven ? 'even' : 'odd'}));
    await db.close();
  }

  Future<void> verifyIntact(int expectedDocs, String scenario) async {
    final db = openPlain();
    db.addIndex('status');
    await db.open();
    final all = await db.getAll();
    expect(all.length, expectedDocs, reason: 'doc count wrong ($scenario)');
    final seen = <int>{};
    for (final doc in all) {
      final v = doc['n'];
      expect(v, isA<int>(), reason: 'corrupt doc ($scenario): $doc');
      expect(doc['status'], (v as int).isEven ? 'even' : 'odd',
          reason: 'torn doc ($scenario): $doc');
      expect(seen.add(v), isTrue,
          reason: 'duplicate doc n=$v ($scenario) — double apply?');
    }
    expect(await db.count(), expectedDocs);
    final even =
        (await db.query().where('status').equals('even').find()).length;
    final odd =
        (await db.query().where('status').equals('odd').find()).length;
    expect(even + odd, expectedDocs,
        reason: 'index out of sync ($scenario)');
    await db.close();
  }

  test('A. fault before COMMIT marker → tx discarded, pre-compact state',
      () async {
    await seedDocs(300);

    // The compact commit bundle for 300 docs is ~30-40 KB — larger than any
    // single-op auto-commit bundle (a few KB at most). Failing there means
    // the COMMIT marker never persists.
    walFail.failOnWriteLargerThan = 10 * 1024;

    final db = openWithFailpoints();
    db.addIndex('status');
    await db.open();
    await expectLater(db.compact(), throwsStateError);
    try {
      await db.close();
    } catch (_) {}

    await verifyIntact(300, 'A: pre-compact');
  });

  test('B. fault after COMMIT marker, before apply → recovery replays tx',
      () async {
    await seedDocs(300);

    // The ONLY _main.truncate in a transactional compact is the deferred
    // truncate at commit-apply time. Failing there = crash right after the
    // atomic commit point.
    mainFail.failOnTruncateCall = 1;

    final db = openWithFailpoints();
    db.addIndex('status');
    await db.open();
    await expectLater(db.compact(), throwsStateError);
    try {
      await db.close();
    } catch (_) {}

    // Recovery must replay the committed truncate+writes: fully compacted,
    // exactly once.
    await verifyIntact(300, 'B: post-commit replay');
  });

  test('C. fault MID-APPLY → replay is idempotent, no data loss', () async {
    await seedDocs(300);

    // Let the truncate and the first applies through, fault on the 15th
    // main-file write — half the transaction applied, half pending.
    // (mainFail counts are at zero: seeding used the plain stack.)
    mainFail.failOnWriteCall = 15;

    final db = openWithFailpoints();
    db.addIndex('status');
    await db.open();
    await expectLater(db.compact(), throwsStateError);
    try {
      await db.close();
    } catch (_) {}

    // If rollback truncated the WAL after the partial apply, this reopen
    // finds a destroyed database (truncate applied, ~9 docs rewritten).
    await verifyIntact(300, 'C: mid-apply replay');
  });
}
