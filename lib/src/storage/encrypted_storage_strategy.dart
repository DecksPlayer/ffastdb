import 'dart:typed_data';
import 'storage_strategy.dart';

/// A wrapper [StorageStrategy] that obfuscates data before writing to the
/// base strategy and de-obfuscates it after reading.
///
/// **⚠️ Security Warning:** This uses a Vigenère-style XOR stream cipher,
/// which provides **obfuscation only, NOT cryptographic security**. Known
/// plaintext attacks (e.g. against the fixed 'FDB2' file header) can partially
/// recover the key. It prevents casual inspection of storage contents (browser
/// DevTools, file hex dumps) but is not suitable for protecting sensitive data
/// against a determined attacker.
///
/// **For real encryption** use AES-256-GCM via a package such as `encrypt`
/// or `pointycastle`, wrapped in a custom [StorageStrategy].
///
/// Primarily used to prevent browser developer-tool inspection of the raw
/// database bytes in Flutter Web applications.
class EncryptedStorageStrategy implements StorageStrategy {
  final StorageStrategy _base;
  final List<int> _key;

  EncryptedStorageStrategy(this._base, String encryptionKey)
      : _key = encryptionKey.codeUnits;

  void _cipher(Uint8List data, int offset) {
    if (_key.isEmpty) return;
    for (int i = 0; i < data.length; i++) {
        // XOR cipher — fast, deterministic, and effectively hides characters
        // for "obfuscation" requirements.
        data[i] ^= _key[(offset + i) % _key.length];
    }
  }

  @override
  Future<void> open() => _base.open();

  @override
  Future<Uint8List> read(int offset, int size) async {
    final data = await _base.read(offset, size);
    _cipher(data, offset);
    return data;
  }

  @override
  Future<void> write(int offset, Uint8List data) async {
    final encrypted = Uint8List.fromList(data);
    _cipher(encrypted, offset);
    return _base.write(offset, encrypted);
  }

  @override
  Future<void> flush() => _base.flush();

  @override
  Future<void> close() => _base.close();

  @override
  Future<int> get size => _base.size;

  @override
  Future<void> truncate(int size) => _base.truncate(size);

  @override
  int? get sizeSync => _base.sizeSync;

  @override
  Uint8List? readSync(int offset, int size) {
    final data = _base.readSync(offset, size);
    if (data != null) _cipher(data, offset);
    return data;
  }

  @override
  bool get needsExplicitFlush => _base.needsExplicitFlush;

  @override
  bool writeSync(int offset, Uint8List data) {
    final encrypted = Uint8List.fromList(data);
    _cipher(encrypted, offset);
    return _base.writeSync(offset, encrypted);
  }
}
