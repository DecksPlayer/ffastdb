import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';

void main() async {
  print('--- FastDB Multi-File Storage Benchmark ---');
  
  // 1. Setup with separate Data Storage
  final metaStorage = MemoryStorageStrategy();
  final dataStorage = MemoryStorageStrategy();
  final db = FastDB(metaStorage, dataStorage: dataStorage);
  await db.open();

  final count = 50000;
  final docs = List.generate(count, (i) => {
    'id': i,
    'name': 'User $i',
    'age': 20 + (i % 50),
    'active': i % 2 == 0,
  });

  print('Goal: Insert $count documents with O(1) append...');
  
  final sw = Stopwatch()..start();
  
  // Use insertAll for batch performance
  await db.insertAll(docs);
  
  sw.stop();
  final ms = sw.elapsedMilliseconds;
  final ops = (count / (ms / 1000)).toStringAsFixed(0);
  
  print('Result: $ms ms ($ops ops/s)');
  
  // Verify data integrity
  final first = await db.findById(1);
  final last = await db.findById(count);
  print('Verification: ID 1: ${first?['name']}, ID $count: ${last?['name']}');

  // DB key 1 → doc with id=0 ('User 0'), DB key count → doc with id=count-1 ('User 49999')
  if (first?['name'] == 'User 0' && last?['name'] == 'User ${count - 1}') {
    print('SUCCESS: Multi-file storage is fully operational.');
  } else {
    print('FAILURE: Data corruption or zero speed. first=${first?['name']}, last=${last?['name']}');
  }

  await db.close();
}
