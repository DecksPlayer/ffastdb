import 'dart:typed_data';
import '../storage_strategy.dart';

/// In-memory storage strategy for web.
///
/// Backed by a single growable [Uint8List] buffer.
/// For persistence across page reloads use [LocalStorageStrategy] (web-only)
/// which is selected automatically by [openDatabase].
class WebStorageStrategy implements StorageStrategy {
  Uint8List _data = Uint8List(0);
  int _usedSize = 0;

  @override
  Future<void> open() async {}

  @override
  Future<Uint8List> read(int offset, int size) async {
    if (offset >= _usedSize) return Uint8List(size);
    final end = (offset + size > _usedSize) ? _usedSize : offset + size;
    final result = Uint8List(size);
    result.setRange(0, end - offset, _data, offset);
    return result;
  }

  @override
  Future<void> write(int offset, Uint8List data) async {
    final required = offset + data.length;
    if (required > _data.length) {
      int newLen = _data.isEmpty ? 1024 : _data.length;
      while (newLen < required) newLen *= 2;
      final grown = Uint8List(newLen);
      if (_data.isNotEmpty) grown.setRange(0, _data.length, _data);
      _data = grown;
    }
    _data.setRange(offset, offset + data.length, data);
    if (required > _usedSize) _usedSize = required;
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}

  @override
  Future<int> get size async => _usedSize;

  @override
  Future<void> truncate(int size) async {
    if (size < _usedSize) _usedSize = size;
  }

  // ── Synchronous fast paths ────────────────────────────────────────────────

  @override
  int? get sizeSync => _usedSize;

  @override
  bool get needsExplicitFlush => false;

  /// WebStorageStrategy uses a RAM buffer — writes are always synchronous.
  @override
  bool writeSync(int offset, Uint8List data) {
    final required = offset + data.length;
    if (required > _data.length) {
      int newLen = _data.isEmpty ? 1024 : _data.length;
      while (newLen < required) newLen *= 2;
      final grown = Uint8List(newLen);
      if (_data.isNotEmpty) grown.setRange(0, _data.length, _data);
      _data = grown;
    }
    _data.setRange(offset, offset + data.length, data);
    if (required > _usedSize) _usedSize = required;
    return true;
  }

  @override
  Uint8List? readSync(int offset, int size) {
    if (offset >= _usedSize) return Uint8List(size);
    final end = (offset + size > _usedSize) ? _usedSize : offset + size;
    final result = Uint8List(size);
    result.setRange(0, end - offset, _data, offset);
    return result;
  }
}
