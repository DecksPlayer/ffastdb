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
  
  /// Maximum number of dirty pages before forcing a flush in write-behind mode.
  /// Prevents unbounded memory growth when write-behind is enabled.
  /// Default: 1000 pages = 4MB of dirty data.
  static const int maxDirtyPages = 1000;

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
  /// BUG FIX: Automatically flushes when dirty pages exceed [maxDirtyPages] to prevent
  /// unbounded memory growth in long-running write-behind operations.
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
      
      // BUG FIX: Flush automatically when dirty pages exceed threshold
      // to prevent unbounded memory growth.
      if (_dirtyPages.length >= maxDirtyPages) {
        return flushDirty();
      }
      
      // Return a pre-allocated completed future — no state-machine allocation,
      // no extra microtask bounce compared to an async function body.
      return _doneFuture;
    } else {
      final offset = pageIndex * pageSize;
      // Discard any stale dirty copy of this page: without this, a page marked
      // dirty in write-behind mode and later written through would be flushed
      // AGAIN by the next flushDirty(), overwriting the newer data on disk.
      _dirtyPages.remove(pageIndex);
      return storage.write(offset, data);
    }
    // In write-behind mode: disk write is deferred until flushDirty()
  }

  /// Pre-allocated completed Future used by write-behind [writePage].
  static final Future<void> _doneFuture = Future.value();

  // ─── Free page list ───────────────────────────────────────────────────────

  /// Pages freed by B-Tree merges/collapses/rebuilds. [allocatePage] reuses
  /// them before growing the file — without this, the file grew monotonically
  /// until the next compact().
  ///
  /// Persisted in the header page (bytes 25+) on clean shutdowns. After a
  /// crash the persisted list is IGNORED (the dirty-flag guards it): a stale
  /// list could hand out pages that are live again — leaking pages is safe,
  /// reusing live pages is not.
  final List<int> _freePages = [];
  bool _freeListDirty = false;

  /// Maximum free-page indexes that fit in the header page at offset 25.
  static const int maxPersistedFreePages = (pageSize - 25 - 4) ~/ 4; // 1017

  /// Number of pages currently in the free list.
  int get freePageCount => _freePages.length;

  /// Returns [pageIndex] to the free list for reuse by [allocatePage].
  void freePage(int pageIndex) {
    if (pageIndex <= 0) return; // never free the header page
    _cache.invalidate(pageIndex);
    _dirtyPages.remove(pageIndex);
    _freePages.add(pageIndex);
    _freeListDirty = true;
  }

  /// Clears the free list (used by compact(), which rebuilds the file).
  void clearFreeList() {
    if (_freePages.isEmpty) return;
    _freePages.clear();
    _freeListDirty = true;
  }

  /// Persists the free-page list into the header page at byte offset 25
  /// (byte 24 is the clean-shutdown flag). No-op unless the list changed.
  Future<void> persistFreeList() async {
    if (!_freeListDirty) return;
    final count = _freePages.length > maxPersistedFreePages
        ? maxPersistedFreePages
        : _freePages.length;
    final bytes = Uint8List(4 + count * 4);
    final bd = ByteData.view(bytes.buffer);
    bd.setUint32(0, count, Endian.little);
    for (int i = 0; i < count; i++) {
      bd.setUint32(4 + i * 4, _freePages[i], Endian.little);
    }
    await storage.write(25, bytes);
    _freeListDirty = false;
  }

  /// Loads the persisted free-page list. Must be called ONLY when the file
  /// was closed cleanly (clean flag set) — see the note on [_freePages].
  Future<void> loadFreeList() async {
    _freePages.clear();
    final head = await storage.read(25, 4);
    if (head.length < 4) return;
    final count = ByteData.view(head.buffer).getUint32(0, Endian.little);
    if (count == 0 || count > maxPersistedFreePages) return;
    final bytes = await storage.read(29, count * 4);
    if (bytes.length < count * 4) return;
    final bd = ByteData.view(bytes.buffer);
    for (int i = 0; i < count; i++) {
      _freePages.add(bd.getUint32(i * 4, Endian.little));
    }
    _freeListDirty = false;
  }

  // ─── Allocate ─────────────────────────────────────────────────────────────

  Future<int> allocatePage() async {
    // Reuse a freed page before growing the file.
    if (_freePages.isNotEmpty) {
      final pageIndex = _freePages.removeLast();
      _freeListDirty = true;
      final emptyPage = Uint8List(pageSize);
      _cache.put(pageIndex, emptyPage);
      // NOT marked dirty: the subsequent node write marks it. One write less
      // per page (the zero-fill below only reserves the file space).
      if (!storage.writeSync(pageIndex * pageSize, emptyPage)) {
        await storage.write(pageIndex * pageSize, emptyPage);
      }
      return pageIndex;
    }

    // Use sync size when available (e.g. MemoryStorageStrategy) to avoid a
    // microtask bounce.  Fall back to async for disk-backed strategies.
    final currentSize = storage.sizeSync ?? await storage.size;
    // Next available page index. Round up to the next full page boundary.
    int pageIndex = (currentSize + pageSize - 1) ~/ pageSize;
    // We reserve page 0 for the header, so start at 1.
    if (pageIndex == 0) pageIndex = 1;

    final emptyPage = Uint8List(pageSize);

    _cache.put(pageIndex, emptyPage);
    // Write to storage to reserve the space and increment the tracked file size.
    // NOT marked dirty in write-behind mode: the subsequent B-Tree node write
    // marks the page dirty anyway — the old code also flushed these zeros,
    // i.e. TWO writes (and two WAL entries) per new page.
    // Use synchronous write when available (e.g. MemoryStorageStrategy) to
    // eliminate one microtask bounce per page allocation.
    if (!storage.writeSync(pageIndex * pageSize, emptyPage)) {
      await storage.write(pageIndex * pageSize, emptyPage);
    }

    return pageIndex;
  }

  // ─── Cache Management ─────────────────────────────────────────────────────

  /// Flushes all dirty pages to disk and clears the dirty set.
  /// Groups contiguous pages to perform larger, fewer write operations.
  Future<void> flushDirty() async {
    if (_dirtyPages.isEmpty) return;
    
    // Sort pages and group contiguous for a single write per range
    final sorted = _dirtyPages.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    
    int rangeStart = sorted.first.key;
    final rangeData = BytesBuilder();
    rangeData.add(sorted.first.value);
    
    for (int i = 1; i < sorted.length; i++) {
      if (sorted[i].key == sorted[i - 1].key + 1) {
        rangeData.add(sorted[i].value); // page is contiguous → merge
      } else {
        await storage.write(rangeStart * pageSize, rangeData.takeBytes());
        rangeStart = sorted[i].key;
        rangeData.add(sorted[i].value);
      }
    }
    await storage.write(rangeStart * pageSize, rangeData.takeBytes());
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

  /// Clears all dirty pages without flushing (used during rollback).
  void clearDirtyPages() {
    _dirtyPages.clear();
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────

  Uint8List _padToPage(Uint8List data) {
    final page = Uint8List(pageSize);
    final len = data.length < pageSize ? data.length : pageSize;
    page.setRange(0, len, data);
    return page;
  }
}
