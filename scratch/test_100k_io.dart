import 'dart:io';
import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/io/io_storage_strategy.dart';
import 'package:ffastdb/src/storage/wal_storage_strategy.dart';

void main() async {
  final tempDir = Directory.systemTemp.createTempSync('fastdb_100k_test');
  final dbPath = '${tempDir.path}/test_100k.fdb';
  print('Testing IoStorageStrategy at $dbPath...');

  final io = IoStorageStrategy(dbPath);
  final db = FastDB(io);
  await db.open();

  final docs = List.generate(
    100000,
    (i) => {'id_num': i, 'text': 'Doc $i'},
  );

  print('Calling insertAll(100k)...');
  final ids = await db.insertAll(docs);
  print('insertAll returned ${ids.length} IDs');

  final countBeforeClose = await db.count();
  print('Count before close: $countBeforeClose');

  await db.close();

  print('Reopening DB to test persistence and index load...');
  final io2 = IoStorageStrategy(dbPath);
  final db2 = FastDB(io2);
  await db2.open();

  final countAfterReopen = await db2.count();
  print('Count after reopen: $countAfterReopen');

  final allDocs = await db2.getAll();
  print('getAll() returned ${allDocs.length} documents');

  if (allDocs.length != 100000) {
    print('❌ DATA LOSS DETECTED ON DISK! Expected 100000 docs, got ${allDocs.length}');
  } else {
    print('✅ SUCCESS! All 100000 docs intact on disk.');
  }

  await db2.close();
  tempDir.deleteSync(recursive: true);
}
