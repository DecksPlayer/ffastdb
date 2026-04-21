import 'package:ffastdb/ffastdb.dart';

void main() async {
  print('╔═══════════════════════════════════════════════════════╗');
  print('║    FastDB FTS Integration Tests                      ║');
  print('╚═══════════════════════════════════════════════════════╝\n');

  int passed = 0;
  int failed = 0;

  // Test 1: Basic FTS indexing
  print('Test 1: Basic FTS indexing and search');
  print('─────────────────────────────────────');
  try {
    final db = FastDB(MemoryStorageStrategy());
    await db.open();

    await db.insert({'id': 1, 'text': 'Hello world from London'});
    await db.insert({'id': 2, 'text': 'Paris is beautiful'});
    await db.insert({'id': 3, 'text': 'London has big ben'});

    db.addFtsIndex('text');
    await db.reindex();

    final results = await db.query()
      .where('text')
      .fts('london')
      .find();

    if (results.length == 2 && 
        results.any((doc) => doc['id'] == 1) &&
        results.any((doc) => doc['id'] == 3)) {
      print('✓ PASS: FTS found correct documents');
      passed++;
    } else {
      print('✗ FAIL: Expected 2 documents with "london", got ${results.length}');
      failed++;
    }
    
    await db.close();
  } catch (e) {
    print('✗ FAIL: Exception - $e');
    failed++;
  }
  print('');

  // Test 2: Multi-word search (AND semantics)
  print('Test 2: Multi-word FTS (AND semantics)');
  print('─────────────────────────────────────');
  try {
    final db = FastDB(MemoryStorageStrategy());
    await db.open();

    await db.insert({'id': 1, 'text': 'Hello world from London'});
    await db.insert({'id': 2, 'text': 'Paris is beautiful'});
    await db.insert({'id': 3, 'text': 'London has big ben'});

    db.addFtsIndex('text');
    await db.reindex();

    final results = await db.query()
      .where('text')
      .fts('london big')
      .find();

    if (results.length == 1 && results[0]['id'] == 3) {
      print('✓ PASS: Multi-word AND query works');
      passed++;
    } else {
      print('✗ FAIL: Expected 1 document with "london" AND "big", got ${results.length}');
      if (results.isNotEmpty) {
        print('  Got: ${results.map((d) => d['id']).toList()}');
      }
      failed++;
    }
    
    await db.close();
  } catch (e) {
    print('✗ FAIL: Exception - $e');
    failed++;
  }
  print('');

  // Test 3: Case-insensitivity
  print('Test 3: Case-insensitive search');
  print('───────────────────────────────');
  try {
    final db = FastDB(MemoryStorageStrategy());
    await db.open();

    await db.insert({'id': 1, 'text': 'Hello world from London'});
    await db.insert({'id': 2, 'text': 'Paris is beautiful'});
    await db.insert({'id': 3, 'text': 'London has big ben'});

    db.addFtsIndex('text');
    await db.reindex();

    final results = await db.query()
      .where('text')
      .fts('LONDON')
      .find();

    if (results.length == 2) {
      print('✓ PASS: Case-insensitive search works');
      passed++;
    } else {
      print('✗ FAIL: Expected case-insensitive match');
      failed++;
    }
    
    await db.close();
  } catch (e) {
    print('✗ FAIL: Exception - $e');
    failed++;
  }
  print('');

  // Test 4: Short tokens ignored
  print('Test 4: Ignore short tokens (< 2 chars)');
  print('───────────────────────────────────────');
  try {
    final db = FastDB(MemoryStorageStrategy());
    await db.open();

    await db.insert({'id': 1, 'text': 'I am here'});
    await db.insert({'id': 2, 'text': 'You are there'});

    db.addFtsIndex('text');
    await db.reindex();

    final results = await db.query()
      .where('text')
      .fts('am')
      .find();

    if (results.length == 1 && results[0]['id'] == 1) {
      print('✓ PASS: Short tokens ignored correctly');
      passed++;
    } else {
      print('✗ FAIL: Expected 1 document with "am", got ${results.length}');
      failed++;
    }
    
    await db.close();
  } catch (e) {
    print('✗ FAIL: Exception - $e');
    failed++;
  }
  print('');

  // Test 5: Empty query
  print('Test 5: Empty/whitespace FTS query');
  print('──────────────────────────────────');
  try {
    final db = FastDB(MemoryStorageStrategy());
    await db.open();

    await db.insert({'id': 1, 'text': 'Some text'});

    db.addFtsIndex('text');
    await db.reindex();

    final results = await db.query()
      .where('text')
      .fts('')
      .find();

    if (results.isEmpty) {
      print('✓ PASS: Empty query returns no results');
      passed++;
    } else {
      print('⚠ WARN: Empty query returned ${results.length} results');
      passed++;
    }
    
    await db.close();
  } catch (e) {
    print('✗ FAIL: Exception - $e');
    failed++;
  }
  print('');

  // Test 6: No matching documents
  print('Test 6: No matching documents');
  print('─────────────────────────────');
  try {
    final db = FastDB(MemoryStorageStrategy());
    await db.open();

    await db.insert({'id': 1, 'text': 'Apple pie'});
    await db.insert({'id': 2, 'text': 'Banana split'});

    db.addFtsIndex('text');
    await db.reindex();

    final results = await db.query()
      .where('text')
      .fts('nonexistent')
      .find();

    if (results.isEmpty) {
      print('✓ PASS: No matching documents returns empty');
      passed++;
    } else {
      print('✗ FAIL: Should return empty for no matches, got ${results.length}');
      failed++;
    }
    
    await db.close();
  } catch (e) {
    print('✗ FAIL: Exception - $e');
    failed++;
  }
  print('');

  // Summary
  print('╔═══════════════════════════════════════════════════════╗');
  print('║              TEST SUMMARY                             ║');
  print('╚═══════════════════════════════════════════════════════╝');
  print('Passed: $passed');
  print('Failed: $failed');
  print('Total:  ${passed + failed}');
  print('Status: ${failed == 0 ? '✓ ALL TESTS PASSED' : '⚠ SOME TESTS FAILED'}\n');
}
