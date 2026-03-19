import 'package:benchmark_harness/benchmark_harness.dart';
import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';
import 'package:ffastdb/src/storage/buffered_storage_strategy.dart';

final _cities = ['London', 'New York', 'Tokyo', 'Paris', 'Buenos Aires', 'Sydney'];

List<Map<String, dynamic>> _makeDocs(int n) => [
      for (int i = 0; i < n; i++)
        {
          'name': 'User_$i',
          'age': 18 + (i % 60),
          'city': _cities[i % _cities.length]
        },
    ];

/// Measures the time it takes to insert 5,000 documents one-by-one
class RegularInsertBenchmark extends AsyncBenchmarkBase {
  RegularInsertBenchmark() : super('RegularInsert');

  late List<Map<String, dynamic>> docs;

  @override
  Future<void> setup() async {
    docs = _makeDocs(5000);
  }

  @override
  Future<void> run() async {
    final db = FastDB(MemoryStorageStrategy(), cacheCapacity: 256);
    db.addIndex('city');
    await db.open();
    for (final doc in docs) {
      await db.insert(doc);
    }
    await db.close();
  }
}

/// Measures the time it takes to insert 5,000 documents in a single batch
class BatchInsertBenchmark extends AsyncBenchmarkBase {
  BatchInsertBenchmark() : super('BatchInsert');

  late List<Map<String, dynamic>> docs;

  @override
  Future<void> setup() async {
    docs = _makeDocs(5000);
  }

  @override
  Future<void> run() async {
    final db = FastDB(MemoryStorageStrategy(), cacheCapacity: 256);
    db.addIndex('city');
    await db.open();
    await db.insertAll(docs);
    await db.close();
  }
}

/// Measures the time it takes to insert 5,000 documents in a batch using buffered strategy
class BufferedInsertBenchmark extends AsyncBenchmarkBase {
  BufferedInsertBenchmark() : super('BufferedInsert');

  late List<Map<String, dynamic>> docs;

  @override
  Future<void> setup() async {
    docs = _makeDocs(5000);
  }

  @override
  Future<void> run() async {
    final inner = MemoryStorageStrategy();
    final buffered = BufferedStorageStrategy(inner, maxPendingBytes: 512 * 1024);
    final db = FastDB(buffered, cacheCapacity: 256);
    db.addIndex('city');
    await db.open();
    await db.insertAll(docs);
    await db.close();
  }
}

Future<void> main() async {
  print('=== FastDB Benchmarks (5,000 docs) ===\n');
  
  await RegularInsertBenchmark().report();
  await BatchInsertBenchmark().report();
  await BufferedInsertBenchmark().report();

  print('\n=== DONE ===');
}
