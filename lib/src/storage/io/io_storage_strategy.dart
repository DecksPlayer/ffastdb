import 'dart:async';
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

  /// Serializes all operations on [_file].
  ///
  /// A [RandomAccessFile] handle does not allow concurrent async operations
  /// ("An async operation is currently pending"), and `setPosition` + read/
  /// write is not atomic across interleaved calls — concurrent readers would
  /// corrupt each other's offsets. Every handle operation goes through this
  /// chain so they execute one at a time, in issue order.
  Future<void> _opQueue = Future.value();

  Future<T> _locked<T>(Future<T> Function() op) {
    final prev = _opQueue;
    final completer = Completer<void>();
    _opQueue = completer.future;
    return prev.then((_) => op()).whenComplete(completer.complete);
  }

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

    // NON-blocking exclusive lock, with a short retry loop. Two requirements
    // meet here:
    //  1. A live owner must make us FAIL (never wait forever on
    //     FileLock.blockingExclusive — that froze apps on startup).
    //  2. After an owner is SIGKILLed, the OS may take a few milliseconds to
    //     release the byte-range lock (observed on Windows in the soak test:
    //     open() right after kill+exitCode intermittently hit errno 33).
    //     Retrying briefly bridges that release latency; a genuinely live
    //     owner holds the lock continuously and we still fail — just after
    //     ~2 s instead of instantly.
    const maxAttempts = 20;
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        _lockFile = await lockFile.open(mode: FileMode.write);
        await _lockFile!.lock(FileLock.exclusive);

        // Write our PID so the lock is inspectable
        final pid = pid_;
        final pidBytes = Uint8List(4);
        pidBytes[0] = pid & 0xFF;
        pidBytes[1] = (pid >> 8) & 0xFF;
        pidBytes[2] = (pid >> 16) & 0xFF;
        pidBytes[3] = (pid >> 24) & 0xFF;
        await _lockFile!.setPosition(0);
        await _lockFile!.writeFrom(pidBytes);
        return;
      } catch (e) {
        lastError = e;
        try {
          await _lockFile?.close();
        } catch (_) {}
        _lockFile = null;
        if (attempt < maxAttempts) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
    }
    throw StateError(
        'FastDB: Cannot open "$path" — another process has it locked. '
        'Close all other instances first. (Original error: $lastError)');
  }

  @override
  Future<void> close() async {
    // Flush/close errors must be reported, but the lock must ALWAYS be
    // released — otherwise a single failed flush (e.g. ENOSPC) keeps the
    // database file locked until the process exits, and even THIS process
    // cannot reopen it.
    Object? flushError;
    await _locked(() async {
      final f = _file;
      if (f != null) {
        try {
          await f.flush();
        } catch (e) {
          flushError = e;
        }
        try {
          await f.close();
        } catch (_) {}
        _file = null;
      }
    });

    // Release and delete lock file
    try {
      await _lockFile?.unlock();
      await _lockFile?.close();
      _lockFile = null;
      final lockFile = File('$path.lock');
      if (await lockFile.exists()) await lockFile.delete();
    } catch (_) {}

    final err = flushError;
    if (err != null) throw err;
  }

  // ─── Read / Write ─────────────────────────────────────────────────────────

  @override
  Future<Uint8List> read(int offset, int size) {
    if (_file == null) throw StateError('Storage not open');
    if (size <= 0) return Future.value(Uint8List(0));

    return _locked(() async {
      await _file!.setPosition(offset);
      final buf = Uint8List(size);
      // Use the tracked size — _file.length() is an fstat(2) syscall per read.
      final available = _cachedSize - offset;
      if (available <= 0) return buf;

      final toRead = available < size ? available : size;
      await _file!.readInto(buf, 0, toRead);
      return buf;
    });
  }

  @override
  Future<void> write(int offset, Uint8List data) {
    if (_file == null) throw StateError('Storage not open');
    return _locked(() async {
      await _file!.setPosition(offset);
      await _file!.writeFrom(data);
      final end = offset + data.length;
      if (end > _cachedSize) _cachedSize = end;
    });
  }

  @override
  Future<void> flush() {
    // RandomAccessFile.flush() already issues fsync(2) on POSIX and
    // FlushFileBuffers() on Windows (verified in the Dart SDK: File::Flush),
    // so data reaches the storage device. The old extra flushSync() caused a
    // SECOND fsync per call AND blocked the isolate — removed.
    return _locked(() async {
      final f = _file;
      if (f != null) {
        await f.flush();
      }
    });
  }

  @override
  Future<int> get size async => _cachedSize;

  @override
  Future<void> truncate(int size) {
    if (_file == null) throw StateError('Storage not open');
    return _locked(() async {
      await _file!.truncate(size);
      if (size < _cachedSize) _cachedSize = size;
    });
  }

  @override
  StorageStrategy? get innerStorage => null; // not a wrapper

  // Disk-backed: no synchronous fast paths.
  @override int? get sizeSync => null;
  @override Uint8List? readSync(int offset, int size) => null;
  @override bool get needsExplicitFlush => true;
  @override bool writeSync(int offset, Uint8List data) => false;
}
