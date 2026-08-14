import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';

void main() async {
  print('Inserting 100,000 docs via insertAll in memory...');
  final db = FastDB(MemoryStorageStrategy());
  await db.open();

  final docs = List.generate(
    100000,
    (i) => {'id_num': i, 'text': 'Doc $i'},
  );

  final ids = await db.insertAll(docs);
  print('insertAll returned ${ids.length} IDs (first: ${ids.first}, last: ${ids.last})');

  final count = await db.count();
  print('db.count() = $count');

  final allDocs = await db.getAll();
  print('db.getAll() returned ${allDocs.length} documents');

  if (allDocs.length != 100000) {
    print('❌ DATA LOSS DETECTED! Expected 100000 docs, got ${allDocs.length}');
  } else {
    print('✅ SUCCESS! All 100000 docs intact.');
  }

  await db.close();
}
