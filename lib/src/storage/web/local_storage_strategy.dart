// This file is only compiled on web (referenced exclusively from
// open_database_web.dart which is selected via conditional export).
import 'dart:convert';
import 'dart:js_interop';

import 'web_storage_strategy.dart';

// ── localStorage JS interop ──────────────────────────────────────────────────

extension type _LocalStorage(JSObject _) {
  external JSString? getItem(JSString key);
  external void setItem(JSString key, JSString value);
  external void removeItem(JSString key);
}

@JS('localStorage')
external _LocalStorage get _localStorage;

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

  @override
  Future<void> open() async {
    try {
      final stored = _localStorage.getItem(_lsKey.toJS)?.toDart;
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
    final sz = await size;
    if (sz == 0) {
      _localStorage.removeItem(_lsKey.toJS);
      return;
    }
    final snapshot = await read(0, sz);
    _localStorage.setItem(_lsKey.toJS, base64Encode(snapshot).toJS);
  }

  @override
  Future<void> close() async => flush();
}
