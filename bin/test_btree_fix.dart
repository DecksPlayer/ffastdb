import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';

void main() async {
  print('=== BTree bulkLoad Fix Test ===');

  final metaStorage = MemoryStorageStrategy();
  final dataStorage = MemoryStorageStrategy();
  final db = FastDB(metaStorage, dataStorage: dataStorage);
  await db.open();

  const count = 50000;
  final docs = List.generate(count, (i) => {
    'id': i,
    'name': 'User $i',
  });

  print('Inserting $count documents...');
  await db.insertAll(docs);
  print('Insert done.');

  // Test a few lookups
  for (final id in [1, 2, 100, 1000, 25000, 49999, 50000]) {
    final doc = await db.findById(id);
    if (doc == null) {
      print('FAIL: ID $id returned null');
    } else {
      print('OK: ID $id → ${doc['name']}');
    }
  }

  await db.close();
  print('=== Test Complete ===');
}
