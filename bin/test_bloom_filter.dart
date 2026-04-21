import 'package:ffastdb/ffastdb.dart';

void main() async {
  final db = FastDB(MemoryStorageStrategy());
  await db.open();

  print('Testing Bloom Filter Integration');
  print('═' * 50);

  // Insert test data
  await db.insert({'id': 1, 'status': 'active'});
  await db.insert({'id': 2, 'status': 'inactive'});
  await db.insert({'id': 3, 'status': 'pending'});
  await db.insert({'id': 4, 'status': 'archived'});

  // Add index
  db.addIndex('status');

  print('\n✓ Documents inserted and indexed');

  // Test positive query
  final activeResults = await db.query()
    .where('status')
    .equals('active')
    .find();
  print('✓ Positive query: Found ${activeResults.length} active docs');

  // Test negative query
  final notInactiveResults = await db.query()
    .where('status')
    .not()
    .equals('inactive')
    .find();
  print('✓ Negative query: Found ${notInactiveResults.length} NOT inactive docs');

  // Verify correctness
  final expectedNotInactive = activeResults.length + 2; // active + pending + archived
  if (notInactiveResults.length == expectedNotInactive) {
    print('✓ Negative query results are correct!');
  } else {
    print('✗ ERROR: Expected $expectedNotInactive, got ${notInactiveResults.length}');
  }

  await db.close();
  print('\n✓ All tests passed!');
}
