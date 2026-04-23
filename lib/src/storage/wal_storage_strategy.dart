import 'dart:typed_data';
import 'storage_strategy.dart';

/// WAL entry types
const int _kEntryWrite = 1;
const int _kEntryCommit = 2;

/// WAL (Write-Ahead Log) storage strategy.
/// 
/// Every write is first recorded to a WAL file BEFORE being applied to the
/// main database file. On crash, the WAL is replayed/rolled back on next open.
/// 
/// WAL entry format (binary):
///   [0..3]   magic: 0xFADBWAL (4 bytes)
///   [4]      type: 1=write, 2=commit, 3=checkpoint (1 byte)
///   [5..12]  txId: transaction ID (8 bytes, LE)
///   [13..20] offset: write offset in main file (8 bytes, LE)
///   [21..24] length: data length (4 bytes, LE)
///   [25..N]  data: raw bytes
///   [N+1..N+4] checksum: CRC32 of everything above (4 bytes)
/// 
/// On open:
///   1. Read WAL file from start
///   2. If last entry is COMMIT → replay all entries to main file
///   3. If last entry is NOT COMMIT → crash occurred, discard incomplete tx
///   4. Delete (checkpoint) WAL after successful replay
class WalStorageStrategy implements StorageStrategy {
  static const List<int> _kMagic = [0xFA, 0xDB, 0x57, 0x41]; // "FDBWA"

  final StorageStrategy _main;
  final StorageStrategy _wal;

  // In-progress transaction
  bool _txOpen = false;
  int _txId = 0;
  final List<_WalEntry> _txEntries = [];

  // Current write position in the WAL
  int _walPos = 0;

  WalStorageStrategy({
    required StorageStrategy main,
    required StorageStrategy wal,
  })  : _main = main,
        _wal = wal;

  // ─── Open / Recover ──────────────────────────────────────────────────────

  @override
  Future<void> open() async {
    await _main.open();
    await _wal.open();
    await _recover();
  }

  /// Reads the WAL file and replays committed transactions to main storage.
  Future<void> _recover() async {
    final walSize = await _wal.size;
    if (walSize == 0) { _walPos = 0; return; }

    final raw = await _wal.read(0, walSize);
    final entries = <_WalEntry>[];
    bool hasCommit = false;
    int offset = 0;

    try {
      while (offset + 25 <= raw.length) {
        // Check magic
        if (raw[offset] != _kMagic[0] || raw[offset + 1] != _kMagic[1] ||
            raw[offset + 2] != _kMagic[2] || raw[offset + 3] != _kMagic[3]) {
          break; // Corrupt or end of valid data
        }

        final type = raw[offset + 4];
        final txId = _readInt64(raw, offset + 5);
        final writeOffset = _readInt64(raw, offset + 13);
        final length = _readInt32(raw, offset + 21);
        offset += 25;

        if (type == _kEntryCommit) {
          // Verify the COMMIT marker's own checksum (4 bytes follow the 25-byte header)
          if (offset + 4 <= raw.length) {
            final storedCrc = _readInt32(raw, offset);
            final computedCrc = _crc32(raw.sublist(offset - 25, offset));
            if (storedCrc == computedCrc) hasCommit = true;
            offset += 4;
          }
          continue;
        }

        if (type == _kEntryWrite) {
          if (offset + length > raw.length) break; // Truncated entry
          final data = raw.sublist(offset, offset + length);
          
          // Verify checksum
          final storedCrc = _readInt32(raw, offset + length);
          final computedCrc = _crc32(raw.sublist(offset - 25, offset + length));
          if (storedCrc != computedCrc) break; // Checksum mismatch = corrupt

          entries.add(_WalEntry(txId: txId, offset: writeOffset, data: data));
          offset += length + 4; // data + checksum
        }
      }
    } catch (_) {
      // Truncated or corrupt WAL — discard the incomplete transaction
    }

    if (hasCommit && entries.isNotEmpty) {
      // Replay committed writes to main file — idempotent: skip writes whose
      // data already matches what is on disk (handles double-recovery on crash).
      for (final entry in entries) {
        try {
          final existing = await _main.read(entry.offset, entry.data.length);
          bool alreadyApplied = existing.length == entry.data.length;
          if (alreadyApplied) {
            for (int i = 0; i < existing.length; i++) {
              if (existing[i] != entry.data[i]) { alreadyApplied = false; break; }
            }
          }
          if (!alreadyApplied) await _main.write(entry.offset, entry.data);
        } catch (_) {
          // If we can't read (e.g. offset beyond EOF), just apply.
          await _main.write(entry.offset, entry.data);
        }
      }
      await _main.flush();
    }

    // Checkpoint: clear the WAL after recovery
    await _checkpoint();
  }

  // ─── Transaction API ─────────────────────────────────────────────────────

  /// Begins a WAL transaction. Multiple writes will be atomically committed.
  Future<void> beginTransaction() async {
    if (_txOpen) {
      // Guard: silently rolling back un-committed entries here would cause
      // silent data loss. Throw so callers notice the misuse.
      throw StateError(
          'WAL: beginTransaction() called while a transaction is already open. '
          'Call commit() or rollback() before starting a new transaction.');
    }
    _txOpen = true;
    _txId++;
    _txEntries.clear();
  }

  /// Commits the current transaction.
  Future<void> commit() async {
    if (!_txOpen) return;

    // 1. Write all entries to WAL file
    for (final entry in _txEntries) {
      await _writeWalEntry(_kEntryWrite, entry);
    }

    // 2. Write COMMIT marker (this is the atomic point of no return)
    await _writeCommitMarker();
    await _wal.flush();

    // 3. Apply writes to main file
    for (final entry in _txEntries) {
      await _main.write(entry.offset, entry.data);
    }
    await _main.flush();

    _txOpen = false;
    _txEntries.clear();

    // 4. Checkpoint if WAL is large
    if (await _wal.size > 1024 * 1024) {
      await _checkpoint();
    }
  }

  /// Rolls back the current transaction (discards buffered writes).
  Future<void> rollback() async {
    _txOpen = false;
    _txEntries.clear();
    // WAL entries are ignored on next recovery since there's no COMMIT marker
  }

  /// Truncates the WAL after all entries have been applied to main storage.
  Future<void> _checkpoint() async {
    await _wal.truncate(0);
    await _wal.flush();
    _walPos = 0;
  }

  /// Public checkpoint — truncates the WAL after all changes are committed.
  Future<void> checkpoint() => _checkpoint();

  // ─── StorageStrategy impl ────────────────────────────────────────────────

  @override
  Future<void> write(int offset, Uint8List data) async {
    if (_txOpen) {
      // Buffer in current transaction
      _txEntries.add(_WalEntry(txId: _txId, offset: offset, data: data));
    } else {
      // Auto-wrap in a single-op transaction
      await beginTransaction();
      _txEntries.add(_WalEntry(txId: _txId, offset: offset, data: data));
      await commit();
    }
  }

  @override
  Future<Uint8List> read(int offset, int size) => _main.read(offset, size);

  @override
  Future<void> flush() => _main.flush();

  @override
  Future<void> truncate(int size) => _main.truncate(size);

  // Disk-backed: no synchronous fast paths.
  @override int? get sizeSync => null;
  @override Uint8List? readSync(int offset, int size) => null;
  @override bool get needsExplicitFlush => true;
  @override bool writeSync(int offset, Uint8List data) => false;

  @override
  Future<void> close() async {
    if (_txOpen) await commit(); // Auto-commit on close
    await _main.close();
    await _wal.close();
  }

  @override
  Future<int> get size async {
    final mainSize = await _main.size;
    if (!_txOpen || _txEntries.isEmpty) return mainSize;
    // During an open transaction, pending (uncommitted) writes are not yet
    // reflected in _main's size. Return the maximum write extent across all
    // buffered entries so that callers like _dataOffset and allocatePage()
    // see the correct "virtual end of file" and don't overlap pending data.
    var maxExtent = mainSize;
    for (final entry in _txEntries) {
      final extent = entry.offset + entry.data.length;
      if (extent > maxExtent) maxExtent = extent;
    }
    return maxExtent;
  }

  // ─── WAL Binary Writers ──────────────────────────────────────────────────

  Future<void> _writeWalEntry(int type, _WalEntry entry) async {
    final buf = BytesBuilder();

    buf.add(_kMagic);
    buf.addByte(type);
    _addInt64(buf, entry.txId);
    _addInt64(buf, entry.offset);
    _addInt32(buf, entry.data.length);
    buf.add(entry.data);

    final payload = buf.toBytes();
    final crc = _crc32(payload);
    
    final full = BytesBuilder();
    full.add(payload);
    _addInt32BytesBuilder(full, crc);

    final bytes = full.toBytes();
    await _wal.write(_walPos, bytes);
    _walPos += bytes.length;
  }

  Future<void> _writeCommitMarker() async {
    final buf = BytesBuilder();
    buf.add(_kMagic);
    buf.addByte(_kEntryCommit);
    _addInt64(buf, _txId);
    _addInt64(buf, 0);
    _addInt32(buf, 0);
    final payload = buf.toBytes();
    final crc = _crc32(payload);
    final full = BytesBuilder();
    full.add(payload);
    _addInt32BytesBuilder(full, crc);
    final bytes = full.toBytes();
    await _wal.write(_walPos, bytes);
    _walPos += bytes.length;
  }

  // ─── Checksum ────────────────────────────────────────────────────────────

  /// Simple CRC32 implementation using the standard polynomial.
  static int _crc32(Uint8List data) {
    int crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc ^= byte;
      for (int i = 0; i < 8; i++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
      }
    }
    return crc ^ 0xFFFFFFFF;
  }

  // ─── Binary Helpers ──────────────────────────────────────────────────────

  int _readInt32(Uint8List b, int off) =>
      ByteData.sublistView(b, off, off + 4).getUint32(0, Endian.little);

  int _readInt64(Uint8List b, int off) =>
      ByteData.sublistView(b, off, off + 8).getUint64(0, Endian.little);

  void _addInt32(BytesBuilder b, int v) {
    final data = Uint8List(4);
    ByteData.sublistView(data).setUint32(0, v, Endian.little);
    b.add(data);
  }

  void _addInt32BytesBuilder(BytesBuilder b, int v) => _addInt32(b, v);

  void _addInt64(BytesBuilder b, int v) {
    final data = Uint8List(8);
    ByteData.sublistView(data).setUint64(0, v, Endian.little);
    b.add(data);
  }
}

class _WalEntry {
  final int txId;
  final int offset;
  final Uint8List data;
  _WalEntry({required this.txId, required this.offset, required this.data});
}
