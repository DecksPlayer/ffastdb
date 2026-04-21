import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/index/fts_index.dart';

void main() async {
  final db = FastDB(MemoryStorageStrategy());
  await db.open();

  print('=== Direct Inspection of FtsIndex ===\n');

  // Create FTS index FIRST
  db.addFtsIndex('text');
  
  // Then insert documents
  await db.insert({'id': 1, 'text': 'Hello world from London'});
  await db.insert({'id': 2, 'text': 'Paris is beautiful'});
  await db.insert({'id': 3, 'text': 'London has big ben'});

  // Get the FtsIndex directly
  // We'll use a workaround to access it
  print('Checking what was indexed...');
  print('');

  // Test by searching
  print('Search results via query():');
  var results = await db.query().where('text').fts('big').find();
  print('fts("big"): ${results.map((d) => d['id']).toList()}');
  print('Expected: [3]');
  print('');

  results = await db.query().where('text').fts('london').find();
  print('fts("london"): ${results.map((d) => d['id']).toList()}');
  print('Expected: [1, 3]');
  print('');

  results = await db.query().where('text').fts('hello').find();
  print('fts("hello"): ${results.map((d) => d['id']).toList()}');
  print('Expected: [1]');
  print('');

  await db.close();
}
