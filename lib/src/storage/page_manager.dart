import 'dart:typed_data';
import 'storage_strategy.dart';
import 'lru_cache.dart';

/// Manages data in fixed-size blocks (Pages) with an LRU cache.
/// 
/// The cache keeps the most recently used pages in RAM, drastically reducing
/// disk reads when traversing B-Tree nodes or fetching hot documents.
/// 
/// With 128 pages × 4KB = 512KB RAM → supports thousands of B-Tree nodes
/// without touching disk on cache hits.
class PageManager {
  static const int pageSize = 4096; // 4KB pages

  final StorageStrategy storage;

  /// LRU cache — default 128 pages = 512KB RAM.
  /// Set higher for better performance on large datasets.
  final LruCache _cache;

  // Dirty pages are written to disk only on explicit flush() or eviction.
  final Map<int, Uint8List> _dirtyPages = {};

  /// If true, page writes are buffered until an explicit [flushDirty()] call.
  bool writeBehind;

  PageManager(this.storage, {int cacheCapacity = 128, this.writeBehind = false})
      : _cache = LruCache(capacity: cacheCapacity);

  // ─── Read ─────────────────────────────────────────────────────────────────

  /// Reads a page. Returns from cache if possible, otherwise reads from disk.
  Future<Uint8List> readPage(int pageIndex) async {
    final cached = _cache.get(pageIndex);
    if (cached != null) return cached;

    // If the page is dirty (write-behind mode), return it from the dirty buffer
    // even if it was evicted from the LRU cache — avoids reading the zeroed
    // placeholder written by allocatePage() instead of the real node data.
    final dirty = _dirtyPages[pageIndex];
    if (dirty != null) {
      _cache.put(pageIndex, dirty); // re-warm cache
      return dirty;
    }

    // Direct offset mapping: Page 0 is offset 0 (Header), Page 1 is offset 4096 (B-Tree).
    final offset = pageIndex * pageSize;
    final data = await storage.read(offset, pageSize);

    final page = data.length == pageSize ? data : _padToPage(data);
    _cache.put(pageIndex, page);
    return page;
  }

  // ─── Write ────────────────────────────────────────────────────────────────

  /// Writes a page.
  ///
  /// In **write-through** mode (default): updates cache and writes to disk immediately.
  /// In **write-behind** mode: updates cache and marks dirty; disk write deferred to [flushDirty()].
  ///
  /// Not declared `async` so that the write-behind fast path can return a
  /// pre-allocated completed [Future] without allocating a state-machine object
  /// on every call.
  Future<void> writePage(int pageIndex, Uint8List data) {
    if (data.length != pageSize) {
      throw ArgumentError('Page data must be exactly $pageSize bytes, got ${data.length}');
    }

    // data comes from BTreeNode.serialize() which allocates a fresh Uint8List(4096).
    // We take ownership directly — no extra copy needed.
    _cache.put(pageIndex, data);

    if (writeBehind) {
      _dirtyPages[pageIndex] = data;
      // Return a pre-allocated completed future — no state-machine allocation,
      // no extra microtask bounce compared to an async function body.
      return _doneFuture;
    } else {
      final offset = pageIndex * pageSize;
      return storage.write(offset, data);
    }
    // In write-behind mode: disk write is deferred until flushDirty()
  }

  /// Pre-allocated completed Future used by write-behind [writePage].
  static final Future<void> _doneFuture = Future.value();

  // ─── Allocate ─────────────────────────────────────────────────────────────

  Future<int> allocatePage() async {
    // Use sync size when available (e.g. MemoryStorageStrategy) to avoid a
    // microtask bounce.  Fall back to async for disk-backed strategies.
    final currentSize = storage.sizeSync ?? await storage.size;
    // Next available page index. Round up to the next full page boundary.
    int pageIndex = (currentSize + pageSize - 1) ~/ pageSize;
    // We reserve page 0 for the header, so start at 1.
    if (pageIndex == 0) pageIndex = 1;

    final emptyPage = Uint8List(pageSize);

    _cache.put(pageIndex, emptyPage);
    if (writeBehind) {
      // In write-behind mode, mark dirty — flushDirty() will write it.
      // Still write to storage ONLY to reserve the space (bump file size).
      _dirtyPages[pageIndex] = emptyPage;
    }
    // Write to storage to reserve the space and increment the tracked file size.
    // In write-behind mode flushDirty() will overwrite this with the real data.
    // Use synchronous write when available (e.g. MemoryStorageStrategy) to
    // eliminate one microtask bounce per page allocation.
    if (!storage.writeSync(pageIndex * pageSize, emptyPage)) {
      await storage.write(pageIndex * pageSize, emptyPage);
    }

    return pageIndex;
  }

  // ─── Cache Management ─────────────────────────────────────────────────────

  /// Flushes all dirty pages to disk and clears the dirty set.
  Future<void> flushDirty() async {
    for (final entry in _dirtyPages.entries) {
      await storage.write(entry.key * pageSize, entry.value);
    }
    _dirtyPages.clear();
  }

  /// Returns cache statistics for debugging / monitoring.
  String get cacheStats => _cache.toString();

  /// Returns the configured cache capacity (number of pages).
  int get cacheCapacity => _cache.capacity;

  /// Synchronous cache-only read. Returns the cached page bytes without any
  /// async I/O, or null if the page is not currently in memory.
  /// Use this before the async [readPage] to skip microtask bounces on hits.
  Uint8List? readPageSync(int pageIndex) {
    return _cache.get(pageIndex) ?? _dirtyPages[pageIndex];
  }

  /// Dynamically toggles write-behind mode on or off.
  void setWriteBehind(bool value) { writeBehind = value; }

  /// Clears the entire page cache (e.g., after a compact() operation).
  void clearCache() {
    _cache.clear();
    _dirtyPages.clear();
  }

  /// Clears only the LRU read cache, leaving write-behind dirty pages intact.
  /// Used after a transaction rollback: the WAL-backed writes (in _txEntries)
  /// were already discarded by wal.rollback(), so only the LRU-cached post-tx
  /// pages need invalidation. Dirty pages reflect pre-tx write-behind state
  /// (e.g. from a preceding insertAll) and must be preserved.
  void clearLruCache() {
    _cache.clear();
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────

  Uint8List _padToPage(Uint8List data) {
    final page = Uint8List(pageSize);
    final len = data.length < pageSize ? data.length : pageSize;
    page.setRange(0, len, data);
    return page;
  }
}
