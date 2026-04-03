import 'dart:convert';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

import 'web_storage_strategy.dart';

// ── localStorage JS interop via package:web ──────────────────────────────────
// No more manual definitions needed.
// ─────────────────────────────────────────────────────────────────────────────

/// [WebStorageStrategy] with automatic persistence to `localStorage`.
///
/// The entire database buffer is serialised as Base64 under the key
/// `ffastdb:<name>` and restored on the next [open] call, so data
/// survives page reloads.  `localStorage` has a ~5 MB limit per origin.
class LocalStorageStrategy extends WebStorageStrategy {
  LocalStorageStrategy(this._dbName);
  final String _dbName;
  String get _lsKey => 'ffastdb:$_dbName';

  /// Tell FastDB to call flush() after every write so localStorage stays in sync.
  @override
  bool get needsExplicitFlush => true;

  /// True when the buffer has changed since the last [flush()].
  /// Prevents redundant Base64 re-encodes when fastdb calls flush() multiple
  /// times per insert/update/delete.
  bool _dirty = false;

  @override
  Future<void> write(int offset, Uint8List data) async {
    await super.write(offset, data);
    _dirty = true;
  }

  @override
  bool writeSync(int offset, Uint8List data) {
    final result = super.writeSync(offset, data);
    _dirty = true;
    return result;
  }

  @override
  Future<void> open() async {
    try {
      final stored = web.window.localStorage.getItem(_lsKey);
      if (stored != null && stored.isNotEmpty) {
        final bytes = base64Decode(stored);
        await write(0, bytes);
      }
    } catch (_) {
      // Corrupted entry — start fresh (super already has empty buffer).
    }
  }

  @override
  Future<void> flush() async {
    if (!_dirty) return;
    _dirty = false;
    final sz = await size;
    if (sz == 0) {
      web.window.localStorage.removeItem(_lsKey);
      return;
    }
    final snapshot = await read(0, sz);
    try {
      web.window.localStorage.setItem(_lsKey, base64Encode(snapshot));
    } catch (_) {
      // localStorage throws QuotaExceededError (~5 MB limit per origin).
      // Surface a clear message instead of a silent data-loss failure.
      throw StateError(
        'ffastdb: localStorage quota exceeded for "$_dbName" '
        '(${(sz / 1024).toStringAsFixed(1)} KB + Base64 overhead). '
        'Switch to IndexedDB: '
        'openDatabase("$_dbName", useIndexedDb: true)',
      );
    }
  }

  @override
  Future<void> close() async => flush();
}
