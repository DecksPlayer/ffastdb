import 'dart:convert';
import 'dart:typed_data';
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

    // Deduplicate tokens for the inverted index - we only need to know
    // IF a document contains a token, not how many times.
    final uniqueTokens = tokens.toSet();

    // Store tokens for this document
    _docTokens[docId] = uniqueTokens;

    // Add to inverted index (exact tokens only)
    for (final token in uniqueTokens) {
      final ids = _tokenIndex.putIfAbsent(token, () => []);
      if (!ids.contains(docId)) ids.add(docId);
    }
  }

  /// Searches for documents matching the query tokens.
  /// Returns docs matching ALL tokens (AND semantics).
  @override
  Iterable<int> search(String operator, dynamic value) {
    if (value is! String) return [];
    
    switch (operator) {
      case 'fts':
        return _runSearch(value);
      case 'equals':
        // For FTS, equals is treated as "contains all words"
        return _runSearch(value);
      case 'startsWith':
        final tokens = tokenize(value);
        if (tokens.isEmpty) return [];
        
        Set<int>? resultSet;
        for (final t in tokens) {
          final matches = searchPrefix(t);
          if (resultSet == null) {
            resultSet = matches.toSet();
          } else {
            resultSet = resultSet.intersection(matches.toSet());
          }
          if (resultSet.isEmpty) break;
        }
        return resultSet?.toList() ?? [];

      case 'contains':
        final tokens = tokenize(value);
        if (tokens.isEmpty) return [];

        Set<int>? resultSet;
        for (final t in tokens) {
          // Find all documents containing this specific search-token as a substring
          final tokenMatches = <int>{};
          for (final indexedToken in _tokenIndex.keys) {
            if (indexedToken.contains(t)) {
              tokenMatches.addAll(_tokenIndex[indexedToken]!);
            }
          }
          
          if (resultSet == null) {
            resultSet = tokenMatches;
          } else {
            resultSet = resultSet.intersection(tokenMatches);
          }
          if (resultSet.isEmpty) break;
        }
        return (resultSet?.toList() ?? [])..sort();
      default:
        return [];
    }
  }

  List<int> _runSearch(String query) {
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

    // .toList() already creates a new list, so we are safe here
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
    return _runSearch(value);
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
  List<int> all() => _docTokens.keys.toList();

  @override
  int get size => _docTokens.length;

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

  // ─── Persistence ──────────────────────────────────────────────────────────

  Uint8List serialize() {
    final buf = BytesBuilder();
    final nameBytes = Uint8List.fromList(utf8.encode(fieldName));
    _writeInt32(buf, nameBytes.length);
    buf.add(nameBytes);
    
    _writeInt32(buf, _docTokens.length);
    for (final entry in _docTokens.entries) {
      _writeInt32(buf, entry.key); // docId
      final tokens = entry.value.toList();
      _writeInt32(buf, tokens.length);
      for (final t in tokens) {
        final tBytes = Uint8List.fromList(utf8.encode(t));
        _writeInt32(buf, tBytes.length);
        buf.add(tBytes);
      }
    }
    return buf.toBytes();
  }

  static FtsIndex deserialize(Uint8List bytes) {
    int off = 0;
    int readInt32() {
      final v = (bytes[off] & 0xFF) | ((bytes[off + 1] & 0xFF) << 8) |
          ((bytes[off + 2] & 0xFF) << 16) | ((bytes[off + 3] & 0xFF) << 24);
      off += 4;
      return v;
    }

    final nameLen = readInt32();
    final fieldName = utf8.decode(bytes.sublist(off, off + nameLen));
    off += nameLen;
    
    final index = FtsIndex(fieldName);
    final docCount = readInt32();
    for (int i = 0; i < docCount; i++) {
      final docId = readInt32();
      final tokenCount = readInt32();
      final tokens = <String>{};
      for (int j = 0; j < tokenCount; j++) {
        final tLen = readInt32();
        final t = utf8.decode(bytes.sublist(off, off + tLen));
        off += tLen;
        tokens.add(t);
        
        // Rebuild inverted index on the fly
        index._tokenIndex.putIfAbsent(t, () => []).add(docId);
      }
      index._docTokens[docId] = tokens;
    }
    return index;
  }

  void _writeInt32(BytesBuilder buf, int v) {
    buf.addByte(v & 0xFF);
    buf.addByte((v >> 8) & 0xFF);
    buf.addByte((v >> 16) & 0xFF);
    buf.addByte((v >> 24) & 0xFF);
  }

  /// Returns statistics about the FTS index.
  String stats() {
    return 'FtsIndex{tokens=${_tokenIndex.length}, docs=${_docTokens.length}}';
  }
}
