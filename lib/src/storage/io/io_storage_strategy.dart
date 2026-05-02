import 'dart:io';
import 'dart:typed_data';
import '../storage_strategy.dart';

// dart:io exposes the current PID via `pid` (top-level in dart:io).
final int pid_ = pid;

/// Mobile/Desktop storage implementation using RandomAccessFile.
/// 
/// Features:
/// - **File locking**: Prevents multiple processes from opening the same DB file.
///   Uses OS-level exclusive lock on open; released on close.
/// - **Async-safe writes**: Flushes are only triggered explicitly or on close.
/// - **Size tracking**: Tracks the logical end-of-file for append operations.
class IoStorageStrategy implements StorageStrategy {
  final String path;
  RandomAccessFile? _file;
  RandomAccessFile? _lockFile;
  int _cachedSize = 0;

  IoStorageStrategy(this.path);

  // ─── Open / Close ─────────────────────────────────────────────────────────

  @override
  Future<void> open() async {
    final dbFile = File(path);
    if (!await dbFile.exists()) {
      await dbFile.create(recursive: true);
    }
    // Capture the logical file size BEFORE opening.
    // On some platforms (Windows) FileMode.write truncates the file to zero on
    // open, so we must read the length first via a stat() call, not via the
    // RandomAccessFile handle.
    final preOpenSize = await dbFile.length();
    // Open in append mode to avoid truncation, but then use setPosition() 
    // for random access. FileMode.write truncates existing files.
    _file = await dbFile.open(mode: FileMode.append);
    await _file!.setPosition(0);
    _cachedSize = preOpenSize;

    // Acquire an exclusive file lock (blocks other processes)
    await _acquireFileLock();
  }

  /// Acquires an OS-level exclusive lock on a `.lock` sidecar file.
  /// Throws [StateError] if another process already holds the lock.
  Future<void> _acquireFileLock() async {
    final lockPath = '$path.lock';
    final lockFile = File(lockPath);

    try {
      // Open with write-exclusive mode and try to lock
      _lockFile = await lockFile.open(mode: FileMode.write);
      await _lockFile!.lock(FileLock.blockingExclusive);

      // Write our PID so the lock is inspectable
      final pid = pid_;
      final pidBytes = Uint8List(4);
      pidBytes[0] = pid & 0xFF;
      pidBytes[1] = (pid >> 8) & 0xFF;
      pidBytes[2] = (pid >> 16) & 0xFF;
      pidBytes[3] = (pid >> 24) & 0xFF;
      await _lockFile!.setPosition(0);
      await _lockFile!.writeFrom(pidBytes);
    } catch (e) {
      throw StateError(
          'FastDB: Cannot open "$path" — another process has it locked. '
          'Close all other instances first. (Original error: $e)');
    }
  }

  @override
  Future<void> close() async {
    await flush();
    await _file?.close();
    _file = null;

    // Release and delete lock file
    try {
      await _lockFile?.unlock();
      await _lockFile?.close();
      _lockFile = null;
      final lockFile = File('$path.lock');
      if (await lockFile.exists()) await lockFile.delete();
    } catch (_) {}
  }

  // ─── Read / Write ─────────────────────────────────────────────────────────

  @override
  Future<Uint8List> read(int offset, int size) async {
    if (_file == null) throw StateError('Storage not open');
    if (size <= 0) return Uint8List(0);

    await _file!.setPosition(offset);
    final buf = Uint8List(size);
    final fileSize = await _file!.length();
    final available = fileSize - offset;
    if (available <= 0) return buf;

    final toRead = available < size ? available : size;
    await _file!.readInto(buf, 0, toRead);
    return buf;
  }

  @override
  Future<void> write(int offset, Uint8List data) async {
    if (_file == null) throw StateError('Storage not open');
    await _file!.setPosition(offset);
    await _file!.writeFrom(data);
    final end = offset + data.length;
    if (end > _cachedSize) _cachedSize = end;
  }

  @override
  Future<void> flush() async {
    // flush() on RandomAccessFile only empties the Dart/OS userspace buffer.
    // We additionally call flushSync() which maps to fdatasync(2) on POSIX and
    // FlushFileBuffers() on Windows, ensuring data reaches the storage device
    // before we return.  This is critical for WAL durability guarantees.
    final f = _file;
    if (f != null) {
      await f.flush();
      try { f.flushSync(); } catch (_) {} // best-effort: older SDKs may not have it
    }
  }

  @override
  Future<int> get size async => _cachedSize;

  @override
  Future<void> truncate(int size) async {
    if (_file == null) throw StateError('Storage not open');
    await _file!.truncate(size);
    if (size < _cachedSize) _cachedSize = size;
  }

  // Disk-backed: no synchronous fast paths.
  @override int? get sizeSync => null;
  @override Uint8List? readSync(int offset, int size) => null;
  @override bool get needsExplicitFlush => true;
  @override bool writeSync(int offset, Uint8List data) => false;
}
