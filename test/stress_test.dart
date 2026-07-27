import 'dart:io';
import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

void main() {
  group('Stress Test', () {
    test('insert 10,000 documents and verify notification batching', () async {
      final dir = Directory.systemTemp.createTempSync('fastdb_stress_');
      final dbPath = '${dir.path}/stress.fdb';
      final db = FastDB(IoStorageStrategy(dbPath));
      await db.open();

      print('Database opened at $dbPath. Starting stress test...');
      
      // Set up 10 watchers
      final watchers = <Stream>[];
      for (int i = 0; i < 10; i++) {
        watchers.add(db.watch('category'));
      }

      int notificationCount = 0;
      final subscriptions = <dynamic>[];
      for (var stream in watchers) {
        // Skip the initial event (immediate yield of current state)
        // so we only count subsequent updates.
        subscriptions.add(stream.skip(1).listen((_) {
          notificationCount++;
        }));
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
      
      print('Total notifications received (excluding initial): $notificationCount');
      expect(notificationCount, equals(10), reason: 'Expected exactly 1 update notification per watcher at the end of batch');

      for (final sub in subscriptions) {
        await sub.cancel();
      }
      await db.close();
      dir.deleteSync(recursive: true);
    });
  });
}

