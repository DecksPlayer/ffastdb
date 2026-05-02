import 'dart:typed_data';
import 'package:fastdb/fastdb.dart';
import 'dart:io';

void main() async {
  final dbPath = 'test_binary.fdb';
  final walPath = 'test_binary.fdb.wal';
  
  if (File(dbPath).existsSync()) File(dbPath).deleteSync();
  if (File(walPath).existsSync()) File(walPath).deleteSync();

  final db = await FfastDb.init(
    WalStorageStrategy(
      main: IoStorageStrategy(dbPath),
      wal: IoStorageStrategy(walPath),
    ),
  );

  print('Inserting large binary data...');
  final largeBytes = Uint8List(1024 * 1024); // 1MB
  for (int i = 0; i < largeBytes.length; i++) {
    largeBytes[i] = i % 256;
  }

  try {
    final id = await db.insert({
      'name': 'test',
      'data': largeBytes,
    });
    print('Inserted with ID: $id');

    final doc = await db.findById(id);
    if (doc == null) {
      print('FAILED: Document not found');
    } else {
      final savedBytes = doc['data'] as Uint8List;
      bool match = true;
      if (savedBytes.length != largeBytes.length) {
        match = false;
      } else {
        for (int i = 0; i < largeBytes.length; i++) {
          if (savedBytes[i] != largeBytes[i]) {
            match = false;
            break;
          }
        }
      }
      print('Match: $match');
    }
  } catch (e) {
    print('Error: $e');
  } finally {
    await db.close();
  }
}
