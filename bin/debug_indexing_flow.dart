import 'package:ffastdb/ffastdb.dart';

void main() async {
  final db = FastDB(MemoryStorageStrategy());
  await db.open();

  print('=== Debugging FTS Indexing Flow ===\n');

  // Create FTS index
  db.addFtsIndex('text');
  print('1. FTS index created with key "_fts_text"');
  
  // Check if index exists
  final hasIndex = (db as dynamic)._secondaryIndexes.containsKey('_fts_text');
  print('2. FTS index exists in _secondaryIndexes: $hasIndex\n');

  // Insert first document
  print('3. Inserting document 1...');
  await db.insert({'id': 1, 'text': 'Hello world from London'});
  
  // Check index size after first insert
  final idx1 = (db as dynamic)._secondaryIndexes['_fts_text'];
  final size1 = idx1 != null ? idx1.size : 0;
  print('   After insert, FTS index size: $size1');
  
  var results = await db.query().where('text').fts('hello').find();
  print('   Search fts("hello"): ${results.map((d) => d['id']).toList()}\n');

  // Insert second document  
  print('4. Inserting document 2...');
  await db.insert({'id': 2, 'text': 'Paris is beautiful'});
  
  // Check if same FtsIndex instance
  final idx2 = (db as dynamic)._secondaryIndexes['_fts_text'];
  final isSameInstance = identical(idx1, idx2);
  print('   Same FtsIndex instance: $isSameInstance');
  
  final size2 = idx2.size;
  print('   After insert, FTS index size: $size2');
  
  results = await db.query().where('text').fts('paris').find();
  print('   Search fts("paris"): ${results.map((d) => d['id']).toList()}\n');

  // Try to check what's in the index
  if (idx2 != null && idx2.runtimeType.toString().contains('FtsIndex')) {
    print('5. FtsIndex details:');
    try {
      final allDocs = idx2.all();
      print('   All indexed document IDs: $allDocs');
    } catch (e) {
      print('   Error getting all docs: $e');
    }
  }

  await db.close();
  print('\nDone.');
}
