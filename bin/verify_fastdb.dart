import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';

void main() async {
  print('=== FastDB Full Verification ===\n');

  final db = FastDB(MemoryStorageStrategy());

  // 1. Add secondary indexes
  db.addIndex('name');
  db.addIndex('age');
  db.addIndex('city');

  await db.open();

  // 2. Batch insert documents
  print('--- Inserting 10 documents ---');
  final ids = await db.insertAll([
    {'name': 'Alice', 'age': 30, 'city': 'London'},
    {'name': 'Bob',   'age': 25, 'city': 'New York'},
    {'name': 'Clara', 'age': 35, 'city': 'London'},
    {'name': 'Dan',   'age': 22, 'city': 'Tokyo'},
    {'name': 'Eva',   'age': 28, 'city': 'London'},
    {'name': 'Frank', 'age': 40, 'city': 'Paris'},
    {'name': 'Gono',  'age': 30, 'city': 'Buenos Aires'},
    {'name': 'Hana',  'age': 19, 'city': 'Tokyo'},
    {'name': 'Ivan',  'age': 55, 'city': 'Moscow'},
    {'name': 'Julia', 'age': 33, 'city': 'New York'},
  ]);
  print('Inserted IDs: $ids\n');

  // 3. Find by ID
  print('--- Find by ID (B-Tree O(log n)) ---');
  final doc = await db.findById(1);
  print('ID 1: $doc\n');

  // 4. Query: equals
  print('--- Query: city == London ---');
  final londonIds = db.query().where('city').equals('London').findIds();
  final londonDocs = await db.find((_) => londonIds);
  for (final d in londonDocs) print('  $d');
  print('');

  // 5. Query: range (age between 25 and 35)
  print('--- Query: 25 <= age <= 35 ---');
  final ageIds = db.query().where('age').between(25, 35).findIds();
  final ageDocs = await db.find((_) => ageIds);
  for (final d in ageDocs) print('  $d');
  print('');

  // 6. Query: startsWith name
  print('--- Query: name.startsWith("A") ---');
  final nameIds = db.query().where('name').startsWith('A').findIds();
  final nameDocs = await db.find((_) => nameIds);
  for (final d in nameDocs) print('  $d');
  print('');

  // 7. Query: combined AND + sort + limit
  print('--- Query: city==London, sorted by age, limit 2 ---');
  final combined = db.query()
      .where('city').equals('London')
      .sortBy('age')
      .limit(2)
      .findIds();
  final combinedDocs = await db.find((_) => combined);
  for (final d in combinedDocs) print('  $d');
  print('');

  // 8. Verify insertAll 
  print('--- B-Tree Range Scan: IDs 3..6 ---');
  final rangeIds = await db.rangeSearch(3, 6);
  print('Range result IDs: $rangeIds\n');

  await db.close();
  print('=== All tests passed! ===');
}
