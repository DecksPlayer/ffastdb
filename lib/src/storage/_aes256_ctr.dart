// Internal pure-Dart AES-256-CTR engine.
// Not exported from the package — used exclusively by EncryptedStorageStrategy.
//
// Implements only the forward AES cipher (sufficient for CTR mode, which is
// symmetric: encrypt == decrypt). FIPS 197 compliant.
//
// Counter block layout (16 bytes):
//   bytes  0–11 : random nonce  (persisted in file header)
//   bytes 12–15 : block counter (big-endian uint32, incremented per 16-byte block)
//
// This gives a maximum addressable space of 2^32 × 16 = 64 GB per database,
// which is well above practical limits for an embedded DB.

import 'dart:math' show Random;
import 'dart:typed_data';

// ─── AES S-box (FIPS 197, Figure 7) ─────────────────────────────────────────

const _sbox = <int>[
  0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
  0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
  0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
  0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
  0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
  0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
  0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
  0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
  0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
  0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
  0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
  0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
  0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
  0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
  0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
  0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
];

// Round constants for key schedule (FIPS 197 Figure 11).
// AES-256 uses indices 0–6 (SubWord+RotWord applied at i = 8,16,24,32,40,48,56).
const _rcon = <int>[0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36];

// ─── GF(2⁸) helper ───────────────────────────────────────────────────────────

// Multiply by 2 in GF(2⁸) with the AES irreducible polynomial (0x11b).
int _xtime(int b) => ((b << 1) ^ ((b & 0x80) != 0 ? 0x1b : 0)) & 0xff;

// MixColumns on one column [a0,a1,a2,a3] → packed 32-bit result (MSB = row 0).
int _mixCol(int a0, int a1, int a2, int a3) {
  final x2a0 = _xtime(a0), x2a1 = _xtime(a1);
  final x2a2 = _xtime(a2), x2a3 = _xtime(a3);
  return ((x2a0 ^ x2a1 ^ a1 ^ a2 ^ a3) << 24) |
         ((a0 ^ x2a1 ^ x2a2 ^ a2 ^ a3) << 16) |
         ((a0 ^ a1 ^ x2a2 ^ x2a3 ^ a3) <<  8) |
          (x2a0 ^ a0 ^ a1 ^ a2 ^ x2a3);
}

// ─── Key schedule ─────────────────────────────────────────────────────────────

/// Expands a 32-byte AES-256 key into 60 round-key words (Uint32List).
/// Call this once per key; reuse the result for every block encryption.
Uint32List aes256KeyExpand(Uint8List key) {
  assert(key.length == 32, 'AES-256 requires exactly 32 bytes');
  final w = Uint32List(60);

  // Load the key words directly.
  for (int i = 0; i < 8; i++) {
    final b = i * 4;
    w[i] = (key[b] << 24) | (key[b + 1] << 16) | (key[b + 2] << 8) | key[b + 3];
  }

  for (int i = 8; i < 60; i++) {
    int temp = w[i - 1];
    if (i % 8 == 0) {
      // RotWord: rotate left by one byte.
      final rot = ((temp << 8) | (temp >>> 24)) & 0xffffffff;
      // SubWord.
      temp = (_sbox[(rot >>> 24) & 0xff] << 24) |
             (_sbox[(rot >>> 16) & 0xff] << 16) |
             (_sbox[(rot >>>  8) & 0xff] <<  8) |
              _sbox[ rot         & 0xff];
      // XOR with Rcon (only the MSB).
      temp ^= _rcon[i ~/ 8 - 1] << 24;
    } else if (i % 8 == 4) {
      // SubWord only (AES-256 extra step).
      temp = (_sbox[(temp >>> 24) & 0xff] << 24) |
             (_sbox[(temp >>> 16) & 0xff] << 16) |
             (_sbox[(temp >>>  8) & 0xff] <<  8) |
              _sbox[ temp         & 0xff];
    }
    w[i] = (w[i - 8] ^ temp) & 0xffffffff;
  }
  return w;
}

// ─── AES-256 forward block cipher ────────────────────────────────────────────

/// Encrypts one 16-byte block from [input]+[inOff] into [output]+[outOff].
/// [rk] must be the expanded key from [aes256KeyExpand].
///
/// State columns s0…s3 are stored as 32-bit words, MSB = row 0.
/// Column j = input bytes [4j, 4j+1, 4j+2, 4j+3].
void aes256EncryptBlock(
    Uint32List rk, Uint8List input, int inOff, Uint8List output, int outOff) {
  // Load state from input (column-major, FIPS 197 convention).
  var s0 = (input[inOff    ] << 24) | (input[inOff + 1] << 16) |
           (input[inOff + 2] <<  8) |  input[inOff + 3];
  var s1 = (input[inOff + 4] << 24) | (input[inOff + 5] << 16) |
           (input[inOff + 6] <<  8) |  input[inOff + 7];
  var s2 = (input[inOff + 8] << 24) | (input[inOff + 9] << 16) |
           (input[inOff +10] <<  8) |  input[inOff +11];
  var s3 = (input[inOff +12] << 24) | (input[inOff +13] << 16) |
           (input[inOff +14] <<  8) |  input[inOff +15];

  // Initial AddRoundKey.
  s0 ^= rk[0]; s1 ^= rk[1]; s2 ^= rk[2]; s3 ^= rk[3];

  // Rounds 1–13: SubBytes + ShiftRows + MixColumns + AddRoundKey.
  //
  // After SubBytes+ShiftRows, new column j picks byte from original column
  // (j + row) mod 4 at position row. Written out explicitly:
  //   new_col_j = [ sbox(s_j >> 24), sbox(s_(j+1)%4 >> 16),
  //                 sbox(s_(j+2)%4 >> 8), sbox(s_(j+3)%4 & 0xff) ]
  for (int r = 1; r < 14; r++) {
    final ki = r * 4;
    // SubBytes + ShiftRows — extract four bytes per new column.
    final r0c0 = _sbox[(s0 >>> 24) & 0xff];
    final r1c0 = _sbox[(s1 >>> 16) & 0xff];
    final r2c0 = _sbox[(s2 >>>  8) & 0xff];
    final r3c0 = _sbox[ s3         & 0xff];

    final r0c1 = _sbox[(s1 >>> 24) & 0xff];
    final r1c1 = _sbox[(s2 >>> 16) & 0xff];
    final r2c1 = _sbox[(s3 >>>  8) & 0xff];
    final r3c1 = _sbox[ s0         & 0xff];

    final r0c2 = _sbox[(s2 >>> 24) & 0xff];
    final r1c2 = _sbox[(s3 >>> 16) & 0xff];
    final r2c2 = _sbox[(s0 >>>  8) & 0xff];
    final r3c2 = _sbox[ s1         & 0xff];

    final r0c3 = _sbox[(s3 >>> 24) & 0xff];
    final r1c3 = _sbox[(s0 >>> 16) & 0xff];
    final r2c3 = _sbox[(s1 >>>  8) & 0xff];
    final r3c3 = _sbox[ s2         & 0xff];

    // MixColumns + AddRoundKey.
    s0 = _mixCol(r0c0, r1c0, r2c0, r3c0) ^ rk[ki    ];
    s1 = _mixCol(r0c1, r1c1, r2c1, r3c1) ^ rk[ki + 1];
    s2 = _mixCol(r0c2, r1c2, r2c2, r3c2) ^ rk[ki + 2];
    s3 = _mixCol(r0c3, r1c3, r2c3, r3c3) ^ rk[ki + 3];
  }

  // Final round: SubBytes + ShiftRows + AddRoundKey (no MixColumns).
  final f0 = (_sbox[(s0 >>> 24) & 0xff] << 24) | (_sbox[(s1 >>> 16) & 0xff] << 16) |
             (_sbox[(s2 >>>  8) & 0xff] <<  8) |  _sbox[ s3         & 0xff];
  final f1 = (_sbox[(s1 >>> 24) & 0xff] << 24) | (_sbox[(s2 >>> 16) & 0xff] << 16) |
             (_sbox[(s3 >>>  8) & 0xff] <<  8) |  _sbox[ s0         & 0xff];
  final f2 = (_sbox[(s2 >>> 24) & 0xff] << 24) | (_sbox[(s3 >>> 16) & 0xff] << 16) |
             (_sbox[(s0 >>>  8) & 0xff] <<  8) |  _sbox[ s1         & 0xff];
  final f3 = (_sbox[(s3 >>> 24) & 0xff] << 24) | (_sbox[(s0 >>> 16) & 0xff] << 16) |
             (_sbox[(s1 >>>  8) & 0xff] <<  8) |  _sbox[ s2         & 0xff];

  s0 = f0 ^ rk[56]; s1 = f1 ^ rk[57]; s2 = f2 ^ rk[58]; s3 = f3 ^ rk[59];

  // Store output.
  output[outOff    ] = (s0 >>> 24) & 0xff; output[outOff + 1] = (s0 >>> 16) & 0xff;
  output[outOff + 2] = (s0 >>>  8) & 0xff; output[outOff + 3] =  s0         & 0xff;
  output[outOff + 4] = (s1 >>> 24) & 0xff; output[outOff + 5] = (s1 >>> 16) & 0xff;
  output[outOff + 6] = (s1 >>>  8) & 0xff; output[outOff + 7] =  s1         & 0xff;
  output[outOff + 8] = (s2 >>> 24) & 0xff; output[outOff + 9] = (s2 >>> 16) & 0xff;
  output[outOff +10] = (s2 >>>  8) & 0xff; output[outOff +11] =  s2         & 0xff;
  output[outOff +12] = (s3 >>> 24) & 0xff; output[outOff +13] = (s3 >>> 16) & 0xff;
  output[outOff +14] = (s3 >>>  8) & 0xff; output[outOff +15] =  s3         & 0xff;
}

// ─── CTR mode ────────────────────────────────────────────────────────────────

/// XORs [data] in place with the AES-256-CTR keystream.
///
/// [nonce12] is a 12-byte fixed prefix (stored in the file header).
/// [offset] is the logical byte offset within the ciphertext stream.
/// [rk] is the expanded round key.
///
/// Counter block = nonce12[0..11] || uint32_be(blockNumber).
/// The function is seekable: it produces the correct keystream for any offset.
void aes256CtrXor(Uint32List rk, Uint8List nonce12, int offset, Uint8List data) {
  int blockNum = offset ~/ 16;
  int blockByte = offset % 16;

  final counterBlock = Uint8List(16);
  final keystream    = Uint8List(16);
  // Pre-fill the fixed nonce portion of the counter block.
  counterBlock.setRange(0, 12, nonce12);

  int pos = 0;
  while (pos < data.length) {
    // Set the big-endian block counter in bytes 12–15.
    counterBlock[12] = (blockNum >>> 24) & 0xff;
    counterBlock[13] = (blockNum >>> 16) & 0xff;
    counterBlock[14] = (blockNum >>>  8) & 0xff;
    counterBlock[15] =  blockNum         & 0xff;

    aes256EncryptBlock(rk, counterBlock, 0, keystream, 0);

    while (blockByte < 16 && pos < data.length) {
      data[pos++] ^= keystream[blockByte++];
    }
    blockByte = 0;
    blockNum++;
  }
}

// ─── Key derivation ──────────────────────────────────────────────────────────

/// Derives a 32-byte AES-256 key from a password string.
///
/// Uses UTF-16 code units with cyclic repetition to fill exactly 32 bytes.
/// **This is NOT a cryptographic KDF.** For maximum security, derive the key
/// externally using PBKDF2, Argon2, or scrypt and pass it via
/// [EncryptedStorageStrategy.withRawKey].
Uint8List aes256KeyFromPassword(String password) {
  final units = password.codeUnits;
  final key   = Uint8List(32);
  if (units.isEmpty) return key; // all-zero key — caller should avoid this
  for (int i = 0; i < 32; i++) {
    key[i] = units[i % units.length] & 0xff;
  }
  return key;
}

/// Generates 12 cryptographically random bytes for use as the CTR nonce.
Uint8List generateNonce12() {
  final rng = Random.secure();
  return Uint8List.fromList(List.generate(12, (_) => rng.nextInt(256)));
}
