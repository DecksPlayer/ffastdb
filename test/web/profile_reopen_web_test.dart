@TestOn('browser')
library;

import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/web/indexed_db_strategy.dart';

int readCalls = 0;
int loadChunkCalls = 0;
int writeCalls = 0;
final readSw = Stopwatch();

class InstrumentedIdb extends IndexedDbStorageStrategy {
  InstrumentedIdb(super.dbName);

  @override
  Future<Uint8List> read(int offset, int size) {
    readCalls++;
    readSw.start();
    final f = super.read(offset, size);
    return f.whenComplete(() => readSw.stop());
  }

  @override
  Future<void> write(int offset, Uint8List data) {
    writeCalls++;
    return super.write(offset, data);
  }
}

void main() {
  test('profile: dirty reopen with 20k docs (5 index types), no clean close',
      () async {
    final dbName = 'profile_reopen_web_${DateTime.now().millisecondsSinceEpoch}';

    final storage1 = IndexedDbStorageStrategy(dbName);
    final db1 = FastDB.forTesting(storage1);
    db1.addIndex('type');
    db1.addIndex('userId');
    db1.addSortedIndex('content');
    db1.addSortedIndex('likes');
    db1.addFtsIndex('content');
    db1.addCompositeIndex(['type', 'userId']);
    await db1.open();

    final subjects = ['The cat', 'A developer', 'The database'];
    final verbs = ['jumps over', 'debugs', 'loves'];
    final objects = ['the lazy dog', 'the complex code', 'a pizza'];
    final phrases = [
      for (int i = 0; i < 400; i++)
        '${subjects[i % 3]} ${verbs[(i ~/ 3) % 3]} ${objects[(i ~/ 9) % 3]}.'
    ];

    const n = 100000;
    final sw0 = Stopwatch()..start();
    for (int start = 0; start < n; start += 10000) {
      final end = start + 10000 > n ? n : start + 10000;
      await db1.insertAll(List.generate(
          end - start,
          (i) => {
                'type': (start + i) % 2 == 0 ? 'post' : 'comment',
                'userId': (start + i) % 500,
                'content': phrases[(start + i) % 400],
                'likes': (start + i) % 500,
              }));
      print('  inserted up to ${end} (${sw0.elapsedMilliseconds}ms so far)');
    }
    sw0.stop();
    print('insertAll($n) total: ${sw0.elapsedMilliseconds}ms');

    // Deliberately DO NOT call db1.close() — this is what a hot restart / a
    // browser tab close (without beforeunload cleanup) leaves behind: the
    // clean-shutdown flag was never written, so the NEXT open() must take
    // the full rebuildSecondaryIndexes() path, exactly like the user's app.
    // We just flush so at least the inserted data itself is durable, same as
    // what actually reaches IndexedDB before a real tab close.
    await storage1.flush();

    // Fresh instance, same underlying IndexedDB database — simulates the
    // "hot restart" reopen.
    final storage2 = InstrumentedIdb(dbName);
    final db2 = FastDB.forTesting(storage2);
    db2.addIndex('type');
    db2.addIndex('userId');
    db2.addSortedIndex('content');
    db2.addSortedIndex('likes');
    db2.addFtsIndex('content');
    db2.addCompositeIndex(['type', 'userId']);

    final progressTicks = <double>[];
    final sw = Stopwatch()..start();
    await db2.open(
      onProgress: (p) {
        progressTicks.add(p);
      },
    );
    sw.stop();

    print('REOPEN (dirty, triggers rebuildSecondaryIndexes): '
        '${sw.elapsedMilliseconds}ms');
    print('progress ticks: ${progressTicks.length} '
        '(first=${progressTicks.isNotEmpty ? progressTicks.first : "-"}, '
        'last=${progressTicks.isNotEmpty ? progressTicks.last : "-"})');
    print('storage.read() calls=$readCalls, '
        'cumulative time in read()=${readSw.elapsedMilliseconds}ms');
    print('storage.write() calls=$writeCalls');

    final count = await db2.count();
    print('count after reopen: $count (expected $n)');
    expect(count, n);

    await db2.close();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
