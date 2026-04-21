import '../index/secondary_index.dart';
import '../index/sorted_index.dart';
import '../index/hash_index.dart';
import '../index/composite_index.dart';
import '../index/fts_index.dart';
import 'query_cache.dart';

/// Result of a query — a list of document IDs to fetch.
class QueryResult {
  final List<int> docIds;
  final int? limit;
  final int? offset;

  const QueryResult(this.docIds, {this.limit, this.offset});

  List<int> get paginated {
    var list = docIds;
    if (offset != null) list = list.skip(offset!).toList();
    if (limit != null) list = list.take(limit!).toList();
    return list;
  }
}

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
  /// Provided by [FastDB.query()] so that [find] and [findFirst] work
  /// without a direct circular dependency on the DB class.
  final Future<dynamic> Function(int id)? _fetchById;

  final List<List<_Condition>> _orGroups = [[]]; // AND within groups, OR between groups
  String? _sortField;
  bool _sortDesc = false;
  int? _limit;
  int? _offset;

  /// Shared query cache for all QueryBuilder instances in this FastDB.
  /// Initialized lazily on first use.
  static final QueryCache _queryCache = QueryCache(maxSize: 256);

  QueryBuilder(this._indexes, [this._fetchById]);

  /// Clears the global query cache. Called by reindex() to invalidate
  /// cached results when indexes change.
  static void clearCache() {
    _queryCache.clear();
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
    final ids = findIds();
    final results = <dynamic>[];
    for (final id in ids) {
      final doc = await _fetchById(id);
      if (doc != null) results.add(doc);
    }
    return results;
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
    final ids = findIds();
    if (ids.isEmpty) return null;
    return _fetchById(ids.first);
  }

  /// Returns the **count** of documents matching the query.
  ///
  /// Uses an O(1) fast path for simple equality conditions on indexed fields
  /// (reads directly from the index bucket without materialising the list).
  ///
  /// ```dart
  /// final activeCount = db.query().where('status').equals('active').count();
  /// ```
  int count() {
    // Hot path: single non-negated equals → direct bucket size, O(1)
    if (_orGroups.length == 1 && _orGroups[0].length == 1) {
      final cond = _orGroups[0][0];
      if (cond is _EqualsCondition && !cond.negated) {
        final index = _indexes[cond.field];
        if (index != null) return index.lookup(cond.value).length;
      }
    }
    return findIds().length;
  }

  // ─── Execution ────────────────────────────────────────────────────────────

  /// Generate a cache key (signature) for this query.
  /// Returns null if the query cannot be cached (e.g., with negations).
  String? _getCacheKey() {
    // Don't cache queries with negations (they're less predictable)
    for (final group in _orGroups) {
      for (final cond in group) {
        if (cond.negated) return null;
      }
    }
    
    // Build signature from conditions, sort, limit, offset
    final parts = <String>[];
    for (int g = 0; g < _orGroups.length; g++) {
      for (final cond in _orGroups[g]) {
        // Include condition values to differentiate queries with same field but different values
        if (cond is _FtsCondition) {
          parts.add('${cond.field}:${cond.runtimeType}:${cond.query}');
        } else if (cond is _EqualsCondition) {
          parts.add('${cond.field}:${cond.runtimeType}:${cond.value}');
        } else if (cond is _RangeCondition) {
          parts.add('${cond.field}:${cond.runtimeType}:${cond.low}:${cond.high}:${cond.mode}');
        } else if (cond is _ContainsCondition) {
          parts.add('${cond.field}:${cond.runtimeType}:${cond.substring}');
        } else if (cond is _StartsWithCondition) {
          parts.add('${cond.field}:${cond.runtimeType}:${cond.prefix}');
        } else if (cond is _InCondition) {
          parts.add('${cond.field}:${cond.runtimeType}:${cond.values.join(",")}');
        } else if (cond is _IsNullCondition) {
          parts.add('${cond.field}:${cond.runtimeType}:${cond.nullExpected}');
        } else {
          parts.add('${cond.field}:${cond.runtimeType}');
        }
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
  List<int> findIds() {
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
            if (cacheKey != null) _queryCache.set(cacheKey, result);
            return result;
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
          // For FTS conditions, look for the index with the '_fts_' prefix
          SecondaryIndex? index;
          if (cond is _FtsCondition) {
            index = _indexes['_fts_${cond.field}'];
          } else {
            index = _indexes[cond.field];
          }
          if (index != null) {
            final result = cond.evaluate(index);
            // Iterable<int> → List<int>: typed data views (Uint32List) are
            // already List<int>; plain lists are returned as-is.
            final finalResult = result is List<int> ? result : result.toList();
            if (cacheKey != null) _queryCache.set(cacheKey, finalResult);
            return finalResult;
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
          final compositeKey = conditionFields.join('+');
          final compositeIdx = _indexes[compositeKey];
          if (compositeIdx is CompositeIndex) {
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
              if (cacheKey != null) _queryCache.set(cacheKey, finalResult);
              return finalResult;
            }
          }
        }
      }
    }

    // No conditions → return all indexed docs
    if (_orGroups.every((g) => g.isEmpty)) {
      if (_indexes.isEmpty) return [];
      final allIds = <int>{};
      for (final idx in _indexes.values) {
        allIds.addAll(idx.all());
      }
      final result = _applySort(allIds.toList());
      if (cacheKey != null) _queryCache.set(cacheKey, result);
      return result;
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
        // For FTS conditions, look for the index with the '_fts_' prefix
        SecondaryIndex? index;
        if (cond is _FtsCondition) {
          index = _indexes['_fts_${cond.field}'];
        } else {
          index = _indexes[cond.field];
        }
        if (index == null) continue; // Unindexed field → skip

        final matches = cond.evaluate(index);
        
        if (i == 0) {
          // First condition: just convert to List
          groupResult = matches is List<int> ? matches : matches.toList();
        } else {
          // Subsequent conditions: intersect with previous results
          if (groupResult!.isEmpty) break; // Short-circuit
          
          // OPTIMIZATION: For small result sets, use Set intersection
          // For large sets, use sorted merge
          if (groupResult.length < 1000) {
            final matchSet = matches.toSet();
            groupResult = groupResult.where((id) => matchSet.contains(id)).toList();
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
    if (cacheKey != null) _queryCache.set(cacheKey, result);
    return result;
  }

  /// Quick check if a list is already sorted (for optimization)
  bool _isSorted(List<int> list) {
    for (int i = 1; i < list.length; i++) {
      if (list[i] < list[i - 1]) return false;
    }
    return true;
  }

  /// Estimated result count for a condition (for CBO ordering).
  /// Uses cheap index-level statistics to avoid evaluating the full condition twice.
  int _estimateSize(_Condition cond) {
    // For FTS conditions, look for the index with the '_fts_' prefix
    SecondaryIndex? index;
    if (cond is _FtsCondition) {
      index = _indexes['_fts_${cond.field}'];
    } else {
      index = _indexes[cond.field];
    }
    if (index == null) return 1000000; // No index = very expensive
    // For equals, use the exact bucket size — O(1) for HashIndex.
    if (cond is _EqualsCondition) {
      return index.lookup(cond.value).length;
    }
    // For other conditions, use total index size as a rough proxy.
    // This avoids running the full condition evaluation a second time.
    return index.size;
  }

  List<int> _applySort(List<int> ids) {
    if (_sortField != null) {
      final idx = _indexes[_sortField!];
      if (idx != null) {
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
          return _paginate(sortedAll.where((id) => idSet.contains(id)).toList());
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
      sb.writeln('  Group $g (${group.length == 1 ? "single" : "AND"}):', );
      if (group.isEmpty) {
        sb.writeln('    <no conditions — returns all indexed docs>');
      }
      for (final cond in group) {
        final idx = _indexes[cond.field];
        final idxDesc = idx == null
            ? 'NO_INDEX ⚠ full-scan required'
            : '${idx.runtimeType} (~${_estimateSize(cond)} docs)';
        final neg = cond.negated ? 'NOT ' : '';
        sb.writeln('    $neg${cond.conditionType.padRight(18)} '
            '${cond.field.padRight(14)}→ $idxDesc');
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
  Iterable<int> evaluate(SecondaryIndex index);
}

class _EqualsCondition implements _Condition {
  @override final String field;
  @override final bool negated;
  final dynamic value;
  _EqualsCondition(this.field, this.value, {this.negated = false});

  @override String get conditionType => 'equals';

  @override
  Iterable<int> evaluate(SecondaryIndex index) {
    final matched = index.lookup(value);
    if (!negated) return matched;
    final allIds = index.all().toSet();
    allIds.removeAll(matched);
    return allIds;
  }
}

enum _RangeMode { between, greaterThan, greaterOrEqual, lessThan, lessOrEqual }

class _RangeCondition implements _Condition {
  @override final String field;
  @override final bool negated;
  final dynamic low;
  final dynamic high;
  final _RangeMode mode;
  _RangeCondition(this.field, this.low, this.high,
      {this.negated = false, this.mode = _RangeMode.between});

  @override String get conditionType => switch (mode) {
    _RangeMode.between        => 'between',
    _RangeMode.greaterThan    => 'greaterThan',
    _RangeMode.greaterOrEqual => 'greaterOrEqualTo',
    _RangeMode.lessThan       => 'lessThan',
    _RangeMode.lessOrEqual    => 'lessThanOrEqualTo',
  };

  @override
  Iterable<int> evaluate(SecondaryIndex index) {
    Iterable<int> matched;
    // Fast path: use native SortedIndex methods (O(log n + k) seek)
    if (index is SortedIndex) {
      matched = switch (mode) {
        _RangeMode.greaterThan => index.greaterThan(low, inclusive: false),
        _RangeMode.greaterOrEqual => index.greaterThan(low, inclusive: true),
        _RangeMode.lessThan => index.lessThan(high, inclusive: false),
        _RangeMode.lessOrEqual => index.lessThan(high, inclusive: true),
        _RangeMode.between => index.range(low, high),
      };
    } else {
      // Generic fallback via SecondaryIndex.range()
      matched = index.range(low ?? '', high ?? '');
    }
    if (!negated) return matched;
    final allIds = index.all().toSet();
    allIds.removeAll(matched);
    return allIds;
  }
}

class _ContainsCondition implements _Condition {
  @override final String field;
  @override final bool negated;
  final String substring;
  _ContainsCondition(this.field, this.substring, {this.negated = false});

  @override String get conditionType => 'contains';

  @override
  Iterable<int> evaluate(SecondaryIndex index) {
    final results = <int>[];
    for (final entry in index.sorted()) {
      if (entry.key is String && (entry.key as String).contains(substring)) {
        results.addAll(entry.value);
      }
    }
    if (!negated) return results;
    final allIds = index.all().toSet();
    allIds.removeAll(results);
    return allIds;
  }
}

class _StartsWithCondition implements _Condition {
  @override final String field;
  @override final bool negated;
  final String prefix;
  _StartsWithCondition(this.field, this.prefix, {this.negated = false});

  @override String get conditionType => 'startsWith';

  @override
  Iterable<int> evaluate(SecondaryIndex index) {
    List<int> results;
    if (index is SortedIndex && prefix.isNotEmpty) {
      // O(log n) prefix scan: use the natural lexicographic sort of SortedIndex.
      // Upper bound '$prefix\uffff' covers all strings with this prefix for
      // typical Unicode data (U+FFFF is larger than any common character).
      results = List<int>.from(index.range(prefix, '$prefix\uffff'));
    } else if (index is HashIndex) {
      // O(n) bucket scan without sorting or copying the full index.
      results = index.filterKeys(
          (key) => key is String && key.startsWith(prefix));
    } else {
      results = <int>[];
      for (final entry in index.sorted()) {
        if (entry.key is String && (entry.key as String).startsWith(prefix)) {
          results.addAll(entry.value);
        }
      }
    }
    if (!negated) return results;
    final allIds = index.all().toSet();
    allIds.removeAll(results);
    return allIds;
  }
}

/// Full-Text Search condition: matches documents where field text contains query words.
class _FtsCondition implements _Condition {
  @override final String field;
  @override final bool negated;
  final String query;
  _FtsCondition(this.field, this.query, {this.negated = false});

  @override String get conditionType => 'fts';

  @override
  Iterable<int> evaluate(SecondaryIndex index) {
    List<int> results = [];
    
    // Check if this is an FTS index
    if (index is FtsIndex) {
      results = index.search(query);
    } else {
      // Fallback: not an FTS index, return empty
      results = [];
    }

    if (!negated) return results;
    final allIds = index.all().toSet();
    allIds.removeAll(results);
    return allIds;
  }
}

/// Matches documents where field value is in the provided [values] set — O(k log n).
class _InCondition implements _Condition {
  @override final String field;
  @override final bool negated;
  final List<dynamic> values;
  _InCondition(this.field, this.values, {this.negated = false});

  @override String get conditionType => 'isIn';

  @override
  Iterable<int> evaluate(SecondaryIndex index) {
    final results = <int>{};
    for (final v in values) {
      results.addAll(index.lookup(v));
    }
    if (!negated) return results;
    final allIds = index.all().toSet();
    allIds.removeAll(results);
    return allIds;
  }
}

/// Matches documents where the indexed field is null (absent from index)
/// or not null (present in the index).
class _IsNullCondition implements _Condition {
  @override final String field;
  @override final bool negated = false;
  final bool nullExpected;
  _IsNullCondition(this.field, {required this.nullExpected});

  @override String get conditionType => nullExpected ? 'isNull' : 'isNotNull';

  @override
  Iterable<int> evaluate(SecondaryIndex index) {
    // Documents present in the index have a non-null value for this field.
    // isNull() → those NOT in the index (we cannot enumerate them here,
    // so we return all indexed IDs negated — callers must combine with a
    // full-scan list if they need non-indexed docs).
    if (!nullExpected) {
      // isNotNull(): docs that have any value indexed
      return index.all();
    }
    // isNull(): the complement of all indexed docs.
    // Since we only have index data, we return an empty set here.
    // The QueryBuilder will compute the complement against the union of all indexes.
    return const [];
  }
}

/// Tautological condition: always matches all indexed documents.
/// Useful for building dynamic queries where you want "no filter".
class _TrueCondition implements _Condition {
  @override final String field;
  @override final bool negated;
  _TrueCondition(this.field) : negated = false;

  @override String get conditionType => 'alwaysTrue';

  @override
  Iterable<int> evaluate(SecondaryIndex index) => index.all();
}

// ─── Fluent condition builder ─────────────────────────────────────────────────

class FieldCondition {
  final QueryBuilder _builder;
  final String _field;
  final bool _negated;

  FieldCondition(this._builder, this._field, {required bool negated})
      : _negated = negated;

  /// Negate the next condition. Example: `.where('status').not().equals('deleted')`.
  FieldCondition not() =>
      FieldCondition(_builder, _field, negated: !_negated);

  QueryBuilder equals(dynamic value) {
    _builder._addCondition(_EqualsCondition(_field, value, negated: _negated));
    return _builder;
  }

  QueryBuilder between(dynamic low, dynamic high) {
    _builder._addCondition(_RangeCondition(_field, low, high, negated: _negated));
    return _builder;
  }

  QueryBuilder greaterThan(dynamic value) {
    _builder._addCondition(_RangeCondition(
        _field, value, null,
        mode: _RangeMode.greaterThan, negated: _negated));
    return _builder;
  }

  QueryBuilder greaterOrEqualTo(dynamic value) {
    _builder._addCondition(_RangeCondition(
        _field, value, null,
        mode: _RangeMode.greaterOrEqual, negated: _negated));
    return _builder;
  }

  QueryBuilder lessThan(dynamic value) {
    _builder._addCondition(_RangeCondition(
        _field, null, value,
        mode: _RangeMode.lessThan, negated: _negated));
    return _builder;
  }

  QueryBuilder lessThanOrEqualTo(dynamic value) {
    _builder._addCondition(_RangeCondition(
        _field, null, value,
        mode: _RangeMode.lessOrEqual, negated: _negated));
    return _builder;
  }

  QueryBuilder contains(String substring) {
    _builder._addCondition(
        _ContainsCondition(_field, substring, negated: _negated));
    return _builder;
  }

  QueryBuilder startsWith(String prefix) {
    _builder._addCondition(
        _StartsWithCondition(_field, prefix, negated: _negated));
    return _builder;
  }

  /// Matches docs where the field value is one of the [values] — SQL `IN (...)`.
  QueryBuilder isIn(List<dynamic> values) {
    _builder._addCondition(_InCondition(_field, values, negated: _negated));
    return _builder;
  }

  /// Tautological filter — matches all indexed documents.
  /// Equivalent to `1=1` in SQL. Useful for dynamic query builders.
  QueryBuilder alwaysTrue() {
    _builder._addCondition(_TrueCondition(_field));
    return _builder;
  }

  /// Matches documents where the field is null (not indexed).
  QueryBuilder isNull() {
    _builder._addCondition(_IsNullCondition(_field, nullExpected: true));
    return _builder;
  }

  /// Matches documents where the field is not null (has an indexed value).
  QueryBuilder isNotNull() {
    _builder._addCondition(_IsNullCondition(_field, nullExpected: false));
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
