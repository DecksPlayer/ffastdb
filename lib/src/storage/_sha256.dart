// Internal pure-Dart SHA-256 (FIPS 180-4), HMAC-SHA256 (RFC 2104) and
// PBKDF2-HMAC-SHA256 (RFC 8018). Not exported — used by
// EncryptedStorageStrategy.
//
// Web-safe: every 32-bit intermediate is masked (dart2js numbers are doubles
// and its bitwise operators work on 32 bits), state lives in Uint32Lists.

import 'dart:typed_data';

final Uint32List _k = Uint32List.fromList(const [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

const List<int> _init = [
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

const int _mask = 0xFFFFFFFF;

int _rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & _mask;

/// Incremental SHA-256.
class Sha256 {
  final Uint32List _h;
  final Uint8List _buf = Uint8List(64);
  final Uint32List _w = Uint32List(64);
  int _bufLen = 0;
  int _total = 0;

  Sha256() : _h = Uint32List.fromList(_init);

  Sha256._copy(Sha256 o) : _h = Uint32List.fromList(o._h) {
    _buf.setRange(0, o._bufLen, o._buf);
    _bufLen = o._bufLen;
    _total = o._total;
  }

  /// A copy of the current state (used to reuse HMAC key pads).
  Sha256 clone() => Sha256._copy(this);

  void add(List<int> data, [int start = 0, int? end]) {
    final stop = end ?? data.length;
    _total += stop - start;
    int i = start;
    if (_bufLen > 0) {
      while (_bufLen < 64 && i < stop) {
        _buf[_bufLen++] = data[i++];
      }
      if (_bufLen < 64) return;
      _block(_buf, 0);
      _bufLen = 0;
    }
    while (stop - i >= 64) {
      _block(data, i);
      i += 64;
    }
    while (i < stop) {
      _buf[_bufLen++] = data[i++];
    }
  }

  /// Finishes the hash and returns the 32-byte digest.
  Uint8List close() {
    final bits = _total * 8;
    final pad = Uint8List(((_bufLen < 56) ? 64 : 128) - _bufLen);
    pad[0] = 0x80;
    final hi = bits ~/ 0x100000000; // no `>> 32`: 32-bit shifts on the web
    final lo = bits - hi * 0x100000000;
    final n = pad.length;
    pad[n - 8] = (hi >>> 24) & 0xFF;
    pad[n - 7] = (hi >>> 16) & 0xFF;
    pad[n - 6] = (hi >>> 8) & 0xFF;
    pad[n - 5] = hi & 0xFF;
    pad[n - 4] = (lo >>> 24) & 0xFF;
    pad[n - 3] = (lo >>> 16) & 0xFF;
    pad[n - 2] = (lo >>> 8) & 0xFF;
    pad[n - 1] = lo & 0xFF;
    final total = _total;
    add(pad);
    _total = total;
    final out = Uint8List(32);
    for (int i = 0; i < 8; i++) {
      final v = _h[i];
      out[i * 4] = (v >>> 24) & 0xFF;
      out[i * 4 + 1] = (v >>> 16) & 0xFF;
      out[i * 4 + 2] = (v >>> 8) & 0xFF;
      out[i * 4 + 3] = v & 0xFF;
    }
    return out;
  }

  void _block(List<int> d, int off) {
    final w = _w;
    for (int t = 0; t < 16; t++) {
      final p = off + t * 4;
      w[t] = (d[p] << 24) | (d[p + 1] << 16) | (d[p + 2] << 8) | d[p + 3];
    }
    for (int t = 16; t < 64; t++) {
      final x = w[t - 15];
      final y = w[t - 2];
      final s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >>> 3);
      final s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >>> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & _mask;
    }
    int a = _h[0], b = _h[1], c = _h[2], dd = _h[3];
    int e = _h[4], f = _h[5], g = _h[6], h = _h[7];
    for (int t = 0; t < 64; t++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = ((e & f) ^ (~e & g)) & _mask;
      final t1 = (h + s1 + ch + _k[t] + w[t]) & _mask;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & _mask;
      h = g;
      g = f;
      f = e;
      e = (dd + t1) & _mask;
      dd = c;
      c = b;
      b = a;
      a = (t1 + t2) & _mask;
    }
    _h[0] = (_h[0] + a) & _mask;
    _h[1] = (_h[1] + b) & _mask;
    _h[2] = (_h[2] + c) & _mask;
    _h[3] = (_h[3] + dd) & _mask;
    _h[4] = (_h[4] + e) & _mask;
    _h[5] = (_h[5] + f) & _mask;
    _h[6] = (_h[6] + g) & _mask;
    _h[7] = (_h[7] + h) & _mask;
  }
}

Uint8List sha256(List<int> data) => (Sha256()..add(data)).close();

/// HMAC-SHA256 with the key pads hashed once (reused for every message).
class HmacSha256 {
  late final Sha256 _inner;
  late final Sha256 _outer;

  HmacSha256(List<int> key) {
    final k = Uint8List(64);
    final kk = key.length > 64 ? sha256(key) : key;
    k.setRange(0, kk.length, kk);
    final ipad = Uint8List(64);
    final opad = Uint8List(64);
    for (int i = 0; i < 64; i++) {
      ipad[i] = k[i] ^ 0x36;
      opad[i] = k[i] ^ 0x5c;
    }
    _inner = Sha256()..add(ipad);
    _outer = Sha256()..add(opad);
  }

  /// Starts a MAC computation; feed it with [Sha256.add], finish with [finish].
  Sha256 begin() => _inner.clone();

  Uint8List finish(Sha256 inner) => (_outer.clone()..add(inner.close())).close();

  Uint8List convert(List<int> message) => finish(begin()..add(message));
}

/// PBKDF2-HMAC-SHA256 (RFC 8018 §5.2).
Uint8List pbkdf2HmacSha256(
    List<int> password, List<int> salt, int iterations, int length) {
  if (iterations < 1) throw ArgumentError.value(iterations, 'iterations');
  final mac = HmacSha256(password);
  final out = Uint8List(length);
  final blocks = (length + 31) ~/ 32;
  for (int i = 1; i <= blocks; i++) {
    var u = mac.convert([
      ...salt,
      (i >>> 24) & 0xFF,
      (i >>> 16) & 0xFF,
      (i >>> 8) & 0xFF,
      i & 0xFF,
    ]);
    final t = Uint8List.fromList(u);
    for (int j = 1; j < iterations; j++) {
      u = mac.convert(u);
      for (int b = 0; b < 32; b++) {
        t[b] ^= u[b];
      }
    }
    final off = (i - 1) * 32;
    final n = length - off < 32 ? length - off : 32;
    out.setRange(off, off + n, t);
  }
  return out;
}
