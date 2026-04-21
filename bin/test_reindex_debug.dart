import 'package:ffastdb/ffastdb.dart';

void main() async {
  print('=== Reindex Debug Test ===');
  
  final db = FastDB(MemoryStorageStrategy());
  await db.open();
  
  print('Inserting 3 documents...');
  final ids = await db.insertAll([
    {'name': 'Alice', 'city': 'London'},
    {'name': 'Bob',   'city': 'Paris'},
    {'name': 'Carol', 'city': 'London'},
  ]);
  
  print('Inserted IDs: $ids');
  print('Total documents: ${await db.count()}');
  
  // Verify all documents exist
  final allDocs = await db.getAll();
  print('All documents:');
  for (final doc in allDocs) {
    print('  ${doc['name']}: city=${doc['city']}');
  }
  
  // Add index AFTER data exists
  print('\nAdding index on "city"...');
  db.addIndex('city');
  print('  Index empty before reindex: ${db.query().where('city').equals('London').findIds()}');
  
  // Try to manually reindex by simulating what reindex() does
  print('\nManually testing the reindex process...');
  
  // Get count
  final totalCount = await db.count();
  print('  Total count: $totalCount');
  
  // Get all docs to verify data exists
  final docs = await db.getAll();
  print('  Found ${docs.length} docs via getAll()');
  for (final doc in docs) {
    print('    - ${doc['name']}: city=${doc['city']}');
  }
  
  // Now try the actual reindex
  print('\nCalling reindex("city")...');
  try {
    await db.reindex('city');
    print('  reindex() completed successfully');
  } catch (e) {
    print('  ERROR during reindex(): $e');
  }
  
  print('After reindex:');
  final londonIds = db.query().where('city').equals('London').findIds();
  print('  Query for city=London: $londonIds');
  print('  Count: ${londonIds.length}');
  
  // Try ParisQuery too
  final parisIds = db.query().where('city').equals('Paris').findIds();
  print('  Query for city=Paris: $parisIds');
  print('  Count: ${parisIds.length}');
  
  await db.close();
}


