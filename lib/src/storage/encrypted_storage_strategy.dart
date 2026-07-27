import 'dart:typed_data';
import '_aes256_ctr.dart';
import 'storage_strategy.dart';

/// A wrapper [StorageStrategy] that transparently encrypts/decrypts all data
/// using **AES-256 in CTR mode** (pure Dart, zero external dependencies).
///
/// ### File layout on disk
/// ```
/// bytes  0–11 : 12-byte random nonce (plaintext, written on first open)
/// bytes 12+   : AES-256-CTR encrypted database content
/// ```
/// The nonce is generated once with [Random.secure] and persisted in the file
/// header. All offsets exposed through [StorageStrategy] are logical (nonce
/// header is invisible to callers).
///
/// ### Key derivation
/// When constructed with a [String] password, the key is derived by taking the
/// UTF-16 code units of the password and cycling them to fill 32 bytes.
/// **This is NOT a cryptographic KDF.** For maximum security, derive the key
/// externally (e.g. PBKDF2, Argon2) and use [EncryptedStorageStrategy.withRawKey].
///
/// ### Thread safety
/// Not thread-safe. Callers must serialise access (FastDB already does this).
class EncryptedStorageStrategy implements StorageStrategy {
  final StorageStrategy _base;
  final Uint32List _rk;      // 60 AES-256 round-key words (expanded once)
  late Uint8List _nonce12;   // 12-byte CTR nonce, loaded/written in open()

  /// Number of bytes reserved at the start of the underlying file for the nonce.
  static const int _headerSize = 12;

  /// Creates an encrypted strategy wrapping [base], deriving the AES key from
  /// the UTF-16 code units of [encryptionKey] (cyclic padding to 32 bytes).
  EncryptedStorageStrategy(this._base, String encryptionKey)
      : _rk = aes256KeyExpand(aes256KeyFromPassword(encryptionKey));

  /// Creates an encrypted strategy with a pre-derived 32-byte raw AES key.
  /// Use this when the caller handles key derivation (PBKDF2, Argon2, etc.).
  EncryptedStorageStrategy.withRawKey(this._base, Uint8List rawKey)
      : _rk = aes256KeyExpand(rawKey) {
    assert(rawKey.length == 32, 'AES-256 requires exactly 32 bytes');
  }

  /// Returns the underlying base storage strategy.
  StorageStrategy get storage => _base;

  // ── StorageStrategy ────────────────────────────────────────────────────────

  @override
  Future<void> open() async {
    await _base.open();
    final baseSize = await _base.size;
    if (baseSize == 0) {
      // New file: generate a fresh nonce and persist it as the file header.
      _nonce12 = generateNonce12();
      await _base.write(0, _nonce12);
    } else if (baseSize >= _headerSize) {
      // Existing file: read the stored nonce.
      _nonce12 = await _base.read(0, _headerSize);
    } else {
      throw StateError(
          'Encrypted storage header is corrupted '
          '(file size $baseSize < required $_headerSize bytes).');
    }
  }

  @override
  Future<Uint8List> read(int offset, int size) async {
    final data = await _base.read(offset + _headerSize, size);
    aes256CtrXor(_rk, _nonce12, offset, data);
    return data;
  }

  @override
  Future<void> write(int offset, Uint8List data) async {
    final encrypted = Uint8List.fromList(data);
    aes256CtrXor(_rk, _nonce12, offset, encrypted);
    return _base.write(offset + _headerSize, encrypted);
  }

  @override
  Future<void> flush() => _base.flush();

  @override
  Future<void> close() => _base.close();

  @override
  Future<int> get size async {
    final s = await _base.size;
    final logical = s - _headerSize;
    return logical < 0 ? 0 : logical;
  }

  @override
  Future<void> truncate(int size) => _base.truncate(size + _headerSize);

  @override
  int? get sizeSync {
    final s = _base.sizeSync;
    if (s == null) return null;
    final logical = s - _headerSize;
    return logical < 0 ? 0 : logical;
  }

  @override
  Uint8List? readSync(int offset, int size) {
    final data = _base.readSync(offset + _headerSize, size);
    if (data != null) aes256CtrXor(_rk, _nonce12, offset, data);
    return data;
  }

  @override
  bool get needsExplicitFlush => _base.needsExplicitFlush;

  @override
  bool writeSync(int offset, Uint8List data) {
    final encrypted = Uint8List.fromList(data);
    aes256CtrXor(_rk, _nonce12, offset, encrypted);
    return _base.writeSync(offset + _headerSize, encrypted);
  }
}
