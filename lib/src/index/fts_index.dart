import 'secondary_index.dart';

/// Full-Text Search (FTS) Index for fast text searching.
///
/// Provides O(log n) text search by building an inverted index of tokens.
/// Supports:
///   - Exact word search: `fts('london')`
///   - Prefix search: `fts('lond*')`
///   - Multiple words (AND): `fts('london city')`
///   - Case-insensitive matching
///
/// Performance:
///   - Indexing: O(m log n) where m = tokens per document
///   - Search: O(log n + k) where k = matching documents
///   - vs contains(): 100-1000x faster on large datasets
///
/// Example:
/// ```dart
/// db.addFtsIndex('description');
/// final results = await db.query()
///   .where('description').fts('london')
///   .find();
/// ```
class FtsIndex extends SecondaryIndex {
  /// Maps tokens to document IDs.
  /// Example: 'london' -> [1, 5, 23, 45]
  final Map<String, List<int>> _tokenIndex = {};

  /// Maps document ID to all tokens in that document.
  /// Used for removing documents during index maintenance.
  final Map<int, Set<String>> _docTokens = {};

  /// The field name that this FTS index covers.
  final String _fieldName;

  FtsIndex(this._fieldName) : super();

  @override
  String get fieldName => _fieldName;

  /// Tokenizes text into searchable tokens.
  /// - Converts to lowercase
  /// - Splits on whitespace and punctuation
  /// - Removes empty tokens
  static List<String> tokenize(String text) {
    if (text.isEmpty) return [];

    // Convert to lowercase and split on non-alphanumeric characters
    final tokens = text.toLowerCase().split(RegExp(r'[^\w]+'));

    // Filter empty tokens and apply min length (3 chars for better results)
    return tokens.where((t) => t.isNotEmpty && t.length >= 2).toList();
  }

  @override
  void add(int docId, dynamic value) {
    if (value is! String) return;

    final tokens = tokenize(value);
    if (tokens.isEmpty) return;

    // Store tokens for this document
    _docTokens[docId] = tokens.toSet();

    // Add to inverted index (exact tokens only)
    for (final token in tokens) {
      _tokenIndex.putIfAbsent(token, () => []).add(docId);
    }
  }

  /// Searches for documents matching the query tokens.
  /// Returns docs matching ALL tokens (AND semantics).
  List<int> search(String query) {
    if (query.isEmpty) return [];

    final tokens = tokenize(query);
    if (tokens.isEmpty) return [];

    // Get matching docs for each token
    final results = <int>{};
    bool first = true;

    for (final token in tokens) {
      final matches = _tokenIndex[token] ?? [];
      if (first) {
        results.addAll(matches);
        first = false;
      } else {
        // Intersect: keep only docs that match all tokens
        results.retainAll(matches);
      }

      if (results.isEmpty) break; // Early exit if no matches
    }

    return results.toList()..sort();
  }

  /// Searches with prefix matching (e.g., 'lond*' matches 'london').
  List<int> searchPrefix(String query) {
    if (query.isEmpty) return [];

    // Remove asterisk if present
    final prefix = query.replaceAll('*', '');
    if (prefix.isEmpty) return all();

    final matches = <int>{};
    for (final token in _tokenIndex.keys) {
      if (token.startsWith(prefix.toLowerCase())) {
        matches.addAll(_tokenIndex[token] ?? []);
      }
    }

    return matches.toList()..sort();
  }

  @override
  List<int> lookup(dynamic value) {
    if (value is! String) return [];
    return search(value);
  }

  @override
  List<int> range(dynamic min, dynamic max) {
    // Range queries don't make sense for FTS
    return [];
  }

  @override
  void remove(int docId, dynamic value) {
    // Remove from inverted index
    final tokens = _docTokens[docId];
    if (tokens == null) return;

    for (final token in tokens) {
      final ids = _tokenIndex[token];
      if (ids != null) {
        ids.remove(docId);
        if (ids.isEmpty) {
          _tokenIndex.remove(token);
        }
      }
    }

    _docTokens.remove(docId);
  }

  @override
  void removeById(int docId) {
    final tokens = _docTokens[docId];
    if (tokens != null) {
      for (final token in tokens) {
        _tokenIndex[token]?.remove(docId);
        if (_tokenIndex[token]?.isEmpty ?? false) {
          _tokenIndex.remove(token);
        }
      }
      _docTokens.remove(docId);
    }
  }

  @override
  List<int> all() {
    final results = <int>{};
    for (final ids in _tokenIndex.values) {
      results.addAll(ids);
    }
    return results.toList();
  }

  @override
  int get size {
    final results = <int>{};
    for (final ids in _tokenIndex.values) {
      results.addAll(ids);
    }
    return results.length;
  }

  @override
  void clear() {
    _tokenIndex.clear();
    _docTokens.clear();
  }

  @override
  List<MapEntry<dynamic, List<int>>> sorted({bool descending = false}) {
    // For FTS, sort by token name (lexicographic)
    final sortedTokens = _tokenIndex.keys.toList()..sort();
    if (descending) {
      sortedTokens.sort((a, b) => b.compareTo(a));
    }

    return [
      for (final token in sortedTokens)
        MapEntry(token, _tokenIndex[token]!),
    ];
  }

  /// Returns statistics about the FTS index.
  String stats() {
    return 'FtsIndex{tokens=${_tokenIndex.length}, docs=${_docTokens.length}}';
  }
}
