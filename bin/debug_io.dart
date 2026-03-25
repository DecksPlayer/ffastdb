import 'dart:io';
import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/io/io_storage_strategy.dart';

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('fastdb_debug_');
  final path = '${dir.path}/db.fdb';
  print('Path: $path');

  // Session 1: insert + close
  final db1 = FastDB(IoStorageStrategy(path));
  await db1.open();
  final id1 = await db1.insert({'msg': 'hello'});
  print('Inserted id=$id1');
  await db1.close();
  print('Closed db1. File size: ${await File(path).length()}');

  // Session 2: reopen + read
  final db2 = FastDB(IoStorageStrategy(path));
  await db2.open();
  final doc = await db2.findById(id1);
  print('findById($id1) = $doc');
  final all = await db2.getAll();
  print('getAll count = ${all.length}');
  await db2.close();

  await dir.delete(recursive: true);
  print('Done.');
}
