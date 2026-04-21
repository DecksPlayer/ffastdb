import 'package:ffastdb/ffastdb.dart';

void main() async {
  final db = FastDB(MemoryStorageStrategy());
  await db.open();

  print('=== Debug FTS with Query Builder ===\n');

  // Insert test documents
  await db.insert({'id': 1, 'text': 'Hello world from London'});
  await db.insert({'id': 2, 'text': 'Paris is beautiful'});
  await db.insert({'id': 3, 'text': 'London has big ben'});

  // Create FTS index
  db.addFtsIndex('text');
  await db.reindex();

  // Test without FTS (plain contains)
  print('Test 1: Without FTS index, using contains():');
  var results = await db.query()
    .where('text')
    .contains('big')
    .find();
  print('Search with contains("big"): ${results.map((d) => d['id']).toList()}');
  print('');

  // Now test with FTS
  print('Test 2: With FTS index, using fts():');
  var query = db.query().where('text');
  print('Query created');
  
  var qWithFts = query.fts('big');
  print('FTS condition added');
  
  results = await qWithFts.find();
  print('Search with fts("big"): ${results.map((d) => d['id']).toList()}');
  print('Expected: [3]');
  print('');

  // Test with simple FTS
  print('Test 3: Simple FTS search:');
  results = await db.query().where('text').fts('london').find();
  print('Search fts("london"): ${results.map((d) => d['id']).toList()}');
  print('Expected: [1, 3]');

  await db.close();
}
