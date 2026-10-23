import 'dart:math';
import 'dart:typed_data';

import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/_aes256_ctr.dart';
import 'package:test/test.dart';

/// Low PBKDF2 cost: these tests open many databases.
EncryptedStorageStrategy enc(StorageStrategy base, [String key = 'pw']) =>
    EncryptedStorageStrategy(base, key, pbkdf2Iterations: 1000);

// v2 physical layout (see EncryptedStorageStrategy).
const header = 128, sector = 1024, phys = 12 + 1024 + 16;

Future<Uint8List> physical(MemoryStorageStrategy m) async => m.read(0, await m.size);

void main() {
  test('random writes, reads and truncates match a plaintext model', () async {
    final rnd = Random(7);
    final base = MemoryStorageStrategy();
    var e = enc(base);
    await e.open();
    var model = Uint8List(0);

    for (int step = 0; step < 400; step++) {
      final op = rnd.nextInt(10);
      if (op < 6) {
        final offset = rnd.nextInt(model.length + 3000);
        final data = Uint8List.fromList(
            List.generate(rnd.nextInt(2500) + 1, (_) => rnd.nextInt(256)));
        await e.write(offset, data);
        if (offset + data.length > model.length) {
          model = Uint8List(offset + data.length)..setRange(0, model.length, model);
        }
        model.setRange(offset, offset + data.length, data);
      } else if (op < 9) {
        final offset = rnd.nextInt(model.length + 100);
        final size = rnd.nextInt(3000);
        final expected = Uint8List(size);
        for (int i = 0; i < size && offset + i < model.length; i++) {
          expected[i] = model[offset + i];
        }
        expect(await e.read(offset, size), expected, reason: 'step $step');
      } else {
        final size = rnd.nextInt(model.length + 1);
        await e.truncate(size);
        model = Uint8List.fromList(model.sublist(0, size));
      }
      expect(await e.size, model.length);
      if (step % 50 == 49) {
        // Reopen: logical size and contents come from the file alone.
        await e.close();
        e = enc(base);
        await e.open();
        expect(await e.size, model.length);
      }
    }
    expect(await e.read(0, model.length), model);
  });

  test('rewriting a sector uses a fresh nonce', () async {
    final base = MemoryStorageStrategy();
    final e = enc(base);
    await e.open();
    await e.write(0, Uint8List(100));
    final first = (await physical(base)).sublist(header, header + 12);
    await e.write(0, Uint8List(100));
    final second = (await physical(base)).sublist(header, header + 12);
    expect(second, isNot(equals(first)));
  });

  test('no plaintext reaches the base storage', () async {
    final base = MemoryStorageStrategy();
    final e = enc(base);
    await e.open();
    final secret = Uint8List.fromList('TOP-SECRET-PAYLOAD'.codeUnits);
    await e.write(5000, secret);
    final bytes = await physical(base);
    final text = String.fromCharCodes(bytes);
    expect(text.contains('TOP-SECRET'), isFalse);
  });

  test('a flipped bit or swapped sectors fail authentication', () async {
    final base = MemoryStorageStrategy();
    var e = enc(base);
    await e.open();
    await e.write(0, Uint8List.fromList(List.generate(3 * sector, (i) => i & 0xFF)));
    await e.close();

    final original = await physical(base);
    // Flip one ciphertext bit of sector 1.
    final tampered = Uint8List.fromList(original);
    tampered[header + phys + 100] ^= 1;
    await base.write(0, tampered);
    e = enc(base);
    await e.open();
    expect(await e.read(0, sector), hasLength(sector)); // sector 0 intact
    expect(() => e.read(sector, 10), throwsStateError);

    // Swap sectors 0 and 1 (each is authentic on its own).
    final swapped = Uint8List.fromList(original)
      ..setRange(header, header + phys, original, header + phys)
      ..setRange(header + phys, header + 2 * phys, original, header);
    await base.write(0, swapped);
    e = enc(base);
    await e.open();
    expect(() => e.read(0, 10), throwsStateError);
  });

  test('wrong key, wrong key kind and tampered header are rejected', () async {
    final base = MemoryStorageStrategy();
    final e = enc(base);
    await e.open();
    await e.write(0, Uint8List(10));
    expect(() => enc(base, 'other').open(), throwsStateError);
    expect(() => EncryptedStorageStrategy.withRawKey(base, Uint8List(32)).open(),
        throwsStateError);

    final bytes = await physical(base);
    bytes[33] ^= 1; // logical size field
    await base.write(0, bytes);
    expect(() => enc(base).open(), throwsStateError);
  });

  test('raw-key databases round-trip', () async {
    final base = MemoryStorageStrategy();
    final key = Uint8List.fromList(List.generate(32, (i) => i * 3));
    var e = EncryptedStorageStrategy.withRawKey(base, key);
    await e.open();
    await e.write(10, Uint8List.fromList([1, 2, 3]));
    await e.close();
    e = EncryptedStorageStrategy.withRawKey(base, key);
    await e.open();
    expect(await e.read(10, 3), [1, 2, 3]);
    expect(e.isLegacyFormat, isFalse);
  });

  test('legacy v1 files keep working', () async {
    // Build a v1 file by hand: 12-byte nonce header + single-nonce CTR.
    final base = MemoryStorageStrategy();
    final nonce = Uint8List.fromList(List.generate(12, (i) => 200 - i));
    final rk = aes256KeyExpand(aes256KeyFromPassword('legacy-pw'));
    final plain = Uint8List.fromList(List.generate(3000, (i) => (i * 13) & 0xFF));
    final ct = Uint8List.fromList(plain);
    aes256CtrXor(rk, nonce, 0, ct);
    await base.write(0, nonce);
    await base.write(12, ct);

    final e = EncryptedStorageStrategy(base, 'legacy-pw');
    await e.open();
    expect(e.isLegacyFormat, isTrue);
    expect(await e.size, 3000);
    expect(await e.read(0, 3000), plain);
    await e.write(3000, Uint8List.fromList([9, 9]));
    expect(await e.read(2999, 3), [plain[2999], 9, 9]);
  });

  test('FastDB on encrypted storage: CRUD, reopen, compact', () async {
    final base = MemoryStorageStrategy();
    var db = FastDB.forTesting(enc(base))..addIndex('k');
    await db.open();
    await db.insertAll([for (int i = 0; i < 500; i++) {'k': 'v${i % 5}', 'i': i}]);
    for (int id = 1; id <= 100; id++) {
      await db.delete(id);
    }
    await db.update(200, {'i': -1});
    await db.close();

    db = FastDB.forTesting(enc(base))..addIndex('k');
    await db.open();
    addTearDown(db.close);
    await db.compact();
    expect(await db.count(), 400);
    expect((await db.findById(200))?['i'], -1);
    expect((await db.findById(500))?['i'], 499);
    expect(await db.query().where('k').equals('v0').count(), 80);
  });
}
