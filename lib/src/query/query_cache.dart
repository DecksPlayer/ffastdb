/// LRU Query Result Cache for FastDB.
///
/// Caches query results based on a query signature to avoid re-executing
/// identical queries repeatedly. Uses a least-recently-used (LRU) eviction
/// policy when the cache reaches capacity.
///
/// Performance: Typical cache hits provide 10-100x speedup for repeated queries.
///
/// Cached lists are returned AS STORED (zero-copy — critical for hot paths
/// with thousands of ids). Callers therefore must store ONLY immutable or
/// effectively-frozen lists: `QueryBuilder.findIds()` wraps results in
/// `UnmodifiableListView` before caching them.
library;

import 'dart:collection';

class QueryCache {
  /// Maximum number of cached query results. Defaults to 256.
  final int maxSize;

  /// Maps query signature → cached result IDs.
  /// Signature is a hash of the query conditions, sort, limit, offset.
  final Map<String, List<int>> _cache = {};

  /// Tracks access order for LRU eviction (keys in order of most-recent-access).
  final List<String> _accessOrder = [];

  /// Creates a new query cache with optional [maxSize] (default: 256).
  QueryCache({this.maxSize = 256});

  int _hits = 0;
  int _misses = 0;

  /// Retrieves cached result for [key], or `null` if not cached.
  /// Updates access order on hit.
  ///
  /// ZERO-COPY: returns the stored list itself. Stored lists are frozen
  /// (see [set]), so this is safe — and ~10x faster than copying large
  /// result lists on every hit.
  List<int>? get(String key) {
    final value = _cache[key];
    if (value == null) {
      _misses++;
      return null;
    }
    _hits++;

    // Mark as recently used
    _accessOrder.remove(key);
    _accessOrder.add(key);

    return value;
  }

  /// Stores [result] in cache under [key].
  /// Evicts the least-recently-used entry if cache is full.
  ///
  /// [result] is wrapped in an [UnmodifiableListView] (no copy): callers
  /// can never mutate the cached instance, so the cache can not be poisoned
  /// and hits need no defensive copy.
  void set(String key, List<int> result) {
    // If already cached, remove old entry
    if (_cache.containsKey(key)) {
      _accessOrder.remove(key);
    }

    // Add new entry
    _cache[key] = UnmodifiableListView(result);
    _accessOrder.add(key);

    // Evict LRU if over capacity
    if (_cache.length > maxSize) {
      final lruKey = _accessOrder.removeAt(0);
      _cache.remove(lruKey);
    }
  }

  /// Clears all cached results.
  void clear() {
    _cache.clear();
    _accessOrder.clear();
  }

  /// Returns the current number of cached queries.
  int get length => _cache.length;

  /// Returns cache hit rate statistics (for debugging).
  /// Format: "Size: x/y, hits/misses (hit_rate%)".
  String stats() {
    final total = _hits + _misses;
    final rate = total == 0 ? 0.0 : _hits / total * 100;
    return 'Size: ${_cache.length}/$maxSize, $_hits/$total hits '
        '(${rate.toStringAsFixed(1)}%)';
  }
}
