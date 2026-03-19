import 'dart:async';
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

class OpsSecEmitter implements ScoreEmitter {
  final int opsPerRun;
  
  const OpsSecEmitter(this.opsPerRun);

  @override
  void emit(String testName, double value) {
    globalResults.add(BenchResult(testName, opsPerRun, value));
  }
}

// ─── Document Generator ───────────────────────────────────────────────────

List<Map<String, dynamic>> _generateDocs(int n) {
  return List.generate(n, (i) => {
    'name': 'User_$i',
    'age': 20 + (i % 60),
    'city': ['London', 'Paris', 'Tokyo', 'NYC', 'Berlin'][i % 5],
    'active': i % 3 != 0,
    'score': i * 1.5,
  });
}

// ─── 1. Sequential Insert 1 Million ────────────────────────────────────────

class SequentialInsert1MBench extends AsyncBenchmarkBase {
  static const int N = 1000000;
  SequentialInsert1MBench() : super('Sequential insert (1M docs)', emitter: const OpsSecEmitter(N));

  late List<Map<String, dynamic>> docs;

  @override
  Future<void> setup() async {
    docs = _generateDocs(N);
  }

  @override
  Future<void> run() async {
    final db = FastDB(MemoryStorageStrategy());
    await db.open();
    for (int i = 0; i < N; i++) {
        await db.insert({
          'name': docs[i]['name'],
          'age': docs[i]['age'],
          'city': docs[i]['city'],
        });
    }
    await db.close();
  }
}

// ─── 2. Batch Insert 1 Million ─────────────────────────────────────────────

class BatchInsert1MBench extends AsyncBenchmarkBase {
  static const int N = 1000000;
  BatchInsert1MBench() : super('Batch insert (1M docs)', emitter: const OpsSecEmitter(N));

  late List<Map<String, dynamic>> docs;

  @override
  Future<void> setup() async {
    docs = _generateDocs(N);
  }

  @override
  Future<void> run() async {
    final db = FastDB(MemoryStorageStrategy());
    await db.open();
    await db.insertAll(docs);
    await db.close();
  }
}

// ─── 3. Primary Key Lookup (1M docs) ──────────────────────────────────────

class FindById1MBench extends AsyncBenchmarkBase {
  static const int N = 1000000;
  static const int READS = 50000;
  FindById1MBench() : super('findById 50k reads (DB size: 1M)', emitter: const OpsSecEmitter(READS));

  late FastDB db;

  @override
  Future<void> setup() async {
    db = FastDB(MemoryStorageStrategy());
    await db.open();
    await db.insertAll(_generateDocs(N));
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

// ─── 4. HashIndex equality lookup (1M docs) ───────────────────────────────

class HashIndex1MBench extends AsyncBenchmarkBase {
  static const int N = 1000000;
  static const int QUERIES = 20000;
  HashIndex1MBench() : super('HashIndex query 20k queries (DB size: 1M)', emitter: const OpsSecEmitter(QUERIES));

  late FastDB db;
  late List<String> cities;

  @override
  Future<void> setup() async {
    db = FastDB(MemoryStorageStrategy());
    db.addIndex('city');
    await db.open();
    await db.insertAll(_generateDocs(N));
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

// ─── 5. SortedIndex range query (1M docs) ─────────────────────────────────

class SortedIndexRange1MBench extends AsyncBenchmarkBase {
  static const int N = 1000000;
  static const int QUERIES = 10000;
  SortedIndexRange1MBench() : super('SortedIndex range 10k queries (DB size: 1M)', emitter: const OpsSecEmitter(QUERIES));

  late FastDB db;

  @override
  Future<void> setup() async {
    db = FastDB(MemoryStorageStrategy());
    db.addSortedIndex('age');
    await db.open();
    await db.insertAll(_generateDocs(N));
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

// ─── Main ─────────────────────────────────────────────────────────────────

Future<void> main() async {
  print('');
  print('╔══════════════════════════════════════════════════════════════════════════════════╗');
  print('║              FastDB — 1 MILLION Documents Performance Benchmark                 ║');
  print('║              Platform: Dart VM  │  In-Memory Storage  │  2026                   ║');
  print('╚══════════════════════════════════════════════════════════════════════════════════╝');
  print('');
  print('Running benchmarks... This may take a minute or two.\n');

  // We skip Sequential Insert initially if the user wants quick results, 
  // but let's run it anyway, they asked for 1M tests!
  await BatchInsert1MBench().report();
  await SequentialInsert1MBench().report();
  await FindById1MBench().report();
  await HashIndex1MBench().report();
  await SortedIndexRange1MBench().report();

  print('');
  print('Benchmark                                          │  ops/sec   │   ms/op');
  print('─' * 85);
  for (final r in globalResults) {
    print(r);
  }
  print('─' * 85);
  print('');
}
