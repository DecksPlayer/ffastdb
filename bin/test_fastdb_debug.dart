import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';

void main() async {
  print('=== FastDB bulkLoad Debug Test (SMALL) ===');

  // Use SMALL count to diagnose
  final metaStorage = MemoryStorageStrategy();
  final dataStorage = MemoryStorageStrategy();
  final db = FastDB(metaStorage, dataStorage: dataStorage);
  await db.open();

  // After open, print page 0 header bytes
  final p0 = await metaStorage.read(0, 8);
  print('Page0 bytes[0..7]: ${p0.map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');

  const count = 500; // small count first
  final docs = List.generate(count, (i) => {
    'id': i,
    'name': 'User $i',
  });

  print('Inserting $count documents...');
  await db.insertAll(docs);
  print('Insert done. Testing lookups...');

  int failures = 0;
  for (final id in [1, 2, 10, 100, 499, 500]) {
    try {
      final doc = await db.findById(id);
      if (doc == null) {
        print('FAIL: ID $id returned null');
        failures++;
      } else {
        print('OK: ID $id → ${doc['name']}');
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
