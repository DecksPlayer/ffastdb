import 'dart:io';
import 'dart:math';
import 'package:ffastdb/ffastdb.dart';
import 'bench_result.dart';

final _cities = ['London', 'New York', 'Tokyo', 'Paris', 'Buenos Aires', 'Sydney'];

List<Map<String, dynamic>> _makeDocs(int n) => [
      for (int i = 0; i < n; i++)
        {'name': 'User_$i', 'age': 18 + (i % 60), 'city': _cities[i % _cities.length]},
    ];

Future<List<BenchResult>> runFfastdbBench(Directory dir, int n) async {
  final results = <BenchResult>[];
  final path = '${dir.path}/ffastdb_bench.fdb';
  final storage = WalStorageStrategy(
    main: IoStorageStrategy(path),
    wal: IoStorageStrategy('$path.wal'),
  );
  final db = FastDB(storage);
  db.addIndex('city');
  await db.open();

  // 1. Bulk insert.
  final docs = _makeDocs(n);
  final swBulk = Stopwatch()..start();
  final ids = await db.insertAll(docs);
  swBulk.stop();
  results.add(BenchResult(
      engine: 'ffastdb', operation: 'insertAll', n: n, elapsedMs: swBulk.elapsedMilliseconds));

  // 2. Sequential single-document inserts (smaller n — this path is
  //    intentionally much slower for every WAL-durable engine).
  final singleN = min(n, 2000);
  final swSingle = Stopwatch()..start();
  for (int i = 0; i < singleN; i++) {
    await db.insert({'name': 'Single_$i', 'age': 30, 'city': _cities[i % _cities.length]});
  }
  swSingle.stop();
  results.add(BenchResult(
      engine: 'ffastdb',
      operation: 'singleInsert',
      n: singleN,
      elapsedMs: swSingle.elapsedMilliseconds));

  // 3. Indexed equality query, repeated.
  const queryN = 2000;
  final swQuery = Stopwatch()..start();
  for (int i = 0; i < queryN; i++) {
    await db.query().where('city').equals(_cities[i % _cities.length]).find();
  }
  swQuery.stop();
  results.add(BenchResult(
      engine: 'ffastdb',
      operation: 'queryIndexed',
      n: queryN,
      elapsedMs: swQuery.elapsedMilliseconds));

  // 4. Lookup by primary key, random order.
  final random = Random(42);
  final lookupN = min(n, 5000);
  final lookupIds = List.generate(lookupN, (_) => ids[random.nextInt(ids.length)]);
  final swFindById = Stopwatch()..start();
  for (final id in lookupIds) {
    await db.findById(id);
  }
  swFindById.stop();
  results.add(BenchResult(
      engine: 'ffastdb',
      operation: 'findById',
      n: lookupN,
      elapsedMs: swFindById.elapsedMilliseconds));

  await db.close();
  return results;
}
