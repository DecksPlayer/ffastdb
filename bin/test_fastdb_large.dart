import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';

void main() async {
  print('=== FastDB bulkLoad Large Test ===');

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

  int failures = 0;
  for (final id in [1, 2, 100, 1000, 10000, 25000, 49999, 50000]) {
    try {
      final doc = await db.findById(id);
      if (doc == null) {
        print('FAIL: ID $id returned null');
        failures++;
      } else {
        final expected = 'User ${id - 1}';
        if (doc['name'] == expected) {
          print('OK: ID $id → ${doc['name']}');
        } else {
          print('FAIL: ID $id → ${doc['name']} (expected $expected)');
          failures++;
        }
      }
    } catch (e) {
      print('ERROR: ID $id → $e');
      failures++;
    }
  }

  if (failures == 0) print('ALL PASSED');
  else print('$failures FAILED');

  await db.close();
}
