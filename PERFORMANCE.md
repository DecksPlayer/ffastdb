# ffastdb — Performance Analysis

> Original analysis covering: `_query_operations.dart`, `fastdb.dart`, `hash_index.dart`, `btree.dart`, `page_manager.dart`, `fast_serializer.dart`
> Original version: v0.2.7+

---

## ✅ Status (v0.3.4): all 6 items below are resolved

Verified against the current code — all 6 original findings (PERF-1 through PERF-6) are
already implemented: `getAll()`/`findByIdsImpl` load in parallel with chunked `Future.wait`
(`_query_operations.dart`), `HashIndex.all()` has an invalidatable cache (`_allCache`),
`sumWhere`/`avgWhere` use `idx.valueOf(id)` when the field is indexed instead of reading the
full document, the serializer dispatches by type name before attempting the Firebase cases
(avoiding try/catch on the fast path), and `PageManager.flushDirty()` already groups
contiguous pages into a single write. They're kept below as historical reference.

**Additional performance work in v0.3.4** (see [`CHANGELOG.md`](CHANGELOG.md) for full detail):
`insertAll()` on real disk no longer does one syscall per document in `WalStorageStrategy`
(write coalescing + a rolling stream buffer for huge transactions), indexing during
`insertAll()`/`compact()` is no longer O(n²) in `SortedIndex` (now uses batched `addAll()`),
and `reindex()` no longer reads each document with its own `read()` call (now batches
contiguous reads). Current numbers measured with `dart run benchmark/disk_insert_benchmark.dart`
and `dart run benchmark/million_benchmark.dart` are in the [README](README.md#performance).

---

## PERF-1: `getAll()` loads documents sequentially (not in parallel) — ✅ Resolved

**File:** [`_query_operations.dart`](lib/src/_query_operations.dart)
**Impact:** High — 10,000 docs ≈ 1 second of latency with a cold cache

```dart
Future<List<dynamic>> getAllImpl() async {
  final ids = await _db._primaryIndex.rangeSearch(1, _db._nextId - 1);
  final results = <dynamic>[];
  for (final id in ids) {
    final doc = await _db._findById(id); // ← sequential: N awaits
    if (doc != null) results.add(doc);
  }
  return results;
}
```

On SSD storage with a cold cache, each `_findById` can take ~100µs. With 10,000 documents
that's **~1 second of serial waiting**.

**Proposed fix — parallel reads with bounded concurrency:**
```dart
Future<List<dynamic>> getAllImpl() async {
  final ids = await _db._primaryIndex.rangeSearch(1, _db._nextId - 1);
  // Process in chunks of 32 to avoid saturating the event loop
  const chunkSize = 32;
  final results = <dynamic>[];
  for (int i = 0; i < ids.length; i += chunkSize) {
    final chunk = ids.skip(i).take(chunkSize).toList();
    final docs = await Future.wait(chunk.map(_db._findById));
    results.addAll(docs.whereType<dynamic>().where((d) => d != null));
  }
  return results;
}
```

**Estimated gain:** 4-8x on large datasets with real storage.

---

## PERF-2: `sumWhere`, `avgWhere`, `minWhere`, `maxWhere` read full documents — ✅ Resolved

**File:** [`fastdb.dart` L702-L779](lib/src/fastdb.dart#L702)
**Impact:** High — N full-document reads when the value is already in the index

Each aggregation does `findIds()` + `N × findById()`. If the field is in a `SortedIndex`, the
value is already available in the tree without reading the full document.

```dart
// BEFORE — reads the whole document to extract a single field:
for (final id in ids) {
  final doc = await _findById(id); // ← full read
  if (doc is Map<String, dynamic>) {
    final v = doc[field];
    if (v is num) total += v;
  }
}
```

**Proposed fix:** expose `index.values()` on `SortedIndex` for aggregations that never touch storage:
```dart
// On SortedIndex — new method:
Iterable<MapEntry<int, dynamic>> entries(); // (docId, value), no doc reads

// In fastdb.dart:
Future<num> sumWhere(queryFn, String field) async {
  final idx = _secondaryIndexes[field];
  if (idx is SortedIndex) {
    // Fast path: O(n) over the index, no storage reads
    final ids = Set<int>.from(await queryFn(query()));
    return idx.entries()
      .where((e) => ids.contains(e.key) && e.value is num)
      .fold<num>(0, (acc, e) => acc + (e.value as num));
  }
  // Slow fallback for unindexed fields...
}
```

**Estimated gain:** 10-50x for aggregations on indexed fields.

---

## PERF-3: `HashIndex.all()` rebuilds the full list on every call — ✅ Resolved

**File:** [`hash_index.dart` L283-L291](lib/src/index/hash_index.dart)
**Impact:** Medium-High — called by sort, watchers, and negated conditions

```dart
@override
List<int> all() {
  final result = <int>[];
  for (final bucket in _buckets) {
    for (final entry in bucket) {
      result.addAll(entry.docIds); // O(total_docs) every time
    }
  }
  return result;
}
```

`all()` is called by:
- `_applySort()` — on every sort query
- `_notifyWatchersBatch()` — on every mutation
- Negated conditions (`not().equals()`) — requires the complement

With 100,000 documents, this generates ~400,000 operations per query.

**Proposed fix — invalidatable cache:**
```dart
class HashIndex {
  List<int>? _allCache; // ← new

  @override
  List<int> all() => _allCache ??= _buildAll();

  List<int> _buildAll() {
    final result = <int>[];
    for (final bucket in _buckets) {
      for (final entry in bucket) result.addAll(entry.docIds);
    }
    return result;
  }

  void add(int docId, dynamic value) {
    _allCache = null; // invalidate on mutation
    // ... existing logic ...
  }

  void remove(int docId, dynamic value) {
    _allCache = null; // invalidate on mutation
    // ... existing logic ...
  }
}
```

**Estimated gain:** 10-100x for queries with frequent sorting or negated conditions.

---

## PERF-4: `BTree.rangeSearch` keeps a `seenIds` Set for every doc

**File:** [`btree.dart` L565-L610](lib/src/index/btree.dart)
**Impact:** Low-Medium — memory and time overhead for `getAll()`

```dart
// rangeSearch keeps two Sets that grow to N elements:
final Set<int> visited = {}; // visited pages
final Set<int> seenIds = {}; // deduplicated IDs
```

For a well-formed B-Tree, `seenIds` should never have duplicates. This overhead exists only
as a corruption guard.

**Proposed fix:**
```dart
Future<List<int>> rangeSearch(int low, int high, {bool skipDedupe = false}) async {
  final Set<int>? seenIds = skipDedupe ? null : {};
  // ... only use seenIds when non-null ...
}

// In getAll() — use the no-dedupe path:
final ids = await _primaryIndex.rangeSearch(1, _nextId - 1, skipDedupe: true);
```

---

## PERF-5: `PageManager.flushDirty()` writes pages serially (one at a time) — ✅ Resolved

**File:** [`page_manager.dart` L137-L142](lib/src/storage/page_manager.dart)
**Impact:** Medium — bottleneck in `commitBatch` with many dirty pages

```dart
Future<void> flushDirty() async {
  for (final entry in _dirtyPages.entries) {
    await storage.write(entry.key * pageSize, entry.value); // serial
  }
  _dirtyPages.clear();
}
```

An `insertAll(5000)` can produce up to 1,000 dirty pages. Serial writes waste the OS's
concurrent I/O capacity.

**Proposed fix — merge contiguous pages:**
```dart
Future<void> flushDirty() async {
  if (_dirtyPages.isEmpty) return;

  // Sort pages and group contiguous ones into a single write per range
  final sorted = _dirtyPages.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));

  int rangeStart = sorted.first.key;
  final rangeData = BytesBuilder();
  rangeData.add(sorted.first.value);

  for (int i = 1; i < sorted.length; i++) {
    if (sorted[i].key == sorted[i-1].key + 1) {
      rangeData.add(sorted[i].value); // contiguous page → merge
    } else {
      await storage.write(rangeStart * pageSize, rangeData.takeBytes());
      rangeStart = sorted[i].key;
      rangeData.add(sorted[i].value);
    }
  }
  await storage.write(rangeStart * pageSize, rangeData.takeBytes());
  _dirtyPages.clear();
}
```

**Estimated gain:** 2-5x on flushes with many contiguous pages (common with sequential inserts).

---

## PERF-6: `fast_serializer.dart` used try/catch for Firebase type detection on every value — ✅ Resolved

**File:** [`fast_serializer.dart`](lib/src/serialization/fast_serializer.dart)
**Impact:** Medium — slow path for documents with large arrays

The three `try/catch` blocks in `_toEncodable` for Firebase `Timestamp`, `GeoPoint`, and
`DocumentReference` used to run for **every value** in the document, including `String`,
`int`, `bool` values that are never Firebase objects.

```dart
// BEFORE — 3 try/catch per document value:
dynamic _toEncodable(dynamic value) {
  try { return (value as Timestamp).toDate()... } catch (_) {}
  try { return (value as GeoPoint)... } catch (_) {}
  try { return (value as DocumentReference)... } catch (_) {}
  return value;
}
```

**Proposed fix — O(1) dispatch by type:**
```dart
dynamic _toEncodable(dynamic value) {
  if (value is String || value is num || value is bool || value is Null) {
    return value; // fast path — common primitive types
  }
  if (value is DateTime) return value.toIso8601String();
  // Only attempt Firebase detection for non-primitive types:
  try { return _encodeFirebaseType(value); } catch (_) {}
  return value;
}
```

**Estimated gain:** 2-10x when serializing documents with large arrays of primitives.

---

## Opportunity Summary

| # | Area | Impact | Effort | Estimated Gain | Status |
|---|------|--------|--------|-----------------|--------|
| PERF-1 | Parallel `getAll()` | 🔴 High | Low | 4-8x | ✅ Resolved |
| PERF-2 | Aggregations without full reads | 🔴 High | Medium | 10-50x | ✅ Resolved |
| PERF-3 | `HashIndex.all()` cache | 🟡 Medium | Low | 10-100x | ✅ Resolved |
| PERF-4 | `rangeSearch` without dedupe | 🟢 Low | Very low | 5-20% | Open |
| PERF-5 | `flushDirty()` page merging | 🟡 Medium | Medium | 2-5x | ✅ Resolved |
| PERF-6 | Serializer type fast path | 🟡 Medium | Low | 2-10x | ✅ Resolved |

---

## Reproducible Benchmarks

To measure the real impact of any change:

```bash
dart run benchmark/million_benchmark.dart       # in-memory, 1M docs
dart run benchmark/disk_insert_benchmark.dart   # real disk (WAL + IoStorageStrategy)
dart run benchmark/batch_write_benchmark.dart   # single insert vs. insertAll(), 5k docs
dart run benchmark/composite_index_benchmark.dart
dart run benchmark/fts_benchmark.dart
dart run benchmark/fts_advanced_benchmark.dart
```

> See the [`benchmark/`](benchmark/) directory for current implementations.
