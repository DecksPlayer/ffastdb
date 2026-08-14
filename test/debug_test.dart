import 'dart:io';
import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

void main() {
  test('Transaction memory rollback works', () async {
    final tempDir = await Directory.systemTemp.createTemp('fastdb_debug_');
    final db = FastDB(WalStorageStrategy(
      main: IoStorageStrategy('${tempDir.path}/db.fdb'),
      wal: IoStorageStrategy('${tempDir.path}/db.fdb.wal'),
    ));
    await db.open();

    final docs = [{}];
    final testDocs = docs.map((d) => Map<String, dynamic>.from(d)).toList();
    final initialIds = await db.insertAll(testDocs);
    
    try {
      await db.transaction(() async {
        if (initialIds.isNotEmpty) {
          await db.update(initialIds.first, {'rolled_back': true});
        }
        throw Exception('Rollback');
      });
    } catch (e) {
      // ignore expected Exception('Rollback')
    }

    try {
      final newIds = await db.rangeSearch(1, 100000);
      expect(newIds.length, initialIds.length, reason: 'newIds length mismatch');
      if (initialIds.isNotEmpty) {
        final id = initialIds.first;
        final doc = await db.findById(id);
        expect(doc, isNotNull, reason: 'doc is null');
        expect(doc!['rolled_back'], isNull, reason: 'doc rolled_back is not null');
      }
    } finally {
      await db.close();
      await tempDir.delete(recursive: true);
    }
  });
}
