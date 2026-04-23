import 'dart:io';
import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/io/io_storage_strategy.dart';
import '../test/user_model.dart';

void main() async {
  print('--- FastDB Hive-like Features Verification ---');
  
  final dbPath = 'hive_test.fdb';
  final storage = IoStorageStrategy(dbPath);
  final db = FastDB(storage);
  
  try {
    await db.open();
    
    // 1. Register Adapter
    db.registerAdapter(UserAdapter());
    print('UserAdapter registered.');
    
    // 2. Test Custom Object (Hive-style put)
    final user = User(name: 'Gono', age: 30, email: 'gono@example.com');
    await db.put(1, user);
    print('Stored: $user');
    
    // 3. Test Retrieval (Hive-style get)
    final retrievedUser = await db.findById(1);
    if (retrievedUser is User) {
      print('✅ Retrieved typed object: ${retrievedUser.name}, age ${retrievedUser.age}');
    } else {
      print('❌ Failed to retrieve typed object.');
    }

    // ── 3. JSON Documents ──────────────────────────────────────────────
    print('\n3. JSON Documents');
    final jsonId = await db.insert({
      'title': 'Hello World',
      'body': 'This is a test document',
      'tags': ['test', 'dart', 'nosql']
    });
    final retrievedJson = await db.findById(jsonId);
    print('✅ Retrieved JSON document: $retrievedJson');
    
  } finally {
    await db.close();
    print('DB Closed.');
    
    final file = File(dbPath);
    if (await file.exists()) {
      await file.delete();
      print('Test DB cleaned up.');
    }
  }
}
