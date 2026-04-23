import 'dart:io';
import 'package:ffastdb/ffastdb.dart';

void main() async {
  final dir = Directory.systemTemp.createTempSync('fastdb_stress_');
  final dbPath = '${dir.path}/stress.fdb';
  final db = FastDB(IoStorageStrategy(dbPath));
  await db.open();

  print('Database opened at $dbPath. Starting stress test...');
  
  // Set up 10 watchers
  final watchers = <Stream>[];
  for (int i = 0; i < 10; i++) {
    // Watchers in FastDB use field names as keys
    watchers.add(db.watch('category'));
  }

  int notificationCount = 0;
  for (var stream in watchers) {
    stream.listen((_) {
      notificationCount++;
    });
  }

  final docs = List.generate(10000, (i) => {
    'name': 'Doc $i',
    'category': i % 10,
    'tags': ['a', 'b', 'c'],
    'nested': {'foo': 'bar'}
  });

  print('Inserting 10,000 documents...');
  final sw = Stopwatch()..start();
  await db.insertAll(docs);
  sw.stop();
  
  print('Insert finished in ${sw.elapsedMilliseconds}ms');
  
  // Wait a bit for async notifications
  await Future.delayed(Duration(seconds: 2));
  
  print('Total notifications received: $notificationCount');
  print('Expected notifications: 10 (one per watcher at the end of batch)');

  if (notificationCount == 10) {
    print('SUCCESS: Notifications batched correctly.');
  } else {
    print('FAILURE: Notifications not batched. Received: $notificationCount');
  }

  await db.close();
  dir.deleteSync(recursive: true);
}
