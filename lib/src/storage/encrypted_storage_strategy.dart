import 'dart:collection';
import 'dart:convert';
import 'dart:math' show Random;
import 'dart:typed_data';
import '_aes256_ctr.dart';
import '_sha256.dart';
import 'storage_strategy.dart';

/// A wrapper [StorageStrategy] that transparently encrypts AND authenticates
/// all data (pure Dart, zero external dependencies).
///
/// ### Format v2 (new files)
/// ```
/// [128-byte header][sector 0][sector 1]...
/// sector = [12-byte random nonce][1024-byte AES-256-CTR ciphertext][16-byte tag]
/// tag    = HMAC-SHA256(macKey, sectorIndex ‖ nonce ‖ ciphertext), truncated
/// ```
/// - Every rewrite of a sector draws a FRESH nonce, so no keystream is ever
///   reused (the v1 format reused one nonce for the whole file — two versions
///   of the same offset, e.g. from a backup, leaked their XOR).
/// - Tampered, swapped or corrupted sectors fail authentication on read
///   instead of decrypting to garbage. A wrong key is reported by open().
/// - Keys: a String password goes through PBKDF2-HMAC-SHA256 with a random
///   salt ([pbkdf2Iterations], stored in the header); a raw 32-byte key
///   ([EncryptedStorageStrategy.withRawKey]) through HMAC-based expansion.
///   For strong protection prefer a random raw key kept in the platform's
///   secure storage over a human password.
/// - Not protected: rolling the whole file (or sectors) back to an OLDER
///   authentic version.
///
/// ### Legacy v1 files
/// Files created by ffastdb <= 0.3.5 (12-byte nonce header, single-nonce CTR,
/// no authentication, non-cryptographic password key) are detected and keep
/// working unchanged — they are NOT upgraded in place. To move one to v2,
/// `exportJson()` it and `importJson()` into a new encrypted database.
/// [isLegacyFormat] tells which format an open file uses.
///
/// ### Thread safety
/// Not thread-safe. Callers must serialise access (FastDB already does this).
class EncryptedStorageStrategy implements StorageStrategy {
  final StorageStrategy _base;
  final String? _password;
  final Uint8List? _rawKey;

  /// PBKDF2 iterations used when a password-protected file is CREATED
  /// (existing files use the count stored in their header).
  final int pbkdf2Iterations;

  /// Default [pbkdf2Iterations]: ~0.2 s on a desktop VM, ~0.6 s on the web.
  static const int defaultPbkdf2Iterations = 100000;

  // ── v2 layout ─────────────────────────────────────────────────────────────
  static const int _headerSize = 128;
  static const int _sector = 1024;
  static const int _nonceLen = 12;
  static const int _tagLen = 16;
  static const int _phys = _nonceLen + _sector + _tagLen;
  static const List<int> _magic = [0x46, 0x46, 0x44, 0x42, 0x45, 0x4E, 0x43, 0x32]; // FFDBENC2
  static const int _kdfRaw = 0;
  static const int _kdfPbkdf2 = 1;

  /// Plaintext sectors kept in memory (64 KB): avoids re-verifying and
  /// re-decrypting hot sectors (header page, recent documents).
  static const int _maxCachedSectors = 64;

  bool _legacy = false;
  late Uint32List _rk; // expanded AES round keys
  HmacSha256? _mac;
  late Uint8List _headerFields; // bytes 0..39 of the v2 header (size patched)
  int _logicalSize = 0;
  final Random _rng = Random.secure();
  final LinkedHashMap<int, Uint8List> _cache = LinkedHashMap();

  // ── v1 (legacy) state ────────────────────────────────────────────────────
  static const int _legacyHeaderSize = 12;
  late Uint8List _nonce12;

  /// Creates an encrypted strategy wrapping [base], protected by
  /// [encryptionKey] (a password, stretched with PBKDF2).
  EncryptedStorageStrategy(this._base, String encryptionKey,
      {this.pbkdf2Iterations = defaultPbkdf2Iterations})
      : _password = encryptionKey,
        _rawKey = null {
    if (encryptionKey.isEmpty) {
      throw ArgumentError('encryptionKey must not be empty');
    }
  }

  /// Creates an encrypted strategy with a pre-derived 32-byte raw key (e.g.
  /// random bytes from the platform's secure storage).
  EncryptedStorageStrategy.withRawKey(this._base, Uint8List rawKey)
      : _password = null,
        _rawKey = Uint8List.fromList(rawKey),
        pbkdf2Iterations = defaultPbkdf2Iterations {
    if (rawKey.length != 32) {
      throw ArgumentError('AES-256 requires exactly 32 bytes');
    }
  }

  /// Returns the underlying base storage strategy.
  StorageStrategy get storage => _base;

  @override
  StorageStrategy get innerStorage => _base;

  /// True when the open file uses the legacy v1 format (see class docs).
  bool get isLegacyFormat => _legacy;

  // ── Open ──────────────────────────────────────────────────────────────────

  @override
  Future<void> open() async {
    await _base.open();
    try {
      await _openEncrypted();
    } catch (_) {
      // Release the base (e.g. its file lock) — the caller gets no handle.
      try {
        await _base.close();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _openEncrypted() async {
    _cache.clear();
    final baseSize = await _base.size;
    if (baseSize == 0) return _createV2();

    final head = await _base.read(0, baseSize < _headerSize ? baseSize : _headerSize);
    if (_startsWithMagic(head)) {
      if (baseSize < _headerSize) {
        throw StateError('Encrypted storage header is corrupted (truncated).');
      }
      return _openV2(head);
    }
    if (baseSize < _legacyHeaderSize) {
      throw StateError(
          'Encrypted storage header is corrupted '
          '(file size $baseSize < required $_legacyHeaderSize bytes).');
    }
    // Legacy v1 file.
    _legacy = true;
    _nonce12 = Uint8List.fromList(head.sublist(0, _legacyHeaderSize));
    _rk = aes256KeyExpand(_rawKey ?? aes256KeyFromPassword(_password!));
  }

  bool _startsWithMagic(Uint8List b) {
    if (b.length < _magic.length) return false;
    for (int i = 0; i < _magic.length; i++) {
      if (b[i] != _magic[i]) return false;
    }
    return true;
  }

  Future<void> _createV2() async {
    _legacy = false;
    final kdf = _password != null ? _kdfPbkdf2 : _kdfRaw;
    final iterations = _password != null ? pbkdf2Iterations : 0;
    final salt = _randomBytes(16);
    _headerFields = Uint8List(40)
      ..setRange(0, 8, _magic)
      ..[8] = 2
      ..[9] = kdf;
    _bd(_headerFields).setUint32(12, iterations, Endian.little);
    _headerFields.setRange(16, 32, salt);
    _deriveKeys(kdf, iterations, salt);
    _logicalSize = 0;
    await _writeHeader();
  }

  void _openV2(Uint8List head) {
    _legacy = false;
    final version = head[8];
    if (version != 2) {
      throw StateError('Unsupported encrypted storage version $version.');
    }
    final kdf = head[9];
    final iterations = _bd(head).getUint32(12, Endian.little);
    final salt = Uint8List.fromList(head.sublist(16, 32));
    if (kdf == _kdfPbkdf2 && _password == null) {
      throw StateError('This database is protected by a password; open it '
          'with EncryptedStorageStrategy(base, password).');
    }
    if (kdf == _kdfRaw && _rawKey == null) {
      throw StateError('This database is protected by a raw key; open it '
          'with EncryptedStorageStrategy.withRawKey(base, key).');
    }
    _deriveKeys(kdf, iterations, salt);
    if (!_equalBytes(head.sublist(40, 56), _keyCheck()) ) {
      throw StateError('EncryptedStorageStrategy: wrong encryption key.');
    }
    if (!_equalBytes(head.sublist(56, 72), _headerTag(head.sublist(0, 56)))) {
      throw StateError('EncryptedStorageStrategy: header authentication failed '
          '(corrupted or tampered file).');
    }
    _headerFields = Uint8List.fromList(head.sublist(0, 40));
    final bd = _bd(head);
    _logicalSize = bd.getUint32(36, Endian.little) * 0x100000000 +
        bd.getUint32(32, Endian.little);
  }

  void _deriveKeys(int kdf, int iterations, Uint8List salt) {
    final Uint8List master;
    if (kdf == _kdfPbkdf2) {
      master = pbkdf2HmacSha256(utf8.encode(_password!), salt, iterations, 32);
    } else {
      master = HmacSha256(_rawKey!).convert([...salt, 0x01]);
    }
    final expand = HmacSha256(master);
    _rk = aes256KeyExpand(expand.convert(utf8.encode('ffastdb/enc')));
    _mac = HmacSha256(expand.convert(utf8.encode('ffastdb/mac')));
  }

  Uint8List _keyCheck() =>
      Uint8List.sublistView(_mac!.convert(utf8.encode('ffastdb/key-check')), 0, _tagLen);

  Uint8List _headerTag(List<int> fields56) =>
      Uint8List.sublistView(_mac!.convert(fields56), 0, _tagLen);

  Future<void> _writeHeader() async {
    final bd = _bd(_headerFields);
    final hi = _logicalSize ~/ 0x100000000;
    bd.setUint32(32, _logicalSize - hi * 0x100000000, Endian.little);
    bd.setUint32(36, hi, Endian.little);
    final header = Uint8List(_headerSize)
      ..setRange(0, 40, _headerFields)
      ..setRange(40, 56, _keyCheck());
    header.setRange(56, 72, _headerTag(Uint8List.sublistView(header, 0, 56)));
    await _base.write(0, header);
  }

  // ── Sectors ───────────────────────────────────────────────────────────────

  int get _sectorCount => (_logicalSize + _sector - 1) ~/ _sector;

  /// Physical bytes of [count] sectors starting at sector [first].
  Future<Uint8List> _readPhysical(int first, int count) =>
      _base.read(_headerSize + first * _phys, count * _phys);

  Uint8List _tag(int index, Uint8List physSector) {
    final idx = Uint8List(8);
    final hi = index ~/ 0x100000000;
    _bd(idx)
      ..setUint32(0, index - hi * 0x100000000, Endian.little)
      ..setUint32(4, hi, Endian.little);
    final h = _mac!.begin()
      ..add(idx)
      ..add(physSector, 0, _nonceLen + _sector);
    return Uint8List.sublistView(_mac!.finish(h), 0, _tagLen);
  }

  /// Verifies and decrypts one physical sector into a fresh plaintext buffer.
  Uint8List _open(int index, Uint8List phys, int at) {
    final sector = Uint8List.sublistView(phys, at, at + _phys);
    final expected = _tag(index, sector);
    for (int i = 0; i < _tagLen; i++) {
      if (sector[_nonceLen + _sector + i] != expected[i]) {
        throw StateError('EncryptedStorageStrategy: authentication failed for '
            'sector $index (corrupted or tampered file).');
      }
    }
    final plain = Uint8List.fromList(
        Uint8List.sublistView(sector, _nonceLen, _nonceLen + _sector));
    aes256CtrXor(_rk, Uint8List.sublistView(sector, 0, _nonceLen), 0, plain);
    return plain;
  }

  /// Encrypts [plain] under a fresh nonce into [out] at [at].
  void _seal(int index, Uint8List plain, Uint8List out, int at) {
    final nonce = _randomBytes(_nonceLen);
    out.setRange(at, at + _nonceLen, nonce);
    final ct = Uint8List.fromList(plain);
    aes256CtrXor(_rk, nonce, 0, ct);
    out.setRange(at + _nonceLen, at + _nonceLen + _sector, ct);
    final tag = _tag(index, Uint8List.sublistView(out, at, at + _phys));
    out.setRange(at + _nonceLen + _sector, at + _phys, tag);
  }

  /// Plaintext of existing sectors [first, first + count), via the cache.
  Future<List<Uint8List>> _plainSectors(int first, int count) async {
    final result = List<Uint8List?>.filled(count, null);
    int? missFirst, missLast;
    for (int i = 0; i < count; i++) {
      final hit = _cache.remove(first + i);
      if (hit != null) {
        _cache[first + i] = hit; // refresh LRU position
        result[i] = hit;
      } else {
        missFirst ??= i;
        missLast = i;
      }
    }
    if (missFirst != null) {
      // One read covering every missing sector.
      final n = missLast! - missFirst + 1;
      final phys = await _readPhysical(first + missFirst, n);
      for (int i = missFirst; i <= missLast; i++) {
        if (result[i] != null) continue;
        final plain = _open(first + i, phys, (i - missFirst) * _phys);
        _remember(first + i, plain);
        result[i] = plain;
      }
    }
    return result.cast<Uint8List>();
  }

  void _remember(int index, Uint8List plain) {
    _cache.remove(index);
    _cache[index] = plain;
    if (_cache.length > _maxCachedSectors) _cache.remove(_cache.keys.first);
  }

  // ── StorageStrategy ───────────────────────────────────────────────────────

  @override
  Future<Uint8List> read(int offset, int size) async {
    if (_legacy) return _legacyRead(offset, size);
    final result = Uint8List(size);
    final end = offset + size < _logicalSize ? offset + size : _logicalSize;
    if (size <= 0 || offset >= end) return result; // beyond EOF reads as zeros
    final first = offset ~/ _sector;
    final last = (end - 1) ~/ _sector;
    final plains = await _plainSectors(first, last - first + 1);
    for (int s = first; s <= last; s++) {
      final sStart = s * _sector;
      final from = offset > sStart ? offset - sStart : 0;
      final to = end < sStart + _sector ? end - sStart : _sector;
      result.setRange(sStart + from - offset, sStart + to - offset,
          plains[s - first], from);
    }
    return result;
  }

  @override
  Future<void> write(int offset, Uint8List data) async {
    if (_legacy) return _legacyWrite(offset, data);
    if (data.isEmpty) return;
    final end = offset + data.length;
    final oldCount = _sectorCount;
    final first = offset ~/ _sector;
    final last = (end - 1) ~/ _sector;
    // A write past EOF materializes the gap sectors (as zeros) so the
    // physical layout stays dense.
    final start = first < oldCount ? first : oldCount;

    // Existing sectors that this write covers only partially must be merged.
    final partial = <int>{};
    if (offset % _sector != 0 && first < oldCount) partial.add(first);
    if (end % _sector != 0 && last < oldCount) partial.add(last);
    final existing = <int, Uint8List>{};
    for (final s in partial) {
      existing[s] = (await _plainSectors(s, 1)).first;
    }

    final out = Uint8List((last - start + 1) * _phys);
    for (int s = start; s <= last; s++) {
      final plain = existing[s] != null
          ? Uint8List.fromList(existing[s]!)
          : Uint8List(_sector); // new, gap or fully overwritten sector
      final sStart = s * _sector;
      if (s >= first) {
        final from = offset > sStart ? offset - sStart : 0;
        final to = end < sStart + _sector ? end - sStart : _sector;
        plain.setRange(from, to, data, sStart + from - offset);
      }
      _seal(s, plain, out, (s - start) * _phys);
      _remember(s, plain);
    }
    await _base.write(_headerSize + start * _phys, out);
    if (end > _logicalSize) {
      _logicalSize = end;
      await _writeHeader();
    }
  }

  @override
  Future<void> truncate(int size) async {
    if (_legacy) return _base.truncate(size + _legacyHeaderSize);
    if (size < 0) size = 0;
    if (size >= _logicalSize) return;
    final newCount = (size + _sector - 1) ~/ _sector;
    _cache.removeWhere((s, _) => s >= newCount);
    // Bytes past the new end inside the last kept sector must read as zeros
    // if the file grows again: re-seal that sector with them cleared.
    if (size % _sector != 0) {
      final s = newCount - 1;
      final plain = Uint8List.fromList((await _plainSectors(s, 1)).first);
      plain.fillRange(size % _sector, _sector, 0);
      final out = Uint8List(_phys);
      _seal(s, plain, out, 0);
      _remember(s, plain);
      await _base.write(_headerSize + s * _phys, out);
    }
    await _base.truncate(_headerSize + newCount * _phys);
    _logicalSize = size;
    await _writeHeader();
  }

  @override
  Future<void> flush() => _base.flush();

  @override
  Future<void> close() {
    _cache.clear();
    return _base.close();
  }

  @override
  Future<int> get size async {
    if (!_legacy) return _logicalSize;
    final s = await _base.size;
    final logical = s - _legacyHeaderSize;
    return logical < 0 ? 0 : logical;
  }

  @override
  int? get sizeSync {
    if (!_legacy) return _logicalSize;
    final s = _base.sizeSync;
    if (s == null) return null;
    final logical = s - _legacyHeaderSize;
    return logical < 0 ? 0 : logical;
  }

  // v2 always goes through the async paths (sector read-modify-write).
  @override
  Uint8List? readSync(int offset, int size) {
    if (!_legacy) return null;
    final data = _base.readSync(offset + _legacyHeaderSize, size);
    if (data != null) aes256CtrXor(_rk, _nonce12, offset, data);
    return data;
  }

  @override
  bool writeSync(int offset, Uint8List data) {
    if (!_legacy) return false;
    final encrypted = Uint8List.fromList(data);
    aes256CtrXor(_rk, _nonce12, offset, encrypted);
    return _base.writeSync(offset + _legacyHeaderSize, encrypted);
  }

  @override
  bool get needsExplicitFlush => _base.needsExplicitFlush;

  // ── Legacy v1 ─────────────────────────────────────────────────────────────

  Future<Uint8List> _legacyRead(int offset, int size) async {
    final data = await _base.read(offset + _legacyHeaderSize, size);
    aes256CtrXor(_rk, _nonce12, offset, data);
    return data;
  }

  Future<void> _legacyWrite(int offset, Uint8List data) {
    final encrypted = Uint8List.fromList(data);
    aes256CtrXor(_rk, _nonce12, offset, encrypted);
    return _base.write(offset + _legacyHeaderSize, encrypted);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Uint8List _randomBytes(int n) {
    final b = Uint8List(n);
    for (int i = 0; i < n; i++) {
      b[i] = _rng.nextInt(256);
    }
    return b;
  }

  static ByteData _bd(Uint8List b) => ByteData.sublistView(b);

  static bool _equalBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
