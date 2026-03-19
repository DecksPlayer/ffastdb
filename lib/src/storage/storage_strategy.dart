import 'dart:typed_data';

/// Base interface for storage operations on different platforms.
abstract class StorageStrategy {
  /// Opens the storage.
  Future<void> open();

  /// Reads a block of data at the given [offset] with [size].
  Future<Uint8List> read(int offset, int size);

  /// Writes a [data] block at the given [offset].
  Future<void> write(int offset, Uint8List data);

  /// Flushes any pending writes to the physical storage.
  Future<void> flush();

  /// Closes the storage.
  Future<void> close();

  /// Returns the current size of the storage in bytes.
  Future<int> get size;

  /// Truncates the storage to [size] bytes. Used by WAL checkpoint to clear the WAL file.
  Future<void> truncate(int size);

  // ── Optional synchronous fast paths ──────────────────────────────────────

  /// If non-null, the current byte length of the storage without awaiting.
  /// Implementations where writes are synchronous (e.g. [MemoryStorageStrategy])
  /// override this to avoid a microtask bounce in hot paths.
  int? get sizeSync => null;

  /// Synchronous read. Returns null if the implementation requires async I/O.
  /// Callers must fall back to [read] when this returns null.
  Uint8List? readSync(int offset, int size) => null;

  /// If false, [flush] is a no-op and all writes are immediately visible
  /// (i.e. the underlying medium is RAM). Hot paths can skip awaiting [flush]
  /// and calling [flush] on every write when this is false.
  bool get needsExplicitFlush => true;

  /// Synchronous write.  Returns true if the write was performed inline
  /// (no I/O scheduling needed), false if the caller must fall back to the
  /// async [write].  Implementations that can guarantee a synchronous,
  /// infallible write (e.g. [MemoryStorageStrategy]) override this.
  bool writeSync(int offset, Uint8List data) => false;
}
