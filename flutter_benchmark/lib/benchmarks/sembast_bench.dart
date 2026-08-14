import 'dart:io';
import 'dart:math';
import 'package:sembast/sembast_io.dart';
import 'bench_result.dart';

final _cities = ['London', 'New York', 'Tokyo', 'Paris', 'Buenos Aires', 'Sydney'];
final _store = intMapStoreFactory.store('bench_docs');

List<Map<String, dynamic>> _makeDocs(int n) => [
      for (int i = 0; i < n; i++)
        {'name': 'User_$i', 'age': 18 + (i % 60), 'city': _cities[i % _cities.length]},
    ];

Future<List<BenchResult>> runSembastBench(Directory dir, int n) async {
  final results = <BenchResult>[];
  final path = '${dir.path}/sembast_bench.db';
  final db = await databaseFactoryIo.openDatabase(path);

  // 1. Bulk insert — sembast has no batch-put API of its own; wrapping every
  //    write in ONE transaction is what defers the fsync to commit time,
  //    the equivalent of ffastdb's insertAll()/Isar's writeTxn(putAll).
  final docs = _makeDocs(n);
  final swBulk = Stopwatch()..start();
  final ids = await db.transaction((txn) async {
    final generatedIds = <int>[];
    for (final doc in docs) {
      generatedIds.add(await _store.add(txn, doc));
    }
    return generatedIds;
  });
  swBulk.stop();
  results.add(BenchResult(
      engine: 'sembast', operation: 'insertAll', n: n, elapsedMs: swBulk.elapsedMilliseconds));

  // 2. Sequential single-document inserts — each its own transaction.
  final singleN = min(n, 2000);
  final swSingle = Stopwatch()..start();
  for (int i = 0; i < singleN; i++) {
    await _store.add(db, {'name': 'Single_$i', 'age': 30, 'city': _cities[i % _cities.length]});
  }
  swSingle.stop();
  results.add(BenchResult(
      engine: 'sembast',
      operation: 'singleInsert',
      n: singleN,
      elapsedMs: swSingle.elapsedMilliseconds));

  // 3. "Indexed" equality query, repeated. Sembast has no secondary index
  //    concept — Filter.equals() is a linear scan over every record. Kept
  //    in the comparison deliberately: it's the real-world cost difference
  //    a B-Tree/hash index (ffastdb, Isar) buys you.
  const queryN = 2000;
  final swQuery = Stopwatch()..start();
  for (int i = 0; i < queryN; i++) {
    await _store.find(db, finder: Finder(filter: Filter.equals('city', _cities[i % _cities.length])));
  }
  swQuery.stop();
  results.add(BenchResult(
      engine: 'sembast',
      operation: 'queryIndexed',
      n: queryN,
      elapsedMs: swQuery.elapsedMilliseconds));

  // 4. Lookup by primary key, random order.
  final random = Random(42);
  final lookupN = min(n, 5000);
  final lookupIds = List.generate(lookupN, (_) => ids[random.nextInt(ids.length)]);
  final swFindById = Stopwatch()..start();
  for (final id in lookupIds) {
    await _store.record(id).get(db);
  }
  swFindById.stop();
  results.add(BenchResult(
      engine: 'sembast',
      operation: 'findById',
      n: lookupN,
      elapsedMs: swFindById.elapsedMilliseconds));

  await db.close();
  return results;
}
