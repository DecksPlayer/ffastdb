import 'dart:io';
import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/io/io_storage_strategy.dart';
import 'package:ffastdb/src/storage/wal_storage_strategy.dart';
import 'package:test/test.dart';

void main() {
  group('JSON Bug Repro Tests', () {
    test('insert and retrieve a JSON document', () async {
      await FfastDb.disposeInstance();
      final dir = Directory.systemTemp.createTempSync('fastdb_bug_repro_');
      final dbPath = '${dir.path}/bug.fdb';

      try {
        final db = await FfastDb.init(
          WalStorageStrategy(
            main: IoStorageStrategy(dbPath),
            wal: IoStorageStrategy('$dbPath.wal'),
          ),
        );

        // 1. Insert a JSON document (Map)
        final doc = {'foo': 'bar', 'id_str': '2d2ee1fa-77d2-421f-8cc3-fb33611e48f7'};
        final id = await db.insert(doc);
        print('Inserted document with ID: $id');

        // 2. Try to retrieve it
        final retrieved = await db.findById(id);
        print('Retrieved: $retrieved');
        
        expect(retrieved, isNotNull);
        expect(retrieved, isA<Map>());
        expect(retrieved['foo'], equals('bar'));
        expect(retrieved['id_str'], equals('2d2ee1fa-77d2-421f-8cc3-fb33611e48f7'));

        await FfastDb.disposeInstance();
      } finally {
        if (Directory(dir.path).existsSync()) {
          dir.deleteSync(recursive: true);
        }
      }
    });
  });
}

