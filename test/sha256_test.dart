import 'dart:convert';
import 'dart:typed_data';

import 'package:ffastdb/src/storage/_sha256.dart';
import 'package:test/test.dart';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

List<int> ascii(String s) => utf8.encode(s);

// Reference values: Python hashlib / hmac (FIPS 180-4, RFC 4231, RFC 7914 §11).
void main() {
  test('SHA-256 vectors (incl. padding boundaries)', () {
    final cases = <List<int>, String>{
      ascii(''): 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      ascii('abc'): 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      ascii('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'):
          '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      ascii('a' * 55): '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318',
      ascii('a' * 56): 'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a',
      ascii('a' * 63): '7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34',
      ascii('a' * 64): 'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb',
      ascii('a' * 1000): '41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3',
      [for (int r = 0; r < 3; r++) ...List.generate(256, (i) => i)]:
          'f3a25aa93aa2fbba28d79260535bbd6a5eb0fc1c24a8b0f04e12b484c1dfe363',
    };
    cases.forEach((msg, digest) => expect(hex(sha256(msg)), digest));
  });

  test('incremental add matches one-shot', () {
    final data = Uint8List.fromList(List.generate(1000, (i) => (i * 7) & 0xFF));
    final h = Sha256();
    for (int i = 0; i < data.length; i += 37) {
      h.add(data, i, i + 37 > data.length ? data.length : i + 37);
    }
    expect(hex(h.close()), hex(sha256(data)));
  });

  test('HMAC-SHA256 vectors (RFC 4231)', () {
    expect(hex(HmacSha256(List.filled(20, 0x0b)).convert(ascii('Hi There'))),
        'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7');
    expect(hex(HmacSha256(ascii('Jefe')).convert(ascii('what do ya want for nothing?'))),
        '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843');
    expect(
        hex(HmacSha256(List.filled(131, 0xaa)).convert(
            ascii('Test Using Larger Than Block-Size Key - Hash Key First'))),
        '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54');
  });

  test('PBKDF2-HMAC-SHA256 vectors', () {
    final p = ascii('password'), s = ascii('salt');
    expect(hex(pbkdf2HmacSha256(p, s, 1, 32)),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b');
    expect(hex(pbkdf2HmacSha256(p, s, 2, 32)),
        'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43');
    expect(hex(pbkdf2HmacSha256(p, s, 4096, 32)),
        'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a');
    expect(
        hex(pbkdf2HmacSha256(ascii('passwordPASSWORDpassword'),
            ascii('saltSALTsaltSALTsaltSALTsaltSALTsalt'), 4096, 40)),
        '348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9');
  });
}
