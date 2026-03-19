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
    final retrievedUser = await db.get(1);
    print('Retrieved: $retrievedUser');
    
    if (retrievedUser is User && retrievedUser.name == user.name) {
      print('SUCCESS: Byte-perfect Hive-like retrieval!');
    } else {
      print('FAILURE: Retrieved object is not what we expected: ${retrievedUser.runtimeType}');
    }
    
    // 4. Test legacy JSON still works
    final jsonId = await db.insert({'type': 'legacy', 'compatible': true});
    final retrievedJson = await db.get(jsonId);
    print('Retrieved JSON: $retrievedJson');
    
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
