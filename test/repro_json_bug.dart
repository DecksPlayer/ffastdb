import 'dart:io';
import 'dart:typed_data';
import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/io/io_storage_strategy.dart';
import 'package:ffastdb/src/storage/wal_storage_strategy.dart';

void main() async {
  final dir = Directory.systemTemp.createTempSync('fastdb_bug_repro_');
  final dbPath = '${dir.path}/bug.fdb';
  print('Repro database path: $dbPath');

  try {
    final db = await FfastDb.init(
      WalStorageStrategy(
        main: IoStorageStrategy(dbPath),
        wal: IoStorageStrategy('$dbPath.wal'),
      ),
    );

    // 1. Insert a JSON document (Map)
    // The inner body (from FastSerializer) will be [length(4), '{...}']
    // FastDB._readAt (at line 927) checks body[0] == 123 ({) or 91 ([).
    // But body[0] is the first byte of length!
    final doc = {'foo': 'bar', 'id_str': '2d2ee1fa-77d2-421f-8cc3-fb33611e48f7'};
    final id = await db.insert(doc);
    print('Inserted document with ID: $id');

    // 2. Try to retrieve it
    try {
      final retrieved = await db.findById(id);
      print('Retrieved: $retrieved');
      if (retrieved == null) {
        print('BUG CONFIRMED: findById returned null for a valid JSON document');
      } else if (retrieved is Map) {
         print('SUCCESS: Correctly retrieved as Map');
      } else {
         print('UNEXPECTED: Retrieved as ${retrieved.runtimeType}: $retrieved');
      }
    } catch (e) {
      print('BUG CONFIRMED: findById threw an error: $e');
    }

    await FfastDb.disposeInstance();
  } finally {
    if (Directory(dir.path).existsSync()) {
      dir.deleteSync(recursive: true);
    }
  }
}
