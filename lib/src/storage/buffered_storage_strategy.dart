import 'dart:typed_data';
import 'storage_strategy.dart';

/// A WAL (Write-Ahead Log) entry.
class _WalEntry {
  final int offset;
  final Uint8List data;
  final int seq; // insertion order — "last write wins" for same-offset entries
  _WalEntry(this.offset, this.data, this.seq);
}

/// Buffered storage strategy — wraps any StorageStrategy with two optimizations:
/// 
/// 1. **Write Buffer**: Accumulates writes in RAM, flushing to disk only when
///    [commit()] is called or the buffer exceeds [maxPendingBytes].
/// 2. **Write Coalescing**: Merges adjacent writes into a single I/O operation,
///    turning 10k individual writes into ~10 large sequential writes.
/// 
/// This is the primary reason FastDB should be 10x faster on bulk inserts.
class BufferedStorageStrategy implements StorageStrategy {
  final StorageStrategy _inner;

  @override
  StorageStrategy get innerStorage => _inner;
  final int maxPendingBytes;

  final List<_WalEntry> _pendingWrites = [];
  int _pendingSize = 0;
  int _seq = 0;

  // Shadow write map for fast reads of uncommitted data: offset → data
  final Map<int, Uint8List> _writeShadow = {};
  int _shadowSize = 0;

  BufferedStorageStrategy(
    this._inner, {
    this.maxPendingBytes = 256 * 1024, // auto-flush at 256KB
  });

  @override
  Future<void> open() => _inner.open();

  @override
  Future<int> get size async {
    final base = await _inner.size;
    return base > _shadowSize ? base : _shadowSize;
  }

  @override
  Future<Uint8List> read(int offset, int sz) async {
    // Check shadow first (uncommitted writes are visible immediately)
    final shadow = _writeShadow[offset];
    if (shadow != null && shadow.length >= sz) {
      return Uint8List.fromList(shadow.sublist(0, sz));
    }
    return _inner.read(offset, sz);
  }

  /// Buffers a write. Actual disk I/O is deferred until [commit()].
  @override
  Future<void> write(int offset, Uint8List data) async {
    _pendingWrites.add(_WalEntry(offset, data, _seq++));
    _writeShadow[offset] = data;
    _pendingSize += data.length;

    final end = offset + data.length;
    if (end > _shadowSize) _shadowSize = end;

    // Auto-flush when buffer is too large
    if (_pendingSize >= maxPendingBytes) {
      await commit();
    }
  }

  /// Commits all buffered writes to the underlying storage in a single pass.
  /// Uses write coalescing: merges overlapping/adjacent writes into one I/O call.
  /// Newer writes always overwrite older ones within the merged range
  /// (entries are applied in insertion order).
  Future<void> commit() async {
    if (_pendingWrites.isEmpty) return;

    // Sort by offset for sequential I/O (avoids random seeks).
    // Tie-break by insertion order: List.sort is NOT stable, and for same-offset
    // writes the LAST one must win.
    _pendingWrites.sort((a, b) {
      if (a.offset != b.offset) return a.offset.compareTo(b.offset);
      return a.seq.compareTo(b.seq);
    });

    // Coalesce adjacent/overlapping writes
    final coalesced = <_WalEntry>[];
    var cur = _pendingWrites.first;

    for (int i = 1; i < _pendingWrites.length; i++) {
      final next = _pendingWrites[i];
      final curEnd = cur.offset + cur.data.length;

      if (next.offset <= curEnd + 512) {
        // Merge: extend current range to cover both, then apply `next` on top
        // (it is newer). This also handles `next` fully contained in `cur` —
        // previously those newer bytes were silently discarded (data corruption).
        final nextEnd = next.offset + next.data.length;
        final newLen = (nextEnd > curEnd ? nextEnd : curEnd) - cur.offset;
        final merged = Uint8List(newLen);
        merged.setRange(0, cur.data.length, cur.data);
        merged.setRange(next.offset - cur.offset, next.offset - cur.offset + next.data.length, next.data);
        cur = _WalEntry(cur.offset, merged, cur.seq);
      } else {
        coalesced.add(cur);
        cur = next;
      }
    }
    coalesced.add(cur);

    // Single flush per coalesced range
    for (final entry in coalesced) {
      await _inner.write(entry.offset, entry.data);
    }

    await _inner.flush();
    _pendingWrites.clear();
    _writeShadow.clear();
    _pendingSize = 0;
  }

  @override
  Future<void> flush() => commit();

  @override
  Future<void> truncate(int size) => _inner.truncate(size);

  // Disk-backed: no synchronous fast paths.
  @override int? get sizeSync => null;
  @override Uint8List? readSync(int offset, int size) => null;
  @override bool get needsExplicitFlush => true;
  @override bool writeSync(int offset, Uint8List data) => false;

  @override
  Future<void> close() async {
    await commit();
    await _inner.close();
  }

  int get pendingBytes => _pendingSize;
  int get pendingWrites => _pendingWrites.length;
}
