import 'package:ffastdb/ffastdb.dart';

void main() async {
  final db = FastDB(MemoryStorageStrategy());
  await db.open();

  print('=== FTS Test: Insert AFTER index creation ===\n');

  // Create FTS index FIRST
  db.addFtsIndex('text');
  
  // Then insert documents
  await db.insert({'id': 1, 'text': 'Hello world from London'});
  await db.insert({'id': 2, 'text': 'Paris is beautiful'});
  await db.insert({'id': 3, 'text': 'London has big ben'});

  print('Documents inserted after FTS index was created');
  print('');

  // Test searches
  var results = await db.query().where('text').fts('london').find();
  print('Search fts("london"): ${results.map((d) => d['id']).toList()}');
  print('Expected: [1, 3]');
  print('');

  results = await db.query().where('text').fts('big').find();
  print('Search fts("big"): ${results.map((d) => d['id']).toList()}');
  print('Expected: [3]');
  print('');

  results = await db.query().where('text').fts('london big').find();
  print('Search fts("london big"): ${results.map((d) => d['id']).toList()}');
  print('Expected: [3]');
  print('');

  await db.close();
}
