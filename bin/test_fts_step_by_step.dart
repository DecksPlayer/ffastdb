import 'package:ffastdb/ffastdb.dart';

void main() async {
  final db = FastDB(MemoryStorageStrategy());
  await db.open();

  print('=== Step-by-step FTS Indexing ===\n');

  // Create FTS index FIRST
  db.addFtsIndex('text');
  print('Step 1: FTS index created for field "text"\n');

  // Insert first document
  await db.insert({'id': 1, 'text': 'Hello world from London'});
  print('Step 2: Inserted document 1');
  var results = await db.query().where('text').fts('hello').find();
  print('  Search fts("hello"): ${results.map((d) => d['id']).toList()} (expect [1])');
  print('');

  // Insert second document
  await db.insert({'id': 2, 'text': 'Paris is beautiful'});
  print('Step 3: Inserted document 2');
  results = await db.query().where('text').fts('paris').find();
  print('  Search fts("paris"): ${results.map((d) => d['id']).toList()} (expect [2])');
  print('');

  // Insert third document
  await db.insert({'id': 3, 'text': 'London has big ben'});
  print('Step 4: Inserted document 3');
  results = await db.query().where('text').fts('london').find();
  print('  Search fts("london"): ${results.map((d) => d['id']).toList()} (expect [1, 3])');
  print('');

  // Check each document
  print('Final verification:');
  results = await db.query().where('text').fts('hello').find();
  print('  fts("hello"): ${results.map((d) => d['id']).toList()} (expect [1])');

  results = await db.query().where('text').fts('paris').find();
  print('  fts("paris"): ${results.map((d) => d['id']).toList()} (expect [2])');

  results = await db.query().where('text').fts('big').find();
  print('  fts("big"): ${results.map((d) => d['id']).toList()} (expect [3])');

  results = await db.query().where('text').fts('london').find();
  print('  fts("london"): ${results.map((d) => d['id']).toList()} (expect [1, 3])');

  await db.close();
}
