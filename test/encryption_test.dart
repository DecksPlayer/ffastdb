import 'dart:io';
import 'dart:typed_data';
import 'package:ffastdb/src/storage/io/io_storage_strategy.dart';
import 'package:ffastdb/src/storage/encrypted_storage_strategy.dart';
import 'package:test/test.dart';

void main() {
  group('EncryptedStorageStrategy', () {
    late Directory tempDir;
    late String dbPath;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('fastdb_encrypt_test_');
      dbPath = '${tempDir.path}/test.fdb';
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('Encrypted data is unreadable without correct key', () async {
      final key = 'secret_key_123';
      final rawData = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      
      // 1. Write encrypted
      {
        final baseStorage = IoStorageStrategy(dbPath);
        final encryptedStorage = EncryptedStorageStrategy(baseStorage, key);
        await encryptedStorage.open();
        await encryptedStorage.write(0, rawData);
        await encryptedStorage.close();
      }

      // 2. Read with same key
      {
        final baseStorage = IoStorageStrategy(dbPath);
        final encryptedStorage2 = EncryptedStorageStrategy(baseStorage, key);
        await encryptedStorage2.open();
        final readData = await encryptedStorage2.read(0, rawData.length);
        expect(readData, equals(rawData), reason: 'Decryption failed with same key');
        await encryptedStorage2.close();
      }

      // 3. Read raw (no encryption) - should be different
      {
        final baseStorage = IoStorageStrategy(dbPath);
        await baseStorage.open();
        final rawRead = await baseStorage.read(0, rawData.length);
        expect(rawRead, isNot(equals(rawData)), reason: 'Raw data should be encrypted on disk');
        await baseStorage.close();
      }
      
      // 4. Read with wrong key
      {
        final baseStorage = IoStorageStrategy(dbPath);
        final wrongStorage = EncryptedStorageStrategy(baseStorage, 'wrong_key');
        await wrongStorage.open();
        final wrongData = await wrongStorage.read(0, rawData.length);
        expect(wrongData, isNot(equals(rawData)), reason: 'Should not decrypt with wrong key');
        await wrongStorage.close();
      }
    });

    test('Encryption handles offsets correctly (cyclic key)', () async {
       final key = 'abc'; // 97, 98, 99
       final rawData = Uint8List.fromList([0, 0, 0, 0]);
       
       {
         final baseStorage = IoStorageStrategy(dbPath);
         final encryptedStorage = EncryptedStorageStrategy(baseStorage, key);
         await encryptedStorage.open();
         
         // Write at offset 1
         // data[0] (pos 1) XOR 'b' (98) = 98
         // data[1] (pos 2) XOR 'c' (99) = 99
         await encryptedStorage.write(1, rawData.sublist(0, 2));
         await encryptedStorage.close();
       }
       
       {
         final baseStorage = IoStorageStrategy(dbPath);
         await baseStorage.open();
         final rawRead = await baseStorage.read(1, 2);
         expect(rawRead[0], equals(98));
         expect(rawRead[1], equals(99));
         await baseStorage.close();
       }
    });
  });
}
