import 'dart:io';
import 'dart:math';
import 'package:isar_community/isar.dart';
import '../models/bench_doc.dart';
import 'bench_result.dart';

final _cities = ['London', 'New York', 'Tokyo', 'Paris', 'Buenos Aires', 'Sydney'];

List<BenchDoc> _makeDocs(int n) => [
      for (int i = 0; i < n; i++)
        BenchDoc()
          ..name = 'User_$i'
          ..age = 18 + (i % 60)
          ..city = _cities[i % _cities.length],
    ];

Future<List<BenchResult>> runIsarBench(Directory dir, int n) async {
  final results = <BenchResult>[];
  final isar = await Isar.open(
    [BenchDocSchema],
    directory: dir.path,
    name: 'isar_bench',
  );

  // 1. Bulk insert.
  final docs = _makeDocs(n);
  final swBulk = Stopwatch()..start();
  await isar.writeTxn(() async {
    await isar.benchDocs.putAll(docs);
  });
  swBulk.stop();
  results.add(BenchResult(
      engine: 'isar_community',
      operation: 'insertAll',
      n: n,
      elapsedMs: swBulk.elapsedMilliseconds));

  // 2. Sequential single-document inserts — each in its OWN write
  //    transaction, matching ffastdb's per-call durability.
  final singleN = min(n, 2000);
  final swSingle = Stopwatch()..start();
  for (int i = 0; i < singleN; i++) {
    await isar.writeTxn(() async {
      await isar.benchDocs.put(BenchDoc()
        ..name = 'Single_$i'
        ..age = 30
        ..city = _cities[i % _cities.length]);
    });
  }
  swSingle.stop();
  results.add(BenchResult(
      engine: 'isar_community',
      operation: 'singleInsert',
      n: singleN,
      elapsedMs: swSingle.elapsedMilliseconds));

  // 3. Indexed equality query, repeated.
  const queryN = 2000;
  final swQuery = Stopwatch()..start();
  for (int i = 0; i < queryN; i++) {
    await isar.benchDocs.filter().cityEqualTo(_cities[i % _cities.length]).findAll();
  }
  swQuery.stop();
  results.add(BenchResult(
      engine: 'isar_community',
      operation: 'queryIndexed',
      n: queryN,
      elapsedMs: swQuery.elapsedMilliseconds));

  // 4. Lookup by primary key, random order.
  final random = Random(42);
  final lookupN = min(n, 5000);
  final maxId = n; // autoIncrement ids for the bulk batch start at 1.
  final lookupIds = List.generate(lookupN, (_) => 1 + random.nextInt(maxId));
  final swFindById = Stopwatch()..start();
  for (final id in lookupIds) {
    await isar.benchDocs.get(id);
  }
  swFindById.stop();
  results.add(BenchResult(
      engine: 'isar_community',
      operation: 'findById',
      n: lookupN,
      elapsedMs: swFindById.elapsedMilliseconds));

  await isar.close();
  return results;
}
