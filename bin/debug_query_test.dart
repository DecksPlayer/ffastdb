import 'package:ffastdb/ffastdb.dart';

void main() async {
  final db = FastDB(MemoryStorageStrategy());
  await db.open();

  print('Testing basic query functionality');
  print('═' * 50);

  // Insert test data
  await db.insert({'id': 1, 'status': 'active'});
  await db.insert({'id': 2, 'status': 'inactive'});
  await db.insert({'id': 3, 'status': 'pending'});

  print('✓ Documents inserted');

  // Test without index first
  print('\nTest 1: Query without index');
  final noIndexResults = await db.query()
    .where('status')
    .equals('active')
    .find();
  print('Found ${noIndexResults.length} results');
  for (final doc in noIndexResults) {
    print('  - ${doc['status']}');
  }

  // Add index and test again
  print('\nTest 2: Adding index...');
  db.addIndex('status');
  print('✓ Index added');

  // Test with index
  print('\nTest 3: Query with index');
  final withIndexResults = await db.query()
    .where('status')
    .equals('active')
    .find();
  print('Found ${withIndexResults.length} results');
  for (final doc in withIndexResults) {
    print('  - ${doc['status']}');
  }

  // Test negative query
  print('\nTest 4: Negative query');
  final negativeResults = await db.query()
    .where('status')
    .not()
    .equals('inactive')
    .find();
  print('Found ${negativeResults.length} NOT inactive');
  for (final doc in negativeResults) {
    print('  - ${doc['status']}');
  }

  await db.close();
}
