import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';

void main() async {
  final db = FastDB(MemoryStorageStrategy());
  await db.open();
  
  final ids = await db.insertAll([
    for (int i = 0; i < 5; i++) {'name': 'User_$i', 'score': i},
  ]);
  print('Inserted IDs: $ids');
  
  for (int i = 0; i < 2; i++) await db.delete(ids[i]);
  
  print('Before compact:');
  for (final id in ids) {
    final doc = await db.findById(id);
    print('  ID $id = ${doc?["name"]}');
  }
  
  await db.compact();
  
  print('After compact:');
  for (final id in ids) {
    final doc = await db.findById(id);
    print('  ID $id = ${doc?["name"]}');
  }
}
