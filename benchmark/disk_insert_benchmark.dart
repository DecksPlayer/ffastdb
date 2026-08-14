// Disk-backed benchmark: exercises the DEFAULT native storage path
// (WalStorageStrategy + IoStorageStrategy) — the in-memory benchmarks in this
// directory measure the B-Tree/index layer in isolation, but real apps write
// through the WAL to disk, which has its own I/O-bound cost profile.
//
// Run: dart run benchmark/disk_insert_benchmark.dart
import 'dart:io';
import 'package:ffastdb/ffastdb.dart';

final _cities = ['London', 'New York', 'Tokyo', 'Paris', 'Buenos Aires', 'Sydney'];

List<Map<String, dynamic>> _makeDocs(int n) => [
      for (int i = 0; i < n; i++)
        {'name': 'User_$i', 'age': 18 + (i % 60), 'city': _cities[i % _cities.length]},
    ];

Future<double> _insertAllDocsPerSec(int n) async {
  final dir = Directory.systemTemp.createTempSync('ffastdb_bench_disk');
  final path = '${dir.path}/bench.fdb';
  final storage = WalStorageStrategy(
    main: IoStorageStrategy(path),
    wal: IoStorageStrategy('$path.wal'),
  );
  final db = FastDB(storage);
  await db.open();
  final docs = _makeDocs(n);
  final sw = Stopwatch()..start();
  await db.insertAll(docs);
  sw.stop();
  await db.close();
  try {
    dir.deleteSync(recursive: true);
  } catch (_) {}
  return n / sw.elapsedMilliseconds * 1000;
}

Future<double> _reindexDocsPerSec(int n) async {
  final dir = Directory.systemTemp.createTempSync('ffastdb_bench_reindex');
  final path = '${dir.path}/bench.fdb';
  final storage = WalStorageStrategy(
    main: IoStorageStrategy(path),
    wal: IoStorageStrategy('$path.wal'),
  );
  final db = FastDB(storage);
  await db.open();
  await db.insertAll(_makeDocs(n));
  db.addIndex('city');
  final sw = Stopwatch()..start();
  await db.reindex();
  sw.stop();
  await db.close();
  try {
    dir.deleteSync(recursive: true);
  } catch (_) {}
  return n / sw.elapsedMilliseconds * 1000;
}

void _row(String label, double docsPerSec) {
  final k = (docsPerSec / 1000).toStringAsFixed(1);
  print('${label.padRight(38)} │ ${k.padLeft(8)}k docs/s');
}

Future<void> main() async {
  print('');
  print('=== FastDB — Disk-Backed Benchmark (WalStorageStrategy + IoStorageStrategy) ===');
  print('');

  print('insertAll() — real disk, no indexes:');
  _row('  10,000 docs', await _insertAllDocsPerSec(10000));
  _row('  100,000 docs', await _insertAllDocsPerSec(100000));
  _row('  1,000,000 docs', await _insertAllDocsPerSec(1000000));

  print('');
  print('reindex() — real disk, one HashIndex:');
  _row('  10,000 docs', await _reindexDocsPerSec(10000));
  _row('  100,000 docs', await _reindexDocsPerSec(100000));

  print('');
  print('=== DONE ===');
}
