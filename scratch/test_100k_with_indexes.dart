import 'dart:io';
import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/io/io_storage_strategy.dart';

void main() async {
  final tempDir = Directory.systemTemp.createTempSync('fastdb_100k_idx_test');
  final dbPath = '${tempDir.path}/test_100k_idx.fdb';
  print('Testing IoStorageStrategy WITH SECONDARY INDEXES at $dbPath...');

  final io = IoStorageStrategy(dbPath);
  final db = FastDB(io);
  db.addIndex('status');
  db.addSortedIndex('id_num');
  await db.open();

  final docs = List.generate(
    100000,
    (i) => {'id_num': i, 'status': i % 2 == 0 ? 'active' : 'inactive', 'text': 'Doc $i'},
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
  db2.addIndex('status');
  db2.addSortedIndex('id_num');
  await db2.open();

  final countAfterReopen = await db2.count();
  print('Count after reopen: $countAfterReopen');

  final activeDocs = await db2.query().where('status').equals('active').find();
  print('Query status == active returned ${activeDocs.length} documents (expected 50000)');

  final sortedDocs = await db2.query().where('id_num').between(0, 100).find();
  print('Query id_num between 0 and 100 returned ${sortedDocs.length} documents (expected 101)');

  final allDocs = await db2.getAll();
  print('getAll() returned ${allDocs.length} documents');

  if (allDocs.length != 100000 || activeDocs.length != 50000) {
    print('❌ DATA LOSS DETECTED! Expected 100000 total & 50000 active, got ${allDocs.length} total & ${activeDocs.length} active');
  } else {
    print('✅ SUCCESS! All 100000 docs and indexes intact on disk.');
  }

  await db2.close();
  tempDir.deleteSync(recursive: true);
}
