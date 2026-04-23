import 'package:ffastdb/src/index/fts_index.dart';

void main() {
  print('=== Direct FtsIndex add() Test ===\n');

  final index = FtsIndex('text');

  print('Adding documents directly to FtsIndex...');
  index.add(1, 'Hello world from London');
  print('  Added doc 1');

  index.add(2, 'Paris is beautiful');
  print('  Added doc 2');

  index.add(3, 'London has big ben');
  print('  Added doc 3');

  print('');
  print('Searching directly in FtsIndex:');
  
  var results = index.search('fts', 'hello');
  print('  search("hello"): $results (expect [1])');

  results = index.search('fts', 'paris');
  print('  search("paris"): $results (expect [2])');

  results = index.search('fts', 'london');
  print('  search("london"): $results (expect [1, 3])');

  results = index.search('fts', 'big');
  print('  search("big"): $results (expect [3])');

  print('');
  print('All tests should be correct ✓');
}
