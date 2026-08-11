import 'dart:typed_data';
import 'storage_strategy.dart';
import '../crc32.dart' as crc;

/// WAL entry types
const int _kEntryWrite = 1;
const int _kEntryCommit = 2;
const int _kEntryTruncate = 3;

/// WAL (Write-Ahead Log) storage strategy.
/// 
/// Every write is first recorded to a WAL file BEFORE being applied to the
/// main database file. On crash, the WAL is replayed/rolled back on next open.
/// 
/// WAL entry format (binary):
///   [0..3]   magic: 0xFADBWAL (4 bytes)
///   [4]      type: 1=write, 2=commit, 3=truncate (1 byte)
///   For type 3 the offset field holds the target size and length is 0.
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
  int _txBufferedBytes = 0;

  /// Truncate recorded inside the current transaction, applied to the main
  /// file at commit time (BEFORE the transaction's writes). This is what
  /// makes compact() crash-safe: previously truncate() hit the main file
  /// immediately, so a failure mid-compact destroyed documents that had not
  /// been rewritten yet. Constraint: within one transaction the truncate is
  /// expected to precede any write that targets the truncated region (the
  /// only in-tree caller, compact, truncates first).
  int? _txTruncateTo;

  /// True between flushing the COMMIT marker to the WAL and finishing the
  /// apply to the main file. Once the marker is persisted, the transaction
  /// has passed its atomic point of no return: a failure during apply must
  /// NOT be followed by a WAL checkpoint in [rollback] — that would destroy
  /// a committed (but half-applied) transaction. Recovery replays it instead.
  bool _commitMarkerWritten = false;

  /// Set when a committed transaction failed during apply. The main file may
  /// be partially written and the WAL holds the only complete copy of the
  /// transaction — so the strategy must NOT accept further operations (their
  /// WAL entries would be replayed AFTER the pending transaction, onto a
  /// layout they were never written for — that destroyed documents in
  /// scenario B/C of wal_truncate_tx_test.dart). Close and reopen to recover.
  bool _poisoned = false;

  void _checkUsable() {
    if (_poisoned) {
      throw StateError(
          'WAL: a committed transaction failed while applying to the main '
          'file. Close and reopen the database so recovery can finish '
          'applying it — further operations are blocked to prevent '
          'corruption.');
    }
  }

  /// Metadata of entries already streamed to the WAL file during the current
  /// transaction (offset in main file, data length, position in WAL file).
  /// Streaming bounds RAM usage of huge transactions (e.g. insertAll of 100k
  /// docs) — the entry DATA is read back from the WAL file at commit time.
  final List<({int offset, int length, int walPos})> _txStreamed = [];

  /// Above this many buffered bytes, transaction writes are streamed directly
  /// to the WAL file instead of being buffered in RAM.
  static const int _txStreamThreshold = 8 * 1024 * 1024; // 8 MB

  /// Rolling buffer for streamed entries' ENCODED bytes (header+data+CRC),
  /// flushed to the WAL file every [_streamFlushBytes] instead of once per
  /// entry — turns e.g. 1M individual `wal.write()` syscalls (one per small
  /// document, ~75% of a 1M-doc `insertAll`'s total time) into a couple
  /// hundred. Always flushed before the entry data is needed elsewhere (a
  /// commit, or a read-your-writes lookup) — see [_flushStreamBuffer].
  final BytesBuilder _streamBuffer = BytesBuilder();
  int _streamBufferBytes = 0;
  static const int _streamFlushBytes = 4 * 1024 * 1024; // 4 MB

  /// The WAL is checkpointed (truncated) only when it exceeds this size —
  /// not after every commit (that was a truncate+fsync storm per operation).
  static const int _checkpointThreshold = 1024 * 1024; // 1 MB

  // Current write position in the WAL
  int _walPos = 0;

  WalStorageStrategy({
    required StorageStrategy main,
    required StorageStrategy wal,
  })  : _main = main,
        _wal = wal;

  /// Returns the underlying main storage strategy.
  StorageStrategy get main => _main;

  /// For capability/path traversal, the "wrapped" storage is the main file.
  @override
  StorageStrategy get innerStorage => _main;

  // ─── Open / Recover ──────────────────────────────────────────────────────

  @override
  Future<void> open() async {
    _poisoned = false;
    await _main.open();
    await _wal.open();
    await _recover();
  }

  /// Reads the WAL file and replays committed transactions to main storage.
  ///
  /// Each call to [commit()] writes one or more WRITE entries followed by a
  /// COMMIT marker to the WAL file.  Between checkpoints the WAL can therefore
  /// contain several completed transactions followed by a partial (uncommitted)
  /// transaction that was interrupted by a crash.
  ///
  /// The old implementation collected **all** WRITE entries and set `hasCommit`
  /// if **any** COMMIT was present.  That meant that uncommitted entries from a
  /// later transaction were replayed whenever an earlier transaction had
  /// committed — causing silent corruption.
  ///
  /// The correct approach tracks "pending" entries per transaction.  A COMMIT
  /// moves the pending list to the committed list; any entries still pending at
  /// the end of the file are discarded.
  Future<void> _recover() async {
    final walSize = await _wal.size;
    if (walSize == 0) { _walPos = 0; return; }

    final raw = await _wal.read(0, walSize);

    // Committed entries across all fully-committed transactions.
    final committedEntries = <_WalEntry>[];
    // Entries belonging to the transaction currently being parsed (not yet committed).
    final pendingEntries = <_WalEntry>[];
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
          // Verify the COMMIT marker's own checksum (4 bytes follow the 25-byte header).
          // ALWAYS advance past the CRC slot, even if truncated — otherwise offset
          // never moves and the loop spins forever (mobile infinite-loop bug).
          bool commitValid = false;
          if (offset + 4 <= raw.length) {
            final storedCrc = _readInt32(raw, offset);
            final computedCrc = _crc32(raw.sublist(offset - 25, offset));
            commitValid = (storedCrc == computedCrc);
          }
          // Advance regardless — clamped to raw.length if truncated.
          offset += 4;

          if (commitValid) {
            // Move all pending entries for this transaction to the committed list.
            committedEntries.addAll(pendingEntries);
          }
          // Whether valid or not, clear pending — entries without a valid COMMIT
          // are discarded (uncommitted transaction, e.g. crash mid-commit).
          pendingEntries.clear();
          continue;
        }

        if (type == _kEntryWrite) {
          // Need room for data + trailing 4-byte CRC.
          if (offset + length + 4 > raw.length) break; // Truncated entry
          final data = raw.sublist(offset, offset + length);

          // Verify checksum
          final storedCrc = _readInt32(raw, offset + length);
          final computedCrc = _crc32(raw.sublist(offset - 25, offset + length));
          if (storedCrc != computedCrc) break; // Checksum mismatch = corrupt

          // Suppress unused variable warning — txId is stored in the file for
          // forensic / debugging purposes but grouping is done via pending list.
          // ignore: unused_local_variable
          final _ = txId;
          pendingEntries.add(_WalEntry(txId: txId, offset: writeOffset, data: data));
          offset += length + 4; // data + checksum
          continue;
        }

        if (type == _kEntryTruncate) {
          // Truncate entry: offset field holds the target size, no data —
          // just the trailing 4-byte CRC over the 25-byte header.
          if (offset + 4 > raw.length) break;
          final storedCrc = _readInt32(raw, offset);
          final computedCrc = _crc32(raw.sublist(offset - 25, offset));
          if (storedCrc != computedCrc) break;
          pendingEntries.add(_WalEntry(
              txId: txId,
              offset: writeOffset,
              data: Uint8List(0),
              isTruncate: true));
          offset += 4;
          continue;
        }

        // Unknown entry type — corrupt WAL, stop parsing.
        break;
      }
    } catch (_) {
      // Truncated or corrupt WAL — discard the incomplete transaction.
    }
    // Any remaining pendingEntries are from an uncommitted transaction — discard them.

    if (committedEntries.isNotEmpty) {
      // Replay committed writes to main file — idempotent: skip writes whose
      // data already matches what is on disk (handles double-recovery on crash).
      for (final entry in committedEntries) {
        if (entry.isTruncate) {
          // Truncate is inherently idempotent — applying it twice is a no-op.
          await _main.truncate(entry.offset);
          continue;
        }
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
    _checkUsable();
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
    _txTruncateTo = null;
    _commitMarkerWritten = false;
  }

  /// Commits the current transaction.
  Future<void> commit() async {
    if (!_txOpen) return;

    // 0. Flush any streamed entries still sitting in the rolling buffer so
    //    _walPos is correct before the block below appends at it.
    await _flushStreamBuffer();

    // 1. Write all buffered entries + the COMMIT marker to the WAL file in a
    //    SINGLE write call (streamed entries are already there). The COMMIT
    //    marker is the atomic point of no return. A recorded truncate is
    //    encoded FIRST so replay order matches commit order.
    final walBytes = BytesBuilder();
    final truncateTo = _txTruncateTo;
    if (truncateTo != null) {
      _encodeWalEntry(
          walBytes, _kEntryTruncate, _txId, truncateTo, Uint8List(0));
    }
    for (final entry in _txEntries) {
      _encodeWalEntry(walBytes, _kEntryWrite, entry.txId, entry.offset, entry.data);
    }
    _encodeWalEntry(walBytes, _kEntryCommit, _txId, 0, Uint8List(0));
    final bytes = walBytes.toBytes();
    await _wal.write(_walPos, bytes);
    _walPos += bytes.length;
    await _wal.flush();
    // Atomic point of no return: the COMMIT marker is durable in the WAL.
    _commitMarkerWritten = true;

    // 2. Apply writes to main file (buffered from RAM, streamed read back
    //    from the WAL file to keep RAM bounded on huge transactions).
    //    The truncate is applied first — same order as in the WAL.
    try {
      if (truncateTo != null) {
        await _main.truncate(truncateTo);
      }
      await _applyCoalesced(_txEntries);
      await _applyStreamed(_txStreamed);
      await _main.flush();
    } catch (e) {
      // Committed but half-applied: block further operations until recovery.
      _poisoned = true;
      rethrow;
    }
    // Entries are durable on the main file now — the WAL may be discarded.
    _commitMarkerWritten = false;

    _txOpen = false;
    _txEntries.clear();
    _txStreamed.clear();
    _txBufferedBytes = 0;
    _txTruncateTo = null;

    // Checkpoint policy: truncate the WAL only when it exceeds the threshold.
    // The multi-transaction recovery is correct, so keeping several committed
    // transactions in the WAL between checkpoints is safe and avoids a
    // truncate+fsync per commit. _walPos keeps advancing until then.
    if (_walPos >= _checkpointThreshold) {
      await _checkpoint();
    }
  }

  /// Rolls back the current transaction (discards buffered writes).
  Future<void> rollback() async {
    _txOpen = false;
    _txEntries.clear();
    _txStreamed.clear();
    _txBufferedBytes = 0;
    _txTruncateTo = null;
    // Discard any streamed bytes not yet flushed. Already-flushed ones carry
    // no COMMIT marker either, so the checkpoint below (or recovery, if the
    // process dies first) discards them the same way it already did before
    // stream buffering existed.
    _streamBuffer.clear();
    _streamBufferBytes = 0;
    if (_commitMarkerWritten) {
      // The COMMIT marker is already durable in the WAL: this transaction
      // passed its atomic point and a failure happened DURING APPLY.
      // Do NOT checkpoint — the entries must survive so recovery can finish
      // applying them on next open (replay is idempotent). Clearing the RAM
      // buffers above is safe: the commit bundle in the WAL file contains
      // everything.
      _commitMarkerWritten = false;
      return;
    }
    // Truncate streamed entries of the aborted transaction so the WAL does
    // not accumulate dead data (they carry no COMMIT marker, so recovery
    // would discard them anyway — this just reclaims the space).
    if (_walPos > 0) {
      await _checkpoint();
    }
    // WAL entries are ignored on next recovery since there's no COMMIT marker
  }

  /// Applies buffered [entries] to [_main], coalescing adjacent/overlapping
  /// writes into as few I/O calls as possible. Sequential document inserts
  /// (and page-flush ranges) write at contiguous offsets, so a transaction of
  /// N small writes typically collapses into a handful of large ones —
  /// turning N syscalls into a few.
  ///
  /// Only entries that TOUCH or OVERLAP (no gap) are grouped together — the
  /// merged buffer is built with setRange() calls that cover only the bytes
  /// each entry actually specifies, so bridging a real gap between two
  /// writes would leave zeros there and clobber whatever pre-existing bytes
  /// (from an earlier, already-committed transaction) lived in that gap —
  /// e.g. the header's clean-shutdown-flag byte sitting between the header
  /// and free-page-list sub-fields, when only those two (not the flag) are
  /// written in the same transaction. Safe regardless of grouping otherwise:
  /// the WAL already holds each entry individually and durably (written
  /// before this method runs), and [_recover] always replays committed
  /// entries at their ORIGINAL granularity with an idempotent "already
  /// applied?" check — this method only changes how many I/O calls the
  /// (already-durable) apply step takes, never what ends up on disk.
  Future<void> _applyCoalesced(List<_WalEntry> entries) async {
    if (entries.isEmpty) return;
    if (entries.length == 1) {
      await _main.write(entries.first.offset, entries.first.data);
      return;
    }

    // Sort by offset to find contiguous/overlapping GROUPS only — this
    // ordering is not used to decide which write wins an overlap (see the
    // painting step below, which re-sorts each group by original index).
    final order = List<int>.generate(entries.length, (i) => i)
      ..sort((a, b) {
        final oa = entries[a].offset, ob = entries[b].offset;
        if (oa != ob) return oa.compareTo(ob);
        return a.compareTo(b);
      });

    int i = 0;
    while (i < order.length) {
      // First pass: grow the group by comparing bounds only (no copying) —
      // copying per step here would re-copy the whole accumulated range for
      // every additional entry (O(n^2) bytes for n contiguous writes).
      int groupEnd = i;
      int rangeEnd = entries[order[i]].offset + entries[order[i]].data.length;
      while (groupEnd + 1 < order.length) {
        final next = entries[order[groupEnd + 1]];
        if (next.offset > rangeEnd) break;
        final nextEnd = next.offset + next.data.length;
        if (nextEnd > rangeEnd) rangeEnd = nextEnd;
        groupEnd++;
      }

      // Second pass: allocate exactly one buffer for the group and paint each
      // entry into it once — in ORIGINAL (temporal) order, not offset order.
      // Offset order only decided the group's bounds above; two entries can
      // overlap while sorting in the OPPOSITE order from when they were
      // actually written (e.g. a single-page write at offset X followed
      // later by a two-page write starting at the SAME offset X — same
      // offset tie is fine, but a third write at X+pageSize from EARLIER
      // than the two-page write sorts AFTER it purely by offset). Painting
      // in offset order would let that earlier write clobber the later one.
      // Sorting group members back to original-index order restores "last
      // write wins" by real time regardless of how offsets happened to sort.
      final rangeOffset = entries[order[i]].offset;
      final merged = Uint8List(rangeEnd - rangeOffset);
      final groupOriginalIndices = [for (int k = i; k <= groupEnd; k++) order[k]]..sort();
      for (final idx in groupOriginalIndices) {
        final e = entries[idx];
        final rel = e.offset - rangeOffset;
        merged.setRange(rel, rel + e.data.length, e.data);
      }
      await _main.write(rangeOffset, merged);
      i = groupEnd + 1;
    }
  }

  /// Above this many bytes, streamed entries are read back from the WAL file
  /// and applied to [_main] in bounded chunks rather than all at once —
  /// keeps peak RAM proportional to the chunk size, not to the whole
  /// transaction (re-reading everything into RAM at once would defeat the
  /// point of streaming, which exists to bound RAM for huge transactions).
  static const int _applyChunkBytes = 8 * 1024 * 1024; // 8 MB

  /// Applies entries that were streamed straight to the WAL file during a
  /// huge transaction (see [_txStreamThreshold]) to [_main].
  ///
  /// Streamed entries were appended back-to-back to the WAL file (nothing
  /// else writes to it mid-transaction), so a whole chunk's worth of entries
  /// — headers, data and CRCs included — can be fetched with ONE read call
  /// instead of one read per entry, then coalesced onto [_main] the same way
  /// [_applyCoalesced] does for RAM-buffered entries. This is what makes
  /// bulk-inserting e.g. 1M small documents (which blows well past the 8MB
  /// RAM-buffering threshold) apply in a handful of large I/O calls instead
  /// of ~2M tiny ones (one read + one write per document).
  Future<void> _applyStreamed(
      List<({int offset, int length, int walPos})> streamed) async {
    if (streamed.isEmpty) return;

    int i = 0;
    while (i < streamed.length) {
      // Grow the chunk while it stays within the RAM budget (a single entry
      // larger than the budget still gets its own chunk of exactly one).
      int j = i;
      int bytes = streamed[i].length;
      while (j + 1 < streamed.length &&
          bytes + streamed[j + 1].length <= _applyChunkBytes) {
        j++;
        bytes += streamed[j].length;
      }

      final chunkStart = streamed[i].walPos;
      final last = streamed[j];
      final chunkEnd = last.walPos + 25 + last.length + 4; // +25 header, +4 CRC
      final raw = await _wal.read(chunkStart, chunkEnd - chunkStart);

      final entries = <_WalEntry>[];
      for (int k = i; k <= j; k++) {
        final s = streamed[k];
        final dataStart = s.walPos - chunkStart + 25; // skip this entry's header
        entries.add(_WalEntry(
            txId: _txId,
            offset: s.offset,
            data: Uint8List.sublistView(raw, dataStart, dataStart + s.length)));
      }
      await _applyCoalesced(entries);

      i = j + 1;
    }
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
    _checkUsable();
    if (_txOpen) {
      if (_txBufferedBytes + data.length <= _txStreamThreshold) {
        // Small transactions: buffer in RAM (fast path).
        _txEntries.add(_WalEntry(txId: _txId, offset: offset, data: data));
        _txBufferedBytes += data.length;
      } else {
        // Huge transactions (e.g. insertAll of 1M docs): the entry's data is
        // never held in RAM as a whole (bounds RAM) — its ENCODED bytes go
        // into a small rolling buffer instead, flushed to the WAL file every
        // few MB rather than with one write() syscall per entry.
        final walPos = _walPos + _streamBufferBytes;
        _encodeWalEntry(_streamBuffer, _kEntryWrite, _txId, offset, data);
        _streamBufferBytes += 25 + data.length + 4; // header + data + CRC
        _txStreamed.add((offset: offset, length: data.length, walPos: walPos));
        if (_streamBufferBytes >= _streamFlushBytes) {
          await _flushStreamBuffer();
        }
      }
    } else {
      // Auto-wrap in a single-op transaction
      await beginTransaction();
      _txEntries.add(_WalEntry(txId: _txId, offset: offset, data: data));
      _txBufferedBytes += data.length;
      await commit();
    }
  }

  @override
  Future<Uint8List> read(int offset, int size) async {
    _checkUsable();
    if (!_txOpen ||
        (_txEntries.isEmpty &&
            _txStreamed.isEmpty &&
            _txTruncateTo == null)) {
      return _main.read(offset, size);
    }
    // Read-your-writes: overlay pending transaction writes (last write wins)
    // on top of the main file content, so a transaction sees its own
    // uncommitted writes — including regions beyond the main file's current
    // end (the `size` getter already reports the virtual end of file).
    //
    // If a truncate is pending, main-file content at/above the truncate
    // point is already logically gone — do not serve it (it is stale).
    final trunc = _txTruncateTo;
    final int baseSize;
    if (trunc == null) {
      baseSize = size;
    } else if (offset >= trunc) {
      baseSize = 0;
    } else {
      baseSize = (offset + size > trunc) ? trunc - offset : size;
    }
    final base = baseSize > 0 ? await _main.read(offset, baseSize) : Uint8List(0);
    final result = Uint8List(size);
    final baseLen = base.length < size ? base.length : size;
    if (baseLen > 0) result.setRange(0, baseLen, base);
    final readEnd = offset + size;

    void overlay(int entryOffset, Uint8List entryData) {
      final entryEnd = entryOffset + entryData.length;
      if (entryEnd <= offset || entryOffset >= readEnd) return; // no overlap
      final srcStart = offset > entryOffset ? offset - entryOffset : 0;
      final dstStart = entryOffset > offset ? entryOffset - offset : 0;
      var copyLen = entryData.length - srcStart;
      if (copyLen > size - dstStart) copyLen = size - dstStart;
      if (copyLen > 0) {
        result.setRange(dstStart, dstStart + copyLen, entryData, srcStart);
      }
    }

    for (final entry in _txEntries) {
      overlay(entry.offset, entry.data);
    }
    // Streamed entries live in the WAL file (RAM-bounded transactions) — but
    // some may still be sitting in the unflushed rolling buffer rather than
    // actually on disk yet. Flush first so every entry below is readable.
    if (_streamBufferBytes > 0) await _flushStreamBuffer();
    for (final s in _txStreamed) {
      if (s.offset + s.length <= offset || s.offset >= readEnd) continue;
      final data = await _wal.read(s.walPos + 25, s.length); // +25: header
      overlay(s.offset, data);
    }
    return result;
  }

  @override
  Future<void> flush() => _main.flush();

  @override
  Future<void> truncate(int size) async {
    _checkUsable();
    if (_txOpen) {
      // Deferred: applied to the main file at commit time.
      _txTruncateTo = size;
    } else {
      // Auto-wrap in a single-op transaction, mirroring write().
      await beginTransaction();
      _txTruncateTo = size;
      await commit();
    }
  }

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
    if (!_txOpen ||
        (_txEntries.isEmpty &&
            _txStreamed.isEmpty &&
            _txTruncateTo == null)) {
      return mainSize;
    }
    // During an open transaction, pending (uncommitted) writes are not yet
    // reflected in _main's size. Return the maximum write extent across all
    // buffered/streamed entries so that callers like _dataOffset and
    // allocatePage() see the correct "virtual end of file". A pending
    // truncate lowers the floor of that virtual size.
    var maxExtent = _txTruncateTo ?? mainSize;
    for (final entry in _txEntries) {
      final extent = entry.offset + entry.data.length;
      if (extent > maxExtent) maxExtent = extent;
    }
    for (final s in _txStreamed) {
      final extent = s.offset + s.length;
      if (extent > maxExtent) maxExtent = extent;
    }
    return maxExtent;
  }

  // ─── WAL Binary Writers ──────────────────────────────────────────────────

  /// Appends one WAL entry (25-byte header + data + 4-byte CRC32) to [buf].
  void _encodeWalEntry(
      BytesBuilder buf, int type, int txId, int offset, Uint8List data) {
    final entryBytes = BytesBuilder();
    entryBytes.add(_kMagic);
    entryBytes.addByte(type);
    _addInt64(entryBytes, txId);
    _addInt64(entryBytes, offset);
    _addInt32(entryBytes, data.length);
    entryBytes.add(data);
    final payload = entryBytes.toBytes();
    buf.add(payload);
    _addInt32(buf, _crc32(payload));
  }

  /// Flushes the rolling stream buffer (see [_streamBuffer]) to the WAL file
  /// with one write() call, if it has anything in it. Called whenever the
  /// buffer crosses [_streamFlushBytes], and unconditionally before anything
  /// that needs the streamed bytes to actually be on disk: [commit] (so
  /// [_walPos] is correct before the RAM-buffered entries + COMMIT marker are
  /// appended) and [read] (so the read-your-writes overlay for [_txStreamed]
  /// entries doesn't read stale/missing bytes for ones not yet flushed).
  Future<void> _flushStreamBuffer() async {
    if (_streamBufferBytes == 0) return;
    final bytes = _streamBuffer.takeBytes();
    await _wal.write(_walPos, bytes);
    _walPos += bytes.length;
    _streamBufferBytes = 0;
  }

  // ─── Checksum ────────────────────────────────────────────────────────────

  /// Shared table-driven CRC32 (see lib/src/crc32.dart).
  static int _crc32(Uint8List data) => crc.crc32(data);

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

  /// True for truncate entries — [offset] holds the target size, [data] is empty.
  final bool isTruncate;
  _WalEntry(
      {required this.txId,
      required this.offset,
      required this.data,
      this.isTruncate = false});
}
