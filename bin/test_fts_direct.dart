import 'package:ffastdb/src/index/fts_index.dart';

void main() {
  print('=== Direct FtsIndex Test ===\n');

  final index = FtsIndex('text');

  // Add documents
  index.add(1, 'Hello world from London');
  index.add(2, 'Paris is beautiful');
  index.add(3, 'London has big ben');

  print('Document 1: "Hello world from London"');
  print('Document 2: "Paris is beautiful"');
  print('Document 3: "London has big ben"');
  print('');

  // Test single-word searches
  print('Single-word searches:');
  var results = index.search('london');
  print('Search "london": $results (expect [1, 3])');

  results = index.search('big');
  print('Search "big": $results (expect [3])');

  results = index.search('world');
  print('Search "world": $results (expect [1])');

  // Test multi-word searches
  print('\nMulti-word searches:');
  results = index.search('london big');
  print('Search "london big": $results (expect [3])');

  results = index.search('london world');
  print('Search "london world": $results (expect [1])');

  results = index.search('london nonexistent');
  print('Search "london nonexistent": $results (expect [])');

  // Debug tokenization
  print('\nTokenization test:');
  var tokens = FtsIndex.tokenize('Hello world from London');
  print('Tokens of "Hello world from London": $tokens');

  tokens = FtsIndex.tokenize('London has big ben');
  print('Tokens of "London has big ben": $tokens');
}
