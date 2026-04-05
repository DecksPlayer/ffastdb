import 'dart:typed_data';
import 'package:ffastdb/src/storage/storage_strategy.dart';

/// In-memory storage implementation for testing and Web fallback.
class MemoryStorageStrategy implements StorageStrategy {
  Uint8List _data = Uint8List(0);
  int _usedSize = 0;

  @override
  Future<void> open() async {}

  @override
  Future<Uint8List> read(int offset, int size) async {
    if (offset >= _usedSize) {
      return Uint8List(size);
    }
    final end = (offset + size > _usedSize) ? _usedSize : offset + size;
    final actualSize = end - offset;
    
    final result = Uint8List(size); // Always return requested size
    if (actualSize > 0) {
      // setRange with a source offset avoids allocating an intermediate sublist.
      result.setRange(0, actualSize, _data, offset);
    }
    return result;
  }

  /// Pre-allocated completed future — returned by [write] to avoid allocating
  /// a new Future object on every write call while keeping the async signature.
  static final Future<void> _done = Future.value();

  @override
  Future<void> write(int offset, Uint8List data) {
    _writeInternal(offset, data);
    return _done;
  }

  void _writeInternal(int offset, Uint8List data) {
    final requiredSize = offset + data.length;
    if (requiredSize > _data.length) {
      // Exponential growth: double the capacity or use the required size if larger
      int newSize = _data.isEmpty ? 1024 : _data.length;
      while (newSize < requiredSize) {
        newSize *= 2;
      }
      
      final newData = Uint8List(newSize);
      if (_data.isNotEmpty) {
        newData.setRange(0, _data.length, _data);
      }
      _data = newData;
    }
    _data.setRange(offset, offset + data.length, data);
    if (requiredSize > _usedSize) {
      _usedSize = requiredSize;
    }
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}

  @override
  Future<int> get size async => _usedSize;

  @override
  Future<void> truncate(int size) async {
    if (size < 0) size = 0;
    if (size < _usedSize) _usedSize = size;
    // BUG FIX: Reclaim backing-buffer memory on significant size reduction.
    // Without this, a database that grew to 50 MB and was then compacted to
    // 5 MB still holds a 64 MB buffer until the process exits.
    if (_data.length > size + 512 * 1024) {
      final shrunk = Uint8List(size);
      if (size > 0) shrunk.setRange(0, size, _data);
      _data = shrunk;
    }
  }

  // ── Synchronous fast paths ────────────────────────────────────────────────

  @override
  int? get sizeSync => _usedSize;

  @override
  bool get needsExplicitFlush => false;

  @override
  Uint8List? readSync(int offset, int size) {
    if (offset >= _usedSize) return Uint8List(size);
    final end = (offset + size > _usedSize) ? _usedSize : offset + size;
    final actualSize = end - offset;
    final result = Uint8List(size);
    if (actualSize > 0) result.setRange(0, actualSize, _data, offset);
    return result;
  }

  /// Synchronous write — always succeeds for in-memory storage.
  @override
  bool writeSync(int offset, Uint8List data) {
    _writeInternal(offset, data);
    return true;
  }
}
