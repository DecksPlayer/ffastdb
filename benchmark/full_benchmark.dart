import 'package:benchmark_harness/benchmark_harness.dart';
import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';

// ─── Custom Emitter for Ops/Sec Table ───────────────────────────────────────

class BenchResult {
  final String name;
  final int ops;
  final double usPerRun;

  BenchResult(this.name, this.ops, this.usPerRun);

  double get msPerRun => usPerRun / 1000;
  double get opsPerSec => ops / (usPerRun / 1000000);
  double get msPerOp => usPerRun / ops / 1000;

  @override
  String toString() {
    final opsK = (opsPerSec / 1000).toStringAsFixed(1);
    final msOp = msPerOp.toStringAsFixed(3);
    return '${name.padRight(50)} │ ${opsK.padLeft(8)}k ops/s │ ${msOp.padLeft(8)} ms/op';
  }
}

final List<BenchResult> globalResults = [];

String _fmt(double v) {
  if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(2)}M';
  if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
  return v.toStringAsFixed(1);
}

class OpsSecEmitter implements ScoreEmitter {
  final int opsPerRun;
  
  const OpsSecEmitter(this.opsPerRun);

  @override
  void emit(String testName, double value) {
    globalResults.add(BenchResult(testName, opsPerRun, value));
  }
}

// ─── 1. Sequential Insert ──────────────────────────────────────────────────

class SequentialInsertBench extends AsyncBenchmarkBase {
  static const int N = 10000;
  SequentialInsertBench() : super('Sequential insert (10k docs)', emitter: const OpsSecEmitter(N));

  @override
  Future<void> run() async {
    final db = FastDB(MemoryStorageStrategy());
    await db.open();
    for (int i = 0; i < N; i++) {
        await db.insert({
          'name': 'User_$i',
          'age': 20 + (i % 60),
          'city': ['London', 'Paris', 'Tokyo', 'NYC', 'Berlin'][i % 5],
          'active': i % 3 != 0,
          'score': i * 1.5,
        });
    }
    await db.close();
  }
}

// ─── 2. Batch Insert (insertAll) ──────────────────────────────────────────

class BatchInsertBench extends AsyncBenchmarkBase {
  static const int N = 10000;
  BatchInsertBench() : super('Batch insert / insertAll (10k docs)', emitter: const OpsSecEmitter(N));

  late List<Map<String, dynamic>> docs;

  @override
  Future<void> setup() async {
    docs = List.generate(N, (i) => {
      'name': 'User_$i',
      'age': 20 + (i % 60),
      'city': ['London', 'Paris', 'Tokyo', 'NYC', 'Berlin'][i % 5],
      'active': i % 3 != 0,
      'score': i * 1.5,
    });
  }

  @override
  Future<void> run() async {
    final db = FastDB(MemoryStorageStrategy());
    await db.open();
    await db.insertAll(docs);
    await db.close();
  }
}

// ─── 3. Primary Key Lookup (findById) ─────────────────────────────────────

class FindByIdBench extends AsyncBenchmarkBase {
  static const int N = 10000;
  static const int READS = 10000;
  FindByIdBench() : super('Primary key lookup / findById (10k reads)', emitter: const OpsSecEmitter(READS));

  late FastDB db;

  @override
  Future<void> setup() async {
    db = FastDB(MemoryStorageStrategy());
    await db.open();
    for (int i = 0; i < N; i++) {
      await db.insert({'name': 'User_$i', 'age': 20 + (i % 60)});
    }
    await db.findById(1);
    await db.findById(N ~/ 2);
  }

  @override
  Future<void> teardown() async {
    await db.close();
  }

  @override
  Future<void> run() async {
    for (int i = 0; i < READS; i++) {
      await db.findById(1 + (i % N));
    }
  }
}

// ─── 4. HashIndex equality lookup ─────────────────────────────────────────

class HashIndexBench extends AsyncBenchmarkBase {
  static const int N = 10000;
  static const int QUERIES = 5000;
  HashIndexBench() : super('HashIndex equality query (5k queries)', emitter: const OpsSecEmitter(QUERIES));

  late FastDB db;
  late List<String> cities;

  @override
  Future<void> setup() async {
    db = FastDB(MemoryStorageStrategy());
    db.addIndex('city');
    await db.open();
    for (int i = 0; i < N; i++) {
      await db.insert({
        'name': 'User_$i',
        'city': ['London', 'Paris', 'Tokyo', 'NYC', 'Berlin'][i % 5],
      });
    }
    cities = ['London', 'Paris', 'Tokyo', 'NYC', 'Berlin'];
  }

  @override
  Future<void> teardown() async {
    await db.close();
  }

  @override
  Future<void> run() async {
    for (int i = 0; i < QUERIES; i++) {
      db.query().where('city').equals(cities[i % 5]).findIds();
    }
  }
}

// ─── 5. SortedIndex range query ───────────────────────────────────────────

class SortedIndexRangeBench extends AsyncBenchmarkBase {
  static const int N = 10000;
  static const int QUERIES = 5000;
  SortedIndexRangeBench() : super('SortedIndex range query (5k queries)', emitter: const OpsSecEmitter(QUERIES));

  late FastDB db;

  @override
  Future<void> setup() async {
    db = FastDB(MemoryStorageStrategy());
    db.addSortedIndex('age');
    await db.open();
    for (int i = 0; i < N; i++) {
      await db.insert({'name': 'User_$i', 'age': 20 + (i % 60)});
    }
  }

  @override
  Future<void> teardown() async {
    await db.close();
  }

  @override
  Future<void> run() async {
    for (int i = 0; i < QUERIES; i++) {
      db.query().where('age').between(25, 35).findIds();
    }
  }
}

// ─── 6. SortedIndex greaterThan ───────────────────────────────────────────

class SortedIndexGreaterThanBench extends AsyncBenchmarkBase {
  static const int N = 10000;
  static const int QUERIES = 5000;
  SortedIndexGreaterThanBench() : super('SortedIndex greaterThan (5k queries)', emitter: const OpsSecEmitter(QUERIES));

  late FastDB db;

  @override
  Future<void> setup() async {
    db = FastDB(MemoryStorageStrategy());
    db.addSortedIndex('score');
    await db.open();
    for (int i = 0; i < N; i++) {
      await db.insert({'name': 'User_$i', 'score': i * 1.5});
    }
  }

  @override
  Future<void> teardown() async {
    await db.close();
  }

  @override
  Future<void> run() async {
    for (int i = 0; i < QUERIES; i++) {
      db.query().where('score').greaterThan(5000.0).findIds();
    }
  }
}

// ─── 7. BitmaskIndex boolean lookup ───────────────────────────────────────

class BitmaskIndexBench extends AsyncBenchmarkBase {
  static const int N = 10000;
  static const int QUERIES = 5000;
  BitmaskIndexBench() : super('BitmaskIndex boolean lookup (5k queries)', emitter: const OpsSecEmitter(QUERIES));

  late FastDB db;

  @override
  Future<void> setup() async {
    db = FastDB(MemoryStorageStrategy());
    db.addBitmaskIndex('active');
    await db.open();
    for (int i = 0; i < N; i++) {
      await db.insert({'name': 'User_$i', 'active': i % 3 != 0});
    }
  }

  @override
  Future<void> teardown() async {
    await db.close();
  }

  @override
  Future<void> run() async {
    for (int i = 0; i < QUERIES; i++) {
      db.query().where('active').equals(true).findIds();
    }
  }
}

// ─── 8. OR Query (2 groups) ───────────────────────────────────────────────

class OrQueryBench extends AsyncBenchmarkBase {
  static const int N = 10000;
  static const int QUERIES = 3000;
  OrQueryBench() : super('OR query city=London OR city=Paris (3k)', emitter: const OpsSecEmitter(QUERIES));

  late FastDB db;

  @override
  Future<void> setup() async {
    db = FastDB(MemoryStorageStrategy());
    db.addIndex('city');
    await db.open();
    for (int i = 0; i < N; i++) {
      await db.insert({
        'name': 'User_$i',
        'city': ['London', 'Paris', 'Tokyo', 'NYC', 'Berlin'][i % 5],
      });
    }
  }

  @override
  Future<void> teardown() async {
    await db.close();
  }

  @override
  Future<void> run() async {
    for (int i = 0; i < QUERIES; i++) {
      db.query()
          .where('city').equals('London')
          .or()
          .where('city').equals('Paris')
          .findIds();
    }
  }
}

// ─── 9. AND Complex query (2 fields) ──────────────────────────────────────

class AndQueryBench extends AsyncBenchmarkBase {
  static const int N = 10000;
  static const int QUERIES = 3000;
  AndQueryBench() : super('AND query age+city (3k)', emitter: const OpsSecEmitter(QUERIES));

  late FastDB db;

  @override
  Future<void> setup() async {
    db = FastDB(MemoryStorageStrategy());
    db.addSortedIndex('age');
    db.addIndex('city');
    await db.open();
    for (int i = 0; i < N; i++) {
      await db.insert({
        'name': 'User_$i',
        'age': 20 + (i % 60),
        'city': ['London', 'Paris', 'Tokyo', 'NYC', 'Berlin'][i % 5],
      });
    }
  }

  @override
  Future<void> teardown() async {
    await db.close();
  }

  @override
  Future<void> run() async {
    for (int i = 0; i < QUERIES; i++) {
      db.query()
          .where('age').between(25, 35)
          .and('city').equals('London')
          .findIds();
    }
  }
}

// ─── 10. IN query ─────────────────────────────────────────────────────────

class InQueryBench extends AsyncBenchmarkBase {
  static const int N = 10000;
  static const int QUERIES = 3000;
  InQueryBench() : super('IN query city IN [Lon,Par,Tok] (3k queries)', emitter: const OpsSecEmitter(QUERIES));

  late FastDB db;

  @override
  Future<void> setup() async {
    db = FastDB(MemoryStorageStrategy());
    db.addIndex('city');
    await db.open();
    for (int i = 0; i < N; i++) {
      await db.insert({
        'name': 'User_$i',
        'city': ['London', 'Paris', 'Tokyo', 'NYC', 'Berlin'][i % 5],
      });
    }
  }

  @override
  Future<void> teardown() async {
    await db.close();
  }

  @override
  Future<void> run() async {
    for (int i = 0; i < QUERIES; i++) {
      db.query().where('city').isIn(['London', 'Paris', 'Tokyo']).findIds();
    }
  }
}

// ─── 11. Update ───────────────────────────────────────────────────────────

class UpdateBench extends AsyncBenchmarkBase {
  static const int N = 5000;
  UpdateBench() : super('Partial update (5k updates)', emitter: const OpsSecEmitter(N));

  late List<Map<String, dynamic>> _docs;
  late FastDB _db;
  late List<int> _ids;

  @override
  Future<void> setup() async {
    _docs = List.generate(N, (i) => {'name': 'User_$i', 'age': 20 + (i % 60)});
  }

  // Re-create DB each iteration so append-only storage doesn't inflate later runs.
  @override
  Future<void> exercise() async {
    _db = FastDB(MemoryStorageStrategy());
    await _db.open();
    _ids = await _db.insertAll(_docs);
    await run();
    await _db.close();
  }

  @override
  Future<void> warmup() => exercise();

  @override
  Future<void> run() async {
    for (int i = 0; i < N; i++) {
      await _db.update(_ids[i], {'age': 30 + (i % 40)});
    }
  }
}

// ─── 12. Delete ───────────────────────────────────────────────────────────

class DeleteBench extends AsyncBenchmarkBase {
  static const int N = 5000;
  DeleteBench() : super('Delete by id (5k deletes)', emitter: const OpsSecEmitter(N));

  late List<Map<String, dynamic>> _docs;
  late FastDB _db;
  late List<int> _ids;

  @override
  Future<void> setup() async {
    _docs = List.generate(N, (i) => {'name': 'User_$i', 'age': 20 + (i % 60)});
  }

  // exercise() is the unit timed by the harness. Override it to re-populate
  // the DB before each measured run() so that run() only contains deletes.
  @override
  Future<void> exercise() async {
    _db = FastDB(MemoryStorageStrategy());
    await _db.open();
    _ids = await _db.insertAll(_docs); // fast batch — not what we're measuring
    await run();                        // only deletes are the subject
    await _db.close();
  }

  // warmup() normally calls run() directly — override it to go through exercise()
  // so _db is initialized before run() is called.
  @override
  Future<void> warmup() => exercise();

  @override
  Future<void> run() async {
    for (int i = 0; i < N; i++) {
      await _db.delete(_ids[i]);
    }
  }
}

// ─── 13. sortBy ───────────────────────────────────────────────────────────

class SortByBench extends AsyncBenchmarkBase {
  static const int N = 5000;
  static const int QUERIES = 1000;
  SortByBench() : super('sortBy age ascending (1k queries / 5k docs)', emitter: const OpsSecEmitter(QUERIES));

  late FastDB db;

  @override
  Future<void> setup() async {
    db = FastDB(MemoryStorageStrategy());
    db.addSortedIndex('age');
    await db.open();
    for (int i = 0; i < N; i++) {
      await db.insert({'name': 'User_$i', 'age': 20 + (i % 60)});
    }
  }

  @override
  Future<void> teardown() async {
    await db.close();
  }

  @override
  Future<void> run() async {
    for (int i = 0; i < QUERIES; i++) {
      db.query().where('age').alwaysTrue().sortBy('age').findIds();
    }
  }
}

// ─── 14. Large dataset 100k inserts ───────────────────────────────────────

class LargeDatasetBench extends AsyncBenchmarkBase {
  static const int N = 100000;
  LargeDatasetBench() : super('Batch insert 100k documents', emitter: const OpsSecEmitter(N));

  late List<Map<String, dynamic>> docs;

  @override
  Future<void> setup() async {
    docs = List.generate(N, (i) => {
      'name': 'User_$i',
      'age': 20 + (i % 60),
    });
  }

  @override
  Future<void> run() async {
    final db = FastDB(MemoryStorageStrategy());
    await db.open();
    await db.insertAll(docs);
    await db.close();
  }
}

// ─── 15. Open / close (cold start simulation) ────────────────────────────

class DBOpenCloseBench extends AsyncBenchmarkBase {
  static const int ROUNDS = 50;
  DBOpenCloseBench() : super('DB open+seed+close cycle (50 rounds)', emitter: const OpsSecEmitter(ROUNDS));

  late List<Map<String, dynamic>> docs;

  @override
  Future<void> setup() async {
    docs = List.generate(1000, (i) => {'name': 'User_$i', 'age': i});
  }

  @override
  Future<void> run() async {
    for (int round = 0; round < ROUNDS; round++) {
      final db = FastDB(MemoryStorageStrategy());
      await db.open();
      await db.insertAll(docs);
      await db.close();
    }
  }
}

// ─── Main ─────────────────────────────────────────────────────────────────────

Future<void> main() async {
  print('');
  print('╔══════════════════════════════════════════════════════════════════════════════════╗');
  print('║              FastDB — Professional Performance Benchmark Suite (Harness)        ║');
  print('║              Platform: Dart VM  │  In-Memory Storage  │  2026                   ║');
  print('╚══════════════════════════════════════════════════════════════════════════════════╝');
  print('');

  await SequentialInsertBench().report();
  await BatchInsertBench().report();
  await FindByIdBench().report();
  await HashIndexBench().report();
  await SortedIndexRangeBench().report();
  await SortedIndexGreaterThanBench().report();
  await BitmaskIndexBench().report();
  await OrQueryBench().report();
  await AndQueryBench().report();
  await InQueryBench().report();
  await UpdateBench().report();
  await DeleteBench().report();
  await SortByBench().report();
  await LargeDatasetBench().report();
  await DBOpenCloseBench().report();

  print('');
  print('Benchmark                                          │  ops/sec   │   ms/op');
  print('─' * 85);
  for (final r in globalResults) {
    print(r);
  }
  print('─' * 85);
  print('');

  final insertSeq = globalResults[0];
  final insertBatch = globalResults[1];
  final findById = globalResults[2];
  final hashEq = globalResults[3];
  final sortRange = globalResults[4];
  final bitmask = globalResults[6];

  print('┌─────────────────────────────── KEY METRICS ───────────────────────────────────┐');
  print('│ Sequential insert:   ${_fmt(insertSeq.opsPerSec)} ops/s'.padRight(40) + '(${insertSeq.msPerOp.toStringAsFixed(3)}ms/op)'.padRight(40) + '│');
  print('│ Batch insert:        ${_fmt(insertBatch.opsPerSec)} ops/s'.padRight(40) + '(${insertBatch.msPerOp.toStringAsFixed(3)}ms/op)'.padRight(40) + '│');
  print('│ findById (B-Tree):   ${_fmt(findById.opsPerSec)} ops/s'.padRight(40) + '(${findById.msPerOp.toStringAsFixed(3)}ms/op)'.padRight(40) + '│');
  print('│ HashIndex equals:    ${_fmt(hashEq.opsPerSec)} ops/s'.padRight(40) + '(${hashEq.msPerOp.toStringAsFixed(3)}ms/op)'.padRight(40) + '│');
  print('│ SortedIndex range:   ${_fmt(sortRange.opsPerSec)} ops/s'.padRight(40) + '(${sortRange.msPerOp.toStringAsFixed(3)}ms/op)'.padRight(40) + '│');
  print('│ BitmaskIndex bool:   ${_fmt(bitmask.opsPerSec)} ops/s'.padRight(40) + '(${bitmask.msPerOp.toStringAsFixed(3)}ms/op)'.padRight(40) + '│');

  final batchSpeedup = (insertBatch.opsPerSec / insertSeq.opsPerSec);
  print('│'.padRight(80) + '│');
  print('│ Batch vs sequential speedup:  ${batchSpeedup.toStringAsFixed(1)}x'.padRight(80) + '│');
  print('└───────────────────────────────────────────────────────────────────────────────┘');

}
