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

    // Group adjacent/overlapping writes by bounds only (no copying yet) —
    // copying on every merge step here would re-copy the whole accumulated
    // range for each additional entry, i.e. O(n^2) bytes for n writes to a
    // contiguous region (exactly what sequential document inserts produce).
    //
    // Only writes that TOUCH or OVERLAP (no gap) are grouped — the merged
    // buffer below is built with setRange() calls that cover only the bytes
    // each entry actually specifies, so a real gap between two writes would
    // be left as zeros and clobber whatever pre-existing bytes lived there.
    // Bridging small gaps was tried and reverted: it silently zeroed
    // untouched bytes between writes (e.g. header sub-fields written by
    // separate calls within one transaction).
    final groupBounds = <int>[]; // pairs of (startIndex, endIndex) into _pendingWrites
    int groupStart = 0;
    int rangeEnd = _pendingWrites.first.offset + _pendingWrites.first.data.length;

    for (int i = 1; i < _pendingWrites.length; i++) {
      final next = _pendingWrites[i];
      if (next.offset <= rangeEnd) {
        final nextEnd = next.offset + next.data.length;
        if (nextEnd > rangeEnd) rangeEnd = nextEnd;
      } else {
        groupBounds.add(groupStart);
        groupBounds.add(i);
        groupStart = i;
        rangeEnd = next.offset + next.data.length;
      }
    }
    groupBounds.add(groupStart);
    groupBounds.add(_pendingWrites.length);

    // Second pass: allocate exactly one buffer per group and paint each
    // entry into it once — in SEQ (temporal) order, not offset order. Offset
    // order only decided the group's bounds above; two overlapping entries
    // at DIFFERENT offsets can sort in the OPPOSITE order from when they
    // were actually written (e.g. a single write at offset X, then later a
    // wider write starting at X, then — earlier than that wider write but
    // at offset X+something — a third write that offset-sorts AFTER it).
    // Painting in offset order would let that earlier write clobber the
    // later, wider one. Re-sorting each group by seq restores "last write
    // wins" by real time regardless of how offsets happened to sort.
    for (int g = 0; g < groupBounds.length; g += 2) {
      final start = groupBounds[g];
      final end = groupBounds[g + 1];

      // Single-entry group — the common case for small, spread-out writes:
      // write its data directly, no merge buffer needed.
      if (end - start == 1) {
        final entry = _pendingWrites[start];
        await _inner.write(entry.offset, entry.data);
        continue;
      }

      final rangeOffset = _pendingWrites[start].offset;
      int rangeLen = 0;
      for (int i = start; i < end; i++) {
        final entry = _pendingWrites[i];
        final entryEnd = entry.offset - rangeOffset + entry.data.length;
        if (entryEnd > rangeLen) rangeLen = entryEnd;
      }
      final merged = Uint8List(rangeLen);
      final group = _pendingWrites.sublist(start, end)
        ..sort((a, b) => a.seq.compareTo(b.seq));
      for (final entry in group) {
        final relOffset = entry.offset - rangeOffset;
        merged.setRange(relOffset, relOffset + entry.data.length, entry.data);
      }
      await _inner.write(rangeOffset, merged);
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
