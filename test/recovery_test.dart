import 'dart:io';
import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

void main() {
  group('Recovery Test', () {
    test('verify nextId is persisted correctly on disk', () async {
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

      expect(diskNextId, equals(10101), reason: 'NextId on disk must match total inserted count + 1');

      await db.close();
      dir.deleteSync(recursive: true);
    });
  });
}

