import 'dart:io';
import 'package:ffastdb/ffastdb.dart';

void main() async {
  final dir = Directory.systemTemp.createTempSync('fastdb_recovery_');
  final dbPath = '${dir.path}/recovery.fdb';
  
  var db = FastDB(IoStorageStrategy(dbPath));
  await db.open();
  for (int i = 0; i < 100; i++) {
    await db.insert({'id_val': i});
  }
  
  final docs = List.generate(10000, (i) => {'batch_id': i});
  await db.insertAll(docs);
  
  final headerBytes = await File(dbPath).readAsBytes();
  // Header: Magic(4), Root(4), NextId(4), Version(4)
  // NextId is at offset 8 (little endian)
  final diskNextId = headerBytes[8] | (headerBytes[9] << 8) | (headerBytes[10] << 16) | (headerBytes[11] << 24);
  print('NextId on disk: $diskNextId');

  if (diskNextId == 10101) {
    print('SUCCESS: nextId persisted correctly.');
  } else {
    print('FAILURE: nextId on disk ($diskNextId) != expected (10101)');
  }

  await db.close();
  dir.deleteSync(recursive: true);
}
