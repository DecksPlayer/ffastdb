import 'dart:io';
import 'dart:typed_data';
import 'package:ffastdb/src/storage/io/io_storage_strategy.dart';
import 'package:ffastdb/src/storage/encrypted_storage_strategy.dart';
import 'package:ffastdb/src/storage/_aes256_ctr.dart';
import 'package:test/test.dart';

void main() {
  group('EncryptedStorageStrategy (AES-256-CTR)', () {
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

    test('Roundtrip: same key decrypts correctly', () async {
      const key = 'secret_key_123';
      final rawData = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

      // 1. Write encrypted.
      {
        final enc = EncryptedStorageStrategy(IoStorageStrategy(dbPath), key);
        await enc.open();
        await enc.write(0, rawData);
        await enc.close();
      }

      // 2. Read back with the same key — must equal the original.
      {
        final enc = EncryptedStorageStrategy(IoStorageStrategy(dbPath), key);
        await enc.open();
        final readData = await enc.read(0, rawData.length);
        expect(readData, equals(rawData), reason: 'Decryption with same key failed');
        await enc.close();
      }
    });

    test('On-disk bytes differ from plaintext (data is actually encrypted)', () async {
      const key = 'secret_key_123';
      final rawData = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

      {
        final enc = EncryptedStorageStrategy(IoStorageStrategy(dbPath), key);
        await enc.open();
        await enc.write(0, rawData);
        await enc.close();
      }

      // Read the raw file bypassing the encrypted layer.
      // The first 12 bytes are the nonce; data starts at byte 12.
      {
        final base = IoStorageStrategy(dbPath);
        await base.open();
        final rawRead = await base.read(12, rawData.length);
        expect(rawRead, isNot(equals(rawData)),
            reason: 'Data on disk should not match plaintext');
        await base.close();
      }
    });

    test('Wrong key produces different output', () async {
      const key = 'secret_key_123';
      final rawData = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

      {
        final enc = EncryptedStorageStrategy(IoStorageStrategy(dbPath), key);
        await enc.open();
        await enc.write(0, rawData);
        await enc.close();
      }

      {
        final wrong = EncryptedStorageStrategy(IoStorageStrategy(dbPath), 'wrong_key');
        await wrong.open();
        final wrongData = await wrong.read(0, rawData.length);
        expect(wrongData, isNot(equals(rawData)),
            reason: 'Wrong key should not decrypt correctly');
        await wrong.close();
      }
    });

    test('Nonce is persisted — DB can be reopened', () async {
      const key = 'persistent_key';
      final page0 = Uint8List.fromList(List.generate(64, (i) => i & 0xff));
      final page1 = Uint8List.fromList(List.generate(64, (i) => (i + 128) & 0xff));

      {
        final enc = EncryptedStorageStrategy(IoStorageStrategy(dbPath), key);
        await enc.open();
        await enc.write(0, page0);
        await enc.write(64, page1);
        await enc.close();
      }

      // Reopen and verify both pages are intact.
      {
        final enc = EncryptedStorageStrategy(IoStorageStrategy(dbPath), key);
        await enc.open();
        final r0 = await enc.read(0, 64);
        final r1 = await enc.read(64, 64);
        expect(r0, equals(page0), reason: 'Page 0 corrupted after reopen');
        expect(r1, equals(page1), reason: 'Page 1 corrupted after reopen');
        await enc.close();
      }
    });

    test('Mid-block write: partial block at non-zero offset decrypts correctly', () async {
      const key = 'offset_test_key';
      // Write 4 bytes starting at logical offset 5 (inside the first 16-byte block).
      final payload = Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD]);

      {
        final enc = EncryptedStorageStrategy(IoStorageStrategy(dbPath), key);
        await enc.open();
        await enc.write(5, payload);
        await enc.close();
      }

      {
        final enc = EncryptedStorageStrategy(IoStorageStrategy(dbPath), key);
        await enc.open();
        final result = await enc.read(5, payload.length);
        expect(result, equals(payload),
            reason: 'Mid-block offset roundtrip failed');
        await enc.close();
      }
    });

    test('Cross-block write: data spanning two AES blocks decrypts correctly', () async {
      const key = 'cross_block_key';
      // Write 10 bytes starting at offset 10 — spans block 0 (bytes 10-15)
      // and block 1 (bytes 16-19).
      final payload = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);

      {
        final enc = EncryptedStorageStrategy(IoStorageStrategy(dbPath), key);
        await enc.open();
        await enc.write(10, payload);
        await enc.close();
      }

      {
        final enc = EncryptedStorageStrategy(IoStorageStrategy(dbPath), key);
        await enc.open();
        final result = await enc.read(10, payload.length);
        expect(result, equals(payload),
            reason: 'Cross-block write roundtrip failed');
        await enc.close();
      }
    });

    test('Logical size hides the 12-byte nonce header', () async {
      const key = 'size_test_key';
      final data = Uint8List(100);

      final enc = EncryptedStorageStrategy(IoStorageStrategy(dbPath), key);
      await enc.open();
      expect(await enc.size, equals(0), reason: 'New DB should report size 0');
      await enc.write(0, data);
      expect(await enc.size, equals(100),
          reason: 'Logical size must equal bytes written, not include nonce');
      await enc.close();
    });

    test('withRawKey constructor: 32-byte key roundtrip', () async {
      final rawKey = Uint8List.fromList(List.generate(32, (i) => i + 1));
      final payload = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);

      {
        final enc = EncryptedStorageStrategy.withRawKey(
            IoStorageStrategy(dbPath), rawKey);
        await enc.open();
        await enc.write(0, payload);
        await enc.close();
      }

      {
        final enc = EncryptedStorageStrategy.withRawKey(
            IoStorageStrategy(dbPath), rawKey);
        await enc.open();
        final result = await enc.read(0, payload.length);
        expect(result, equals(payload), reason: 'withRawKey roundtrip failed');
        await enc.close();
      }
    });
  });

  // ─── AES-256 core unit tests ───────────────────────────────────────────────
  // Verified against NIST SP 800-38A Appendix F.5 (AES-256-CTR).

  group('AES-256-CTR core (NIST SP 800-38A F.5)', () {
    // Test vectors from NIST SP 800-38A, Section F.5.5 / F.5.6.
    // Key:    603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4
    // Nonce:  f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff  (initial counter block)
    // Block 1 plaintext:  6bc1bee22e409f96e93d7e117393172a
    // Block 1 ciphertext: 601ec313775789a5b7a7f504bbf3d228

    test('NIST AES-256-CTR block 1 encryption', () {
      final key = _hexToBytes(
          '603deb1015ca71be2b73aef0857d7781'
          '1f352c073b6108d72d9810a30914dff4');
      // Use nonce = first 12 bytes of the NIST initial counter block.
      // Counter starts at the value encoded in bytes 12–15 = 0xfcfdfeff.
      final nonce12 = _hexToBytes('f0f1f2f3f4f5f6f7f8f9fafb');
      // Simulate counter starting at 0xfcfdfeff for block 0.
      // We achieve this by choosing a logical offset such that
      // blockNum = 0xfcfdfeff.
      final plaintext = _hexToBytes('6bc1bee22e409f96e93d7e117393172a');
      final expected  = _hexToBytes('601ec313775789a5b7a7f504bbf3d228');

      final rk = aes256KeyExpand(key);
      final data = Uint8List.fromList(plaintext);
      // The NIST counter block has the last 4 bytes = 0xfcfdfeff,
      // so block number = 0xfcfdfeff.
      const blockNum = 0xfcfdfeff;
      aes256CtrXor(rk, nonce12, blockNum * 16, data);

      expect(data, equals(expected),
          reason: 'NIST AES-256-CTR block 1 mismatch');
    });

    test('CTR is self-inverse: encrypt(encrypt(x)) == x', () {
      final key = Uint8List.fromList(List.generate(32, (i) => i));
      final nonce = generateNonce12();
      final rk    = aes256KeyExpand(key);

      final original = Uint8List.fromList(List.generate(48, (i) => i * 7 & 0xff));
      final copy     = Uint8List.fromList(original);

      aes256CtrXor(rk, nonce, 0, copy);       // encrypt
      expect(copy, isNot(equals(original)));
      aes256CtrXor(rk, nonce, 0, copy);       // decrypt (same operation)
      expect(copy, equals(original), reason: 'CTR self-inverse failed');
    });

    test('CTR seekability: encrypting at offset 32 matches partial stream', () {
      final key   = Uint8List.fromList(List.generate(32, (i) => i + 1));
      final nonce = generateNonce12();
      final rk    = aes256KeyExpand(key);

      // Encrypt 48 bytes starting at offset 0.
      final full = Uint8List(48);
      aes256CtrXor(rk, nonce, 0, full);

      // Encrypt 16 bytes starting at offset 32 (second half of stream).
      final partial = Uint8List(16);
      aes256CtrXor(rk, nonce, 32, partial);

      expect(partial, equals(full.sublist(32)),
          reason: 'CTR seek produced different keystream than contiguous encrypt');
    });
  });
}

// ─── helpers ─────────────────────────────────────────────────────────────────

Uint8List _hexToBytes(String hex) {
  final clean = hex.replaceAll(' ', '');
  final result = Uint8List(clean.length ~/ 2);
  for (int i = 0; i < result.length; i++) {
    result[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}
