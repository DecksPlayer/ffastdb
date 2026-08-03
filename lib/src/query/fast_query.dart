import 'dart:async';
import 'dart:collection';
import '../fastdb.dart';
import '../index/secondary_index.dart';
import '../index/sorted_index.dart';
import '../index/composite_index.dart';
import '../query/query_cache.dart';

/// Fluent query builder with a Cost-Based Optimizer (CBO) and query caching.
///
/// Supports:
///   - `where().equals()`, `between()`, `greaterThan()`, `lessThan()`,
///     `contains()`, `startsWith()`, `isIn()`, `isNull()`, `isNotNull()`
///   - `where().not()` for negation
///   - `.or()` for disjunctive conditions
///   - `.sortBy()`, `.limit()`, `.skip()`
///
/// The internal planner evaluates conditions by estimated cardinality
/// (most selective index first) to minimize intersection cost.
///
/// Query results are cached automatically to avoid re-executing identical queries.
class QueryBuilder {
  final Map<String, SecondaryIndex> _indexes;

  /// Optional callback to resolve a document by its internal ID.
  final Future<dynamic> Function(int id)? _fetchById;

  /// Optional callback to search the primary index (B-Tree).
  /// Used for queries with no conditions to return all documents.
  final Future<List<int>> Function(int low, int high)? _primarySearch;

  /// Optional callback to watch secondary indexes.
  final Stream<List<int>> Function(String field)? _watchStream;

  final List<List<_Condition>> _orGroups = [
    [],
  ]; // AND within groups, OR between groups
  String? _sortField;
  bool _sortDesc = false;
  int? _limit;
  int? _offset;

  /// Default cache shared only by directly-constructed builders (legacy
  /// behavior for `QueryBuilder(...)` without a database reference).
  /// FastDB instances inject their own per-instance cache so that two
  /// databases never share cached query results.
  static final QueryCache _defaultCache = QueryCache(maxSize: 256);

  /// Query cache for this builder. Injected by FastDB (one per database
  /// instance); falls back to [_defaultCache] for standalone builders.
  final QueryCache _queryCache;

  QueryBuilder(
    this._indexes, [
    this._fetchById,
    this._primarySearch,
    this._watchStream,
    QueryCache? cache,
  ]) : _queryCache = cache ?? _defaultCache;

  /// Stream that emits matching documents every time any of the queried fields change.
  Stream<List<dynamic>> watch() {
    if (_fetchById == null || _watchStream == null) {
      throw StateError(
        'QueryBuilder.watch() requires a database reference. '
        'Use db.query().where(...).watch() instead.',
      );
    }

    // Watch condition fields AND the sort field (a change there re-orders).
    final fields = _orGroups.expand((g) => g.map((c) => c.field)).toSet();
    if (_sortField != null) fields.add(_sortField!);
    if (fields.isEmpty) {
      fields.add(''); // '' = wildcard: notified on every write
    }

    final subs = <StreamSubscription>[];
    late StreamController<List<dynamic>> controller;
    bool running = false;
    bool pending = false;

    // Serialized execution: a burst of notifications never runs concurrent
    // finds (which could emit stale results AFTER newer ones).
    Future<void> runQuery() async {
      if (running) {
        pending = true;
        return;
      }
      running = true;
      try {
        do {
          pending = false;
          if (controller.isClosed) return;
          try {
            final result = await find();
            if (!controller.isClosed) controller.add(result);
          } catch (e) {
            if (!controller.isClosed) controller.addError(e);
          }
        } while (pending);
      } finally {
        running = false;
      }
    }

    controller = StreamController<List<dynamic>>.broadcast(
      // Lazy: subscriptions are created only when someone actually listens —
      // previously they were created eagerly and leaked if never listened.
      onListen: () {
        runQuery(); // single initial emission
        for (final field in fields) {
          // db.watch() emits the CURRENT state immediately on subscription;
          // skip that first event per field — our own initial runQuery()
          // already covers it (prevents N+1 duplicate initial emissions).
          var skipInitial = true;
          subs.add(
            _watchStream(field).listen((_) {
              if (skipInitial) {
                skipInitial = false;
                return;
              }
              runQuery();
            }),
          );
        }
      },
      onCancel: () async {
        for (final sub in subs) {
          await sub.cancel();
        }
        subs.clear();
        await controller.close();
      },
    );

    return controller.stream;
  }

  /// Clears the default query cache used by directly-constructed builders.
  ///
  /// NOTE: FastDB instances own a per-instance cache that is cleared
  /// automatically on every write — you do not need to call this.
  static void clearCache() {
    _defaultCache.clear();
  }

  /// Searches for IDs within a range (inclusive).
  /// This is the most efficient way to get all document IDs or a subset by primary key.
  Future<List<int>> rangeSearch(int low, int high) async {
    if (_primarySearch == null) return [];
    return await _primarySearch(low, high);
  }

  // ─── Condition Starters ───────────────────────────────────────────────────

  /// Add an AND condition on [field].
  FieldCondition where(String field) {
    return FieldCondition(this, field, negated: false);
  }

  /// Alias for fluent chaining — behaves identically to `where()`.
  FieldCondition and(String field) => where(field);

  /// Start an OR group — conditions in different OR groups are unioned.
  ///
  /// Example:
  /// ```dart
  /// db.query()
  ///   .where('city').equals('London')
  ///   .or()
  ///   .where('city').equals('Paris')
  ///   .findIds();
  /// ```
  QueryBuilder or() {
    _orGroups.add([]);
    return this;
  }

  // ─── Sorting & Pagination ─────────────────────────────────────────────────

  /// Sort results by [field], ascending by default.
  QueryBuilder sortBy(String field, {bool descending = false}) {
    _sortField = field;
    _sortDesc = descending;
    return this;
  }

  /// Maximum number of results to return.
  QueryBuilder limit(int n) {
    _limit = n;
    return this;
  }

  /// Number of results to skip (for pagination).
  QueryBuilder skip(int n) {
    _offset = n;
    return this;
  }

  void _addCondition(_Condition cond) {
    _orGroups.last.add(cond);
  }

  // ─── High-level Execution ─────────────────────────────────────────────────

  /// Executes the query and returns the matching **documents**.
  ///
  /// Equivalent to calling [findIds] and fetching each document by ID.
  /// Only available when using `db.query()` — throws [StateError] if the
  /// builder was constructed without a database reference.
  ///
  /// ```dart
  /// final docs = await db.query()
  ///   .where('status').equals('active')
  ///   .find();
  /// ```
  Future<List<dynamic>> find() async {
    if (_fetchById == null) {
      throw StateError(
        'QueryBuilder.find() requires a database reference. '
        'Use db.query().where(...).find() instead of constructing QueryBuilder directly.',
      );
    }
    final ids = await findIds();
    if (ids.isEmpty) return const [];
    // Resolve documents concurrently (same pattern as findByIdsImpl) instead
    // of one sequential await per document.
    final docs = await Future.wait(ids.map(_fetchById), eagerError: false);
    return [for (final d in docs) ?d];
  }

  /// Returns the **first** matching document, or `null` if none match.
  ///
  /// More efficient than [find] when you only need one result — stops after
  /// the first ID is resolved.
  ///
  /// ```dart
  /// final user = await db.query()
  ///   .where('email').equals('alice@example.com')
  ///   .findFirst();
  /// ```
  Future<dynamic> findFirst() async {
    if (_fetchById == null) {
      throw StateError(
        'QueryBuilder.findFirst() requires a database reference. '
        'Use db.query().where(...).findFirst() instead.',
      );
    }
    // Push limit(1) into execution so sort/pagination stop at the first hit
    // (previously the full result set was materialized and truncated).
    final savedLimit = _limit;
    _limit = 1;
    try {
      final ids = await findIds();
      if (ids.isEmpty) return null;
      return _fetchById(ids.first);
    } finally {
      _limit = savedLimit;
    }
  }

  /// Returns the **count** of documents matching the query.
  ///
  /// Uses an O(1) fast path for simple equality conditions on indexed fields
  /// (reads directly from the index bucket without materialising the list).
  ///
  /// `limit()`/`skip()` are IGNORED (SQL `COUNT` semantics): the count always
  /// covers the whole match set, on both the fast and the slow path —
  /// previously the fast path ignored pagination but the slow path applied it.
  ///
  /// ```dart
  /// final activeCount = await db.query().where('status').equals('active').count();
  /// ```
  Future<int> count() async {
    // Hot path: single non-negated equals → direct bucket size, O(1)
    if (_orGroups.length == 1 && _orGroups[0].length == 1) {
      final cond = _orGroups[0][0];
      if (cond is _EqualsCondition && !cond.negated) {
        final index = _indexes[cond.field];
        if (index != null) return index.lookupCount(cond.value);
      }
    }
    // Count the full match set regardless of limit/offset.
    final savedLimit = _limit;
    final savedOffset = _offset;
    _limit = null;
    _offset = null;
    try {
      return (await findIds()).length;
    } finally {
      _limit = savedLimit;
      _offset = savedOffset;
    }
  }

  // ─── Execution ────────────────────────────────────────────────────────────

  /// Type-tagged value encoding for cache keys: `equals(1)` and `equals('1')`
  /// MUST NOT share an entry (HashIndex distinguishes runtime types), and
  /// `isIn([1, 23])` must not collide with `isIn(['1, 23'])` (string values
  /// carry a length prefix to make separators unambiguous).
  static String _encVal(dynamic v) =>
      v is String ? 'S${v.length}:$v' : '${v.runtimeType}:$v';

  /// Generate a cache key (signature) for this query.
  /// Returns null if the query cannot be cached (e.g., with negations).
  String? _getCacheKey() {
    // Don't cache queries with negations (they're less predictable)
    for (final group in _orGroups) {
      for (final cond in group) {
        if (cond.negated) return null;
      }
    }

    // Build signature from conditions, sort, limit, offset.
    // Condition parts within each group are SORTED so that
    // `where('a').equals(1).where('b').equals(2)` and the reverse order
    // share one cache entry instead of two.
    final parts = <String>[];
    for (int g = 0; g < _orGroups.length; g++) {
      final group = _orGroups[g];
      String condPart(_Condition cond) {
        if (cond is _FtsCondition) {
          return '${cond.field}:${cond.runtimeType}:${_encVal(cond.query)}';
        } else if (cond is _EqualsCondition) {
          return '${cond.field}:${cond.runtimeType}:${_encVal(cond.value)}';
        } else if (cond is _RangeCondition) {
          return '${cond.field}:${cond.runtimeType}:${_encVal(cond.low)}:${_encVal(cond.high)}:${cond.mode}';
        } else if (cond is _ContainsCondition) {
          return '${cond.field}:${cond.runtimeType}:${_encVal(cond.substring)}';
        } else if (cond is _StartsWithCondition) {
          return '${cond.field}:${cond.runtimeType}:${_encVal(cond.prefix)}';
        } else if (cond is _InCondition) {
          final vals = cond.values.map(_encVal).toList()..sort();
          return '${cond.field}:${cond.runtimeType}:${vals.join(",")}';
        } else if (cond is _IsNullCondition) {
          return '${cond.field}:${cond.runtimeType}:${cond.nullExpected}';
        } else {
          return '${cond.field}:${cond.runtimeType}';
        }
      }

      if (group.length == 1) {
        parts.add(condPart(group.first)); // fast path: no list, no sort
      } else {
        final groupParts = [for (final cond in group) condPart(cond)]..sort();
        parts.addAll(groupParts);
      }
      if (g < _orGroups.length - 1) parts.add('OR');
    }

    if (_sortField != null) {
      parts.add('sort:$_sortField:$_sortDesc');
    }
    if (_limit != null) parts.add('limit:$_limit');
    if (_offset != null) parts.add('offset:$_offset');

    return parts.join('|');
  }

  /// Execute and return matching document IDs.
  ///
  /// Algorithm:
  ///   1. Check query cache for identical queries (common for repeated operations).
  ///   2. For each OR group, evaluate conditions in selectivity order (CBO).
  ///   3. Intersect (AND) results within an OR group.
  ///   4. Union (OR) results across groups.
  ///   5. Cache result for future identical queries.
  Future<List<int>> findIds() async {
    if (FastDB.debugQueryPlan) {
      print('[ffastdb] QueryPlan:\n${explain()}');
    }

    // ── Check cache before executing query ────────────────────────────────────
    final cacheKey = _getCacheKey();
    if (cacheKey != null) {
      final cached = _queryCache.get(cacheKey);
      if (cached != null) return cached;
    }

    // ── Hot path: sortBy-only query (no filter, just sort) ──────────────────
    // Common pattern: query().where('field').alwaysTrue().sortBy('field')
    // If sortField matches the True condition's field, return sorted IDs directly
    if (_orGroups.length == 1 && _sortField != null) {
      final group = _orGroups[0];
      if (group.length == 1) {
        final cond = group[0];
        if (cond is _TrueCondition && cond.field == _sortField) {
          final index = _indexes[_sortField!];
          if (index is SortedIndex) {
            // Return all sorted IDs directly from the SortedIndex
            final sortedAll = index.sortedIds(descending: _sortDesc);
            final result = _paginate(sortedAll);
            final frozen = UnmodifiableListView<int>(result);
            if (cacheKey != null) _queryCache.set(cacheKey, frozen);
            return frozen;
          }
        }
      }
    }

    // ── Hot path: single AND condition, no sort, no pagination ──────────────
    // Avoids Set allocation and double evaluation; covers the most common query
    // pattern by returning the index result directly (zero copies for
    // SortedIndex views and O(1) for HashIndex list references).
    if (_orGroups.length == 1) {
      final group = _orGroups[0];
      if (group.length == 1 &&
          _sortField == null &&
          _limit == null &&
          _offset == null) {
        final cond = group[0];
        if (!cond.negated) {
          final index = _getIndexForField(cond.field, cond);
          if (index != null) {
            final result = await cond.evaluate(index, this);
            // Iterable<int> → List<int>: typed data views (Uint32List) are
            // already List<int>; plain lists are returned as-is.
            final finalResult = result is List<int> ? result : result.toList();
            final frozen = UnmodifiableListView<int>(finalResult);
            if (cacheKey != null) _queryCache.set(cacheKey, frozen);
            return frozen;
          }
        }
      }
    }

    // ── Hot path: composite index for multiple AND conditions ────────────────
    // Check if there's a composite index for the conditions in this group
    if (_orGroups.length == 1 && _sortField == null) {
      final group = _orGroups[0];
      if (group.length > 1) {
        // Try to find a composite index for this set of conditions
        final conditionFields = <String>[];
        for (final cond in group) {
          if (cond is _EqualsCondition && !cond.negated) {
            conditionFields.add(cond.field);
          } else {
            // Can't use composite index if any condition is not a simple equals
            conditionFields.clear();
            break;
          }
        }

        if (conditionFields.isNotEmpty) {
          // Find a composite index covering exactly these fields — in ANY
          // order (previously `conditionFields.join('+')` required the query
          // to list fields in the same order as the index declaration,
          // silently missing the optimization otherwise).
          CompositeIndex? compositeIdx;
          for (final idx in _indexes.values) {
            if (idx is CompositeIndex &&
                idx.fieldNames.length == conditionFields.length &&
                idx.fieldNames.every(conditionFields.contains)) {
              compositeIdx = idx;
              break;
            }
          }
          if (compositeIdx != null) {
            // Found a composite index! Use it directly
            final values = <dynamic>[];
            for (final field in compositeIdx.fieldNames) {
              // Find the condition for this field
              bool found = false;
              for (final cond in group) {
                if (cond is _EqualsCondition && cond.field == field) {
                  values.add(cond.value);
                  found = true;
                  break;
                }
              }
              if (!found) {
                // Field not in conditions, can't use this composite index
                values.clear();
                break;
              }
            }

            if (values.length == compositeIdx.fieldNames.length) {
              // All fields matched, use the composite index
              final result = compositeIdx.lookup(values);
              final finalResult = _paginate(result);
              final frozen = UnmodifiableListView<int>(finalResult);
              if (cacheKey != null) _queryCache.set(cacheKey, frozen);
              return frozen;
            }
          }
        }
      }
    }

    // No conditions → return all docs from primary index
    if (_orGroups.every((g) => g.isEmpty)) {
      final allIds =
          await (_primarySearch?.call(1, 0x7FFFFFFF) ??
              Future<List<int>>.value([]));
      final result = _applySort(allIds);
      final frozen = UnmodifiableListView<int>(result);
      if (cacheKey != null) _queryCache.set(cacheKey, frozen);
      return frozen;
    }

    // Evaluate OR groups
    Set<int>? unionResult;
    for (final group in _orGroups) {
      if (group.isEmpty) continue;

      // CBO: sort conditions by estimated result size (most selective first)
      final sortedConditions = List<_Condition>.from(group);
      sortedConditions.sort((a, b) {
        final sizeA = _estimateSize(a);
        final sizeB = _estimateSize(b);
        return sizeA.compareTo(sizeB);
      });

      // AND (intersect) within group
      // OPTIMIZATION: Use sorted lists and merge instead of Set operations
      List<int>? groupResult;
      for (int i = 0; i < sortedConditions.length; i++) {
        final cond = sortedConditions[i];
        final index = _getIndexForField(cond.field, cond);

        // Unindexed field → full-scan with in-memory filtering (never
        // silently discard the condition — that returned wrong results).
        final matches = index != null
            ? await cond.evaluate(index, this)
            : await _fullScan(cond);

        if (groupResult == null) {
          // First evaluated condition: just convert to List
          groupResult = matches is List<int> ? matches : matches.toList();
        } else {
          // Subsequent conditions: intersect with previous results
          if (groupResult.isEmpty) break; // Short-circuit

          // OPTIMIZATION: For small result sets, use Set intersection —
          // built from the SMALLER side and iterating the larger one
          // (previously always built the Set from the new matches, which can
          // be millions of ids when the CBO misestimates selectivity).
          if (groupResult.length < 1000) {
            final matchList = matches is List<int> ? matches : matches.toList();
            if (matchList.length <= groupResult.length) {
              final matchSet = matchList.toSet();
              groupResult = groupResult.where(matchSet.contains).toList();
            } else {
              final resultSet = groupResult.toSet();
              groupResult = matchList.where(resultSet.contains).toList();
            }
          } else {
            // Merge algorithm: O(n + m) instead of O(n * m)
            final matchList = matches is List<int> ? matches : matches.toList();
            if (!_isSorted(matchList)) matchList.sort();
            if (!_isSorted(groupResult)) groupResult.sort();

            final result = <int>[];
            int i = 0, j = 0;
            while (i < groupResult.length && j < matchList.length) {
              if (groupResult[i] == matchList[j]) {
                result.add(groupResult[i]);
                i++;
                j++;
              } else if (groupResult[i] < matchList[j]) {
                i++;
              } else {
                j++;
              }
            }
            groupResult = result;
          }
        }
      }

      if (groupResult != null && groupResult.isNotEmpty) {
        if (unionResult == null) {
          unionResult = groupResult.toSet();
        } else {
          unionResult.addAll(groupResult);
        }
      }
    }

    final ids = (unionResult ?? {}).toList();
    final result = _applySort(ids);
    final frozen = UnmodifiableListView<int>(result);
    if (cacheKey != null) _queryCache.set(cacheKey, frozen);
    return frozen;
  }

  /// Applies [cond] in memory over the pre-fetched [docs] (aligned with
  /// [allIds]). Non-Map documents are treated as "field absent" (null).
  List<int> _fullScanSync(
    _Condition cond,
    List<int> allIds,
    List<dynamic> docs,
  ) {
    final result = <int>[];
    for (int i = 0; i < allIds.length; i++) {
      final doc = docs[i];
      if (doc == null) continue;
      final value = doc is Map ? _extractQueryField(doc, cond.field) : null;
      final m = cond.matchesValue(value);
      if (cond.negated ? !m : m) result.add(allIds[i]);
    }
    return result;
  }

  /// Full-scan fallback for conditions on fields without any usable index.
  /// Scans the primary index and filters documents in memory, so conditions
  /// on unindexed fields return correct results instead of being silently
  /// discarded. Register an index (`addIndex`/`addSortedIndex`/...) to make
  /// the query O(log n) instead of O(N).
  Future<List<int>> _fullScan(_Condition cond) async {
    if (_primarySearch == null || _fetchById == null) {
      throw StateError(
        'Cannot evaluate condition on unindexed field "${cond.field}": this '
        'QueryBuilder has no database reference for the full-scan fallback. '
        'Register an index (db.addIndex/db.addSortedIndex/...) or run the '
        'query via db.query().',
      );
    }
    final allIds = await _primarySearch(1, 0x7FFFFFFF);
    if (allIds.isEmpty) return const [];
    // Fetch in batches to bound memory and event-loop pressure.
    final docs = List<dynamic>.filled(allIds.length, null);
    const batchSize = 100;
    for (int i = 0; i < allIds.length; i += batchSize) {
      final end = (i + batchSize < allIds.length)
          ? i + batchSize
          : allIds.length;
      final batch = await Future.wait([
        for (int j = i; j < end; j++) _fetchById(allIds[j]),
      ], eagerError: false);
      for (int j = i; j < end; j++) {
        docs[j] = batch[j - i];
      }
    }
    return _fullScanSync(cond, allIds, docs);
  }

  /// Quick check if a list is already sorted (for optimization)
  bool _isSorted(List<int> list) {
    for (int i = 1; i < list.length; i++) {
      if (list[i] < list[i - 1]) return false;
    }
    return true;
  }

  int _estimateSize(_Condition cond) {
    final index = _getIndexForField(cond.field, cond);
    if (index == null) return 1000000; // No index = very expensive
    // For equals, use the exact bucket size — O(1) for HashIndex.
    if (cond is _EqualsCondition) {
      return index.lookupCount(cond.value);
    }
    // For other conditions, use total index size as a rough proxy.
    // This avoids running the full condition evaluation a second time.
    return index.size;
  }

  /// Resolves the best index for a given field and condition.
  /// Automatically falls back to FTS index for string-based queries if no
  /// primary index is available for the field.
  SecondaryIndex? _getIndexForField(String field, _Condition cond) {
    // 1. FTS operator ALWAYS uses FTS index
    if (cond is _FtsCondition) {
      return _indexes['_fts_$field'];
    }

    // 2. Contains operator prefers FTS index (much faster, multi-word support)
    if (cond is _ContainsCondition) {
      final ftsIdx = _indexes['_fts_$field'];
      if (ftsIdx != null) return ftsIdx;
    }

    // 3. Direct match (HashIndex, SortedIndex, etc.)
    // For startsWith, we prefer SortedIndex if available for literal prefix match.
    final direct = _indexes[field];
    if (direct != null) {
      // Capability check: only SortedIndex can answer range queries — a
      // HashIndex/BitmaskIndex/CompositeIndex returns [] for them, which used
      // to produce silently WRONG empty results. Fall through to full-scan.
      if (cond is _RangeCondition && direct is! SortedIndex) return null;
      return direct;
    }

    // 4. Fallback to FTS for startsWith/equals if no direct index exists
    if (cond is _StartsWithCondition || cond is _EqualsCondition) {
      return _indexes['_fts_$field'];
    }

    return null;
  }

  List<int> _applySort(List<int> ids) {
    if (_sortField != null) {
      final idx = _indexes[_sortField!];
      if (idx != null) {
        // Small result set relative to the index: sort the k ids directly by
        // their indexed value — O(k log k) instead of scanning the WHOLE
        // index O(N) to filter k results.
        if (ids.isNotEmpty &&
            idx.size > 0 &&
            ids.length < idx.size ~/ 4 &&
            idx.valueOf(ids.first) != null) {
          int cmp(int a, int b) {
            final va = idx.valueOf(a);
            final vb = idx.valueOf(b);
            if (va == null && vb == null) return 0;
            if (va == null) return 1; // docs without the field, last
            if (vb == null) return -1;
            return _compareValues(va, vb);
          }

          ids.sort(_sortDesc ? (a, b) => cmp(b, a) : cmp);
          return _paginate(ids);
        }

        // Fast path: SortedIndex has pre-sorted IDs directly from SplayTree
        if (idx is SortedIndex) {
          final sortedAll = idx.sortedIds(descending: _sortDesc);
          // Filter to only IDs in our result set
          if (ids.isEmpty) {
            // sortBy without filter — return all sorted IDs
            return _paginate(sortedAll);
          }

          // Simple and fast: use Set for O(1) lookups
          final idSet = ids.toSet();
          return _paginate(
            sortedAll.where((id) => idSet.contains(id)).toList(),
          );
        }

        // Generic path: build rank map and sort
        final sorted = idx.sorted(descending: _sortDesc);
        final order = <int, int>{};
        int rank = 0;

        for (final entry in sorted) {
          for (final id in entry.value) {
            order[id] = rank;
            rank++;
          }
        }

        ids.sort((a, b) {
          final rankA = order[a];
          final rankB = order[b];
          if (rankA == null && rankB == null) return 0;
          if (rankA == null) return 1;
          if (rankB == null) return -1;
          return rankA.compareTo(rankB);
        });
      }
    }
    return _paginate(ids);
  }

  List<int> _paginate(List<int> list) {
    var result = list;
    if (_offset != null) result = result.skip(_offset!).toList();
    if (_limit != null) result = result.take(_limit!).toList();
    return result;
  }

  /// Returns a human-readable description of the query execution plan.
  ///
  /// Shows which indexes will be used for each condition, their estimated
  /// result sizes, sort directives, and pagination. Use this to diagnose
  /// slow queries that may be missing indexes.
  ///
  /// Example:
  /// ```dart
  /// print(db.query().where('city').equals('London').where('age').between(18, 65).explain());
  /// // QueryPlan {
  /// //   Group 0 (AND):
  /// //     equals             city         → HashIndex (~3 docs)
  /// //     between            age          → SortedIndex (~12 docs)
  /// // }
  /// ```
  String explain() {
    final sb = StringBuffer();
    sb.writeln('QueryPlan {');
    for (int g = 0; g < _orGroups.length; g++) {
      if (g > 0) sb.writeln('  OR');
      final group = _orGroups[g];
      sb.writeln('  Group $g (${group.length == 1 ? "single" : "AND"}):');
      if (group.isEmpty) {
        sb.writeln('    <no conditions — returns all indexed docs>');
      }
      for (final cond in group) {
        // Use the SAME index resolution as execution so the plan shown is the
        // plan executed (previously direct `_indexes[field]` hid FTS fallbacks).
        final idx = _getIndexForField(cond.field, cond);
        final idxDesc = idx == null
            ? 'FULL_SCAN (no index — O(N) filter)'
            : '${idx.runtimeType} (~${_estimateSize(cond)} docs)';
        final neg = cond.negated ? 'NOT ' : '';
        sb.writeln(
          '    $neg${cond.conditionType.padRight(18)} '
          '${cond.field.padRight(14)}→ $idxDesc',
        );
      }
    }
    if (_sortField != null) {
      sb.writeln('  SORT BY $_sortField ${_sortDesc ? "DESC" : "ASC"}');
    }
    if (_limit != null) sb.writeln('  LIMIT $_limit');
    if (_offset != null) sb.writeln('  OFFSET $_offset');
    sb.write('}');
    return sb.toString();
  }
}

// ─── Condition types ─────────────────────────────────────────────────────────

abstract class _Condition {
  String get field;
  bool get negated;
  String get conditionType;
  FutureOr<Iterable<int>> evaluate(SecondaryIndex index, QueryBuilder builder);

  /// In-memory evaluation of a document's field [value] (null if the document
  /// lacks the field). Used by the full-scan fallback for unindexed fields.
  /// Negation is applied by the caller, NOT here.
  bool matchesValue(dynamic value);
}

/// Unified total order for in-memory comparisons (mirrors SortedIndex):
/// nums numerically, strings lexicographically, bools false < true,
/// mixed types by type rank — never throws.
int _compareValues(dynamic a, dynamic b) {
  if (a is num && b is num) return a.compareTo(b);
  if (a is String && b is String) return a.compareTo(b);
  if (a is bool && b is bool) return a == b ? 0 : (a ? 1 : -1);
  final ra = a is num
      ? 0
      : a is String
      ? 1
      : a is bool
      ? 2
      : 3;
  final rb = b is num
      ? 0
      : b is String
      ? 1
      : b is bool
      ? 2
      : 3;
  if (ra != rb) return ra.compareTo(rb);
  return a.toString().compareTo(b.toString());
}

/// Mirrors `HashIndex._equals`: unified numeric equality (1 == 1.0),
/// other types require the same runtime type.
bool _indexEquals(dynamic a, dynamic b) {
  if (a == null || b == null) return false;
  if (a is num && b is num) return a == b;
  if (a.runtimeType != b.runtimeType) return false;
  return a == b;
}

/// Extracts a (possibly nested, dot-notation) field from [doc].
dynamic _extractQueryField(Map<dynamic, dynamic> doc, String fieldPath) {
  if (!fieldPath.contains('.')) return doc[fieldPath];
  dynamic current = doc;
  for (final part in fieldPath.split('.')) {
    if (current is! Map) return null;
    current = current[part];
  }
  return current;
}

/// FTS-consistent tokenization (mirrors FtsIndex): lowercase, split on
/// non-alphanumeric, keep tokens of length >= 2.
List<String> _tokenizeForScan(String text) {
  return text
      .toLowerCase()
      .split(RegExp(r'[^\w]+'))
      .where((t) => t.isNotEmpty && t.length >= 2)
      .toList();
}

/// Numeric-safe comparison for the full-scan fallback. Returns null when the
/// values are not comparable (mixed/incompatible types).
int? _tryCompare(dynamic a, dynamic b) {
  if (a is! Comparable || b == null) return null;
  try {
    return a.compareTo(b);
  } catch (_) {
    return null;
  }
}

class _EqualsCondition implements _Condition {
  @override
  final String field;
  @override
  final bool negated;
  final dynamic value;
  _EqualsCondition(this.field, this.value, {this.negated = false});

  @override
  String get conditionType => 'equals';

  @override
  Iterable<int> evaluate(SecondaryIndex index, QueryBuilder builder) {
    final matched = index.search(negated ? 'notEquals' : 'equals', value);
    return matched;
  }

  @override
  bool matchesValue(dynamic value) => _indexEquals(value, this.value);
}

enum _RangeMode { between, greaterThan, greaterOrEqual, lessThan, lessOrEqual }

class _RangeCondition implements _Condition {
  @override
  final String field;
  @override
  final bool negated;
  final dynamic low;
  final dynamic high;
  final _RangeMode mode;
  _RangeCondition(
    this.field,
    this.low,
    this.high, {
    this.negated = false,
    this.mode = _RangeMode.between,
  });

  @override
  String get conditionType => switch (mode) {
    _RangeMode.between => 'between',
    _RangeMode.greaterThan => 'greaterThan',
    _RangeMode.greaterOrEqual => 'greaterOrEqualTo',
    _RangeMode.lessThan => 'lessThan',
    _RangeMode.lessOrEqual => 'lessThanOrEqualTo',
  };

  @override
  Iterable<int> evaluate(SecondaryIndex index, QueryBuilder builder) {
    final matched = index.search(
      conditionType,
      mode == _RangeMode.between ? [low, high] : (low ?? high),
    );
    if (!negated) return matched;
    final allIds = index.all().toSet();
    allIds.removeAll(matched);
    return allIds;
  }

  @override
  bool matchesValue(dynamic value) {
    if (value == null) return false;
    return switch (mode) {
      _RangeMode.between =>
        (_tryCompare(value, low) ?? -1) >= 0 &&
            (_tryCompare(value, high) ?? 1) <= 0,
      _RangeMode.greaterThan => (_tryCompare(value, low) ?? -1) > 0,
      _RangeMode.greaterOrEqual => (_tryCompare(value, low) ?? -1) >= 0,
      _RangeMode.lessThan => (_tryCompare(value, high) ?? 1) < 0,
      _RangeMode.lessOrEqual => (_tryCompare(value, high) ?? 1) <= 0,
    };
  }
}

class _ContainsCondition implements _Condition {
  @override
  final String field;
  @override
  final bool negated;
  final String substring;
  _ContainsCondition(this.field, this.substring, {this.negated = false});

  @override
  String get conditionType => 'contains';

  @override
  Iterable<int> evaluate(SecondaryIndex index, QueryBuilder builder) {
    final matched = index.search('contains', substring);
    if (!negated) return matched;
    final allIds = index.all().toSet();
    allIds.removeAll(matched);
    return allIds;
  }

  @override
  bool matchesValue(dynamic value) =>
      value is String && value.contains(substring);
}

class _StartsWithCondition implements _Condition {
  @override
  final String field;
  @override
  final bool negated;
  final String prefix;
  _StartsWithCondition(this.field, this.prefix, {this.negated = false});

  @override
  String get conditionType => 'startsWith';

  @override
  Iterable<int> evaluate(SecondaryIndex index, QueryBuilder builder) {
    final matched = index.search('startsWith', prefix);
    if (!negated) return matched;
    final allIds = index.all().toSet();
    allIds.removeAll(matched);
    return allIds;
  }

  @override
  bool matchesValue(dynamic value) =>
      value is String && value.startsWith(prefix);
}

/// Full-Text Search condition: matches documents where field text contains query words.
class _FtsCondition implements _Condition {
  @override
  final String field;
  @override
  final bool negated;
  final String query;
  _FtsCondition(this.field, this.query, {this.negated = false});

  @override
  String get conditionType => 'fts';

  @override
  Iterable<int> evaluate(SecondaryIndex index, QueryBuilder builder) {
    final matched = index.search('fts', query);
    if (!negated) return matched;
    final allIds = index.all().toSet();
    allIds.removeAll(matched);
    return allIds;
  }

  @override
  bool matchesValue(dynamic value) {
    if (value is! String) return false;
    final docTokens = _tokenizeForScan(value).toSet();
    return _tokenizeForScan(query).every(docTokens.contains);
  }
}

/// Matches documents where field value is in the provided [values] set — O(k log n).
class _InCondition implements _Condition {
  @override
  final String field;
  @override
  final bool negated;
  final List<dynamic> values;
  _InCondition(this.field, this.values, {this.negated = false});

  @override
  String get conditionType => 'isIn';

  @override
  Iterable<int> evaluate(SecondaryIndex index, QueryBuilder builder) {
    final results = <int>{};
    for (final v in values) {
      results.addAll(index.lookup(v));
    }
    if (!negated) return results;
    final allIds = index.all().toSet();
    allIds.removeAll(results);
    return allIds;
  }

  @override
  bool matchesValue(dynamic value) => values.any((v) => _indexEquals(v, value));
}

/// Matches documents where the indexed field is null (absent from index)
/// or not null (present in the index).
/// Negation is folded into [nullExpected] at construction
/// (`not().isNull()` ≡ `isNotNull()`), so [negated] is always false.
class _IsNullCondition implements _Condition {
  @override
  final String field;
  @override
  final bool negated = false;
  final bool nullExpected;
  _IsNullCondition(this.field, {required this.nullExpected});

  @override
  String get conditionType => nullExpected ? 'isNull' : 'isNotNull';

  @override
  FutureOr<Iterable<int>> evaluate(
    SecondaryIndex index,
    QueryBuilder builder,
  ) async {
    if (!nullExpected) {
      // isNotNull(): docs that have any value indexed
      return index.all();
    }
    // isNull(): the complement of all indexed docs.
    final allIds = await builder.rangeSearch(1, 0x7FFFFFFF);
    final indexedIds = index.all().toSet();
    return allIds.where((id) => !indexedIds.contains(id));
  }

  @override
  bool matchesValue(dynamic value) =>
      nullExpected ? value == null : value != null;
}

/// Tautological condition: always matches all indexed documents.
/// Useful for building dynamic queries where you want "no filter".
/// Negated it matches nothing.
class _TrueCondition implements _Condition {
  @override
  final String field;
  @override
  final bool negated;
  _TrueCondition(this.field, {this.negated = false});

  @override
  String get conditionType => 'alwaysTrue';

  @override
  Iterable<int> evaluate(SecondaryIndex index, QueryBuilder builder) =>
      negated ? const <int>[] : index.all();

  @override
  bool matchesValue(dynamic value) => !negated;
}

// ─── Fluent condition builder ─────────────────────────────────────────────────

class FieldCondition {
  final QueryBuilder _builder;
  final String _field;
  final bool _negated;

  FieldCondition(this._builder, this._field, {required bool negated})
    : _negated = negated;

  /// Negate the next condition. Example: `.where('status').not().equals('deleted')`.
  FieldCondition not() => FieldCondition(_builder, _field, negated: !_negated);

  QueryBuilder equals(dynamic value) {
    _builder._addCondition(_EqualsCondition(_field, value, negated: _negated));
    return _builder;
  }

  QueryBuilder between(dynamic low, dynamic high) {
    _builder._addCondition(
      _RangeCondition(_field, low, high, negated: _negated),
    );
    return _builder;
  }

  QueryBuilder greaterThan(dynamic value) {
    _builder._addCondition(
      _RangeCondition(
        _field,
        value,
        null,
        mode: _RangeMode.greaterThan,
        negated: _negated,
      ),
    );
    return _builder;
  }

  QueryBuilder greaterOrEqualTo(dynamic value) {
    _builder._addCondition(
      _RangeCondition(
        _field,
        value,
        null,
        mode: _RangeMode.greaterOrEqual,
        negated: _negated,
      ),
    );
    return _builder;
  }

  QueryBuilder lessThan(dynamic value) {
    _builder._addCondition(
      _RangeCondition(
        _field,
        null,
        value,
        mode: _RangeMode.lessThan,
        negated: _negated,
      ),
    );
    return _builder;
  }

  QueryBuilder lessThanOrEqualTo(dynamic value) {
    _builder._addCondition(
      _RangeCondition(
        _field,
        null,
        value,
        mode: _RangeMode.lessOrEqual,
        negated: _negated,
      ),
    );
    return _builder;
  }

  QueryBuilder contains(String substring) {
    _builder._addCondition(
      _ContainsCondition(_field, substring, negated: _negated),
    );
    return _builder;
  }

  QueryBuilder startsWith(String prefix) {
    _builder._addCondition(
      _StartsWithCondition(_field, prefix, negated: _negated),
    );
    return _builder;
  }

  /// Matches docs where the field value is one of the [values] — SQL `IN (...)`.
  QueryBuilder isIn(List<dynamic> values) {
    _builder._addCondition(_InCondition(_field, values, negated: _negated));
    return _builder;
  }

  /// Tautological filter — matches all indexed documents.
  /// Equivalent to `1=1` in SQL. Useful for dynamic query builders.
  /// Negated (`not().alwaysTrue()`) matches nothing.
  QueryBuilder alwaysTrue() {
    _builder._addCondition(_TrueCondition(_field, negated: _negated));
    return _builder;
  }

  /// Matches documents where the field is null (not indexed).
  /// `not().isNull()` is equivalent to [isNotNull].
  QueryBuilder isNull() {
    _builder._addCondition(
      _IsNullCondition(_field, nullExpected: _negated ? false : true),
    );
    return _builder;
  }

  /// Matches documents where the field is not null (has an indexed value).
  /// `not().isNotNull()` is equivalent to [isNull].
  QueryBuilder isNotNull() {
    _builder._addCondition(
      _IsNullCondition(_field, nullExpected: _negated ? true : false),
    );
    return _builder;
  }

  /// Full-Text Search on this field.
  /// Requires an FTS index created with `db.addFtsIndex(fieldName)`.
  ///
  /// Example:
  /// ```dart
  /// db.addFtsIndex('description');
  /// final results = await db.query()
  ///   .where('description').fts('london city')
  ///   .find();
  /// ```
  ///
  /// Performance: 100-1000x faster than `contains()` for large text fields.
  QueryBuilder fts(String query) {
    _builder._addCondition(_FtsCondition(_field, query, negated: _negated));
    return _builder;
  }
}
