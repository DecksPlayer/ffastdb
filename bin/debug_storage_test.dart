import 'package:ffastdb/ffastdb.dart';

void main() async {
  final db = FastDB(MemoryStorageStrategy());
  await db.open();

  print('Testing document storage');
  print('═' * 50);

  // Insert test data
  final id1 = await db.insert({'id': 1, 'status': 'active'});
  final id2 = await db.insert({'id': 2, 'status': 'inactive'});
  final id3 = await db.insert({'id': 3, 'status': 'pending'});

  print('✓ Documents inserted');
  print('  ID 1: $id1');
  print('  ID 2: $id2');
  print('  ID 3: $id3');

  // Try to retrieve by ID
  print('\nTest 1: Retrieve by ID');
  final doc1 = await db.get(id1);
  print('Doc 1: $doc1');

  // Try to scan all documents
  print('\nTest 2: Scan all documents');
  final allDocs = await db.query().find();
  print('Total docs: ${allDocs.length}');
  for (final doc in allDocs) {
    print('  - $doc');
  }

  // Try where('status').alwaysTrue()
  print('\nTest 3: Query with alwaysTrue()');
  final allViaQuery = await db.query()
    .where('status')
    .alwaysTrue()
    .find();
  print('Total via query: ${allViaQuery.length}');
  for (final doc in allViaQuery) {
    print('  - $doc');
  }

  await db.close();
}
