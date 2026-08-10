import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';

void main() async {
  print('Creating DB with 100,000 docs...');
  final db = FastDB(MemoryStorageStrategy());
  await db.open();

  final docs = List.generate(
    100000,
    (i) => {
      'name': 'User_$i',
      'age': i % 100,
      'city': 'City_${i % 50}',
      'status': i % 2 == 0 ? 'active' : 'inactive',
    },
  );

  final swInsert = Stopwatch()..start();
  await db.insertAll(docs);
  swInsert.stop();
  print('Insert 100k docs took: ${swInsert.elapsedMilliseconds} ms');

  print('Adding SortedIndex on age...');
  db.addSortedIndex('age');
  db.addIndex('city');

  final swReindex = Stopwatch()..start();
  await db.reindex();
  swReindex.stop();
  print('Reindex 100k docs (SortedIndex + HashIndex) took: ${swReindex.elapsedMilliseconds} ms!');

  final countAge = await db.query().where('age').equals(25).count();
  print('Count where age == 25: $countAge');

  await db.close();
  print('DONE');
}
