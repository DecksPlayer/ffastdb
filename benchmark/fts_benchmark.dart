import 'package:ffastdb/ffastdb.dart';

void main() async {
  final db = FastDB(MemoryStorageStrategy());
  await db.open();

  print('╔════════════════════════════════════════════════════════════╗');
  print('║    FastDB Full-Text Search (FTS) Benchmark                ║');
  print('╚════════════════════════════════════════════════════════════╝\n');

  // Seed database with documents containing various descriptions
  final documents = List.generate(5000, (i) => {
    'id': i,
    'title': 'Document $i',
    'description':
        'This is a detailed description about London and Paris. '
        'It contains information about cities, travel, and tourism. '
        'London is the capital of England. Paris is the capital of France. '
        'Both cities are famous for their culture and history. '
        'Travel to London in summer and enjoy the British Museum. '
        'Paris offers the Eiffel Tower and romantic atmosphere. '
        'The description might also mention other cities like Berlin, Barcelona, Tokyo. '
        'Category: ${['travel', 'culture', 'history'][i % 3]}',
    'content':
        'Lorem ipsum dolor sit amet. ${List.generate((i % 10) + 1, (j) => 'London Paris travel tourism culture').join(' ')}',
  });

  print('Seeding ${documents.length} documents...');
  for (final doc in documents) {
    await db.insert(doc);
  }
  print('✓ Database seeded\n');

  // Benchmark 1: contains() - Linear scan
  print('BENCHMARK 1: String.contains() - Linear Search');
  print('─────────────────────────────────────────────');
  
  final containsQuery = () => db.query()
    .where('description')
    .contains('London')
    .find();

  final containsTimes = <int>[];
  for (int i = 0; i < 20; i++) {
    final sw = Stopwatch()..start();
    await containsQuery();
    sw.stop();
    containsTimes.add(sw.elapsedMicroseconds);
  }

  final containsAvg = containsTimes.reduce((a, b) => a + b) ~/ containsTimes.length;
  final containsMin = containsTimes.reduce((a, b) => a < b ? a : b);
  final containsMax = containsTimes.reduce((a, b) => a > b ? a : b);

  print('String.contains() search (20 runs):');
  print('  Min:  ${containsMin}µs');
  print('  Avg:  ${containsAvg}µs');
  print('  Max:  ${containsMax}µs\n');

  // Benchmark 2: FTS Index
  print('BENCHMARK 2: FTS Index - Inverted Index Search');
  print('──────────────────────────────────────────────');
  
  // Create FTS index
  db.addFtsIndex('description');

  final ftsTimes = <int>[];
  for (int i = 0; i < 20; i++) {
    final sw = Stopwatch()..start();
    await db.query()
      .where('description')
      .fts('London')
      .find();
    sw.stop();
    ftsTimes.add(sw.elapsedMicroseconds);
  }

  final ftsAvg = ftsTimes.reduce((a, b) => a + b) ~/ ftsTimes.length;
  final ftsMin = ftsTimes.reduce((a, b) => a < b ? a : b);
  final ftsMax = ftsTimes.reduce((a, b) => a > b ? a : b);

  print('FTS index search (20 runs):');
  print('  Min:  ${ftsMin}µs');
  print('  Avg:  ${ftsAvg}µs');
  print('  Max:  ${ftsMax}µs\n');

  // Summary
  print('PERFORMANCE IMPROVEMENT');
  print('───────────────────────');
  final improvement = containsAvg / ftsAvg;
  print('Average speedup: ${improvement.toStringAsFixed(1)}x');
  print('Min speedup:     ${(containsMin / ftsMin).toStringAsFixed(1)}x');
  print('Max speedup:     ${(containsMax / ftsMax).toStringAsFixed(1)}x\n');

  // Benchmark 3: Multi-word FTS
  print('BENCHMARK 3: Multi-word FTS (AND semantics)');
  print('────────────────────────────────────────────');
  
  final multiWordTimes = <int>[];
  for (int i = 0; i < 15; i++) {
    final sw = Stopwatch()..start();
    await db.query()
      .where('description')
      .fts('London travel culture')
      .find();
    sw.stop();
    multiWordTimes.add(sw.elapsedMicroseconds);
  }

  final multiAvg = multiWordTimes.reduce((a, b) => a + b) ~/ multiWordTimes.length;
  print('Multi-word FTS query average: ${multiAvg}µs');
  print('vs single-word: ${(ftsAvg / multiAvg).toStringAsFixed(1)}x\n');

  // Benchmark 4: FTS vs Contains on larger text
  print('BENCHMARK 4: Large Text Field (5000+ chars)');
  print('───────────────────────────────────────────');
  
  db.addFtsIndex('content');

  final largeContains = <int>[];
  for (int i = 0; i < 10; i++) {
    final sw = Stopwatch()..start();
    await db.query()
      .where('content')
      .contains('London')
      .find();
    sw.stop();
    largeContains.add(sw.elapsedMicroseconds);
  }

  final largeFts = <int>[];
  for (int i = 0; i < 10; i++) {
    final sw = Stopwatch()..start();
    await db.query()
      .where('content')
      .fts('London')
      .find();
    sw.stop();
    largeFts.add(sw.elapsedMicroseconds);
  }

  final largeContainsAvg = largeContains.reduce((a, b) => a + b) ~/ largeContains.length;
  final largeFtsAvg = largeFts.reduce((a, b) => a + b) ~/ largeFts.length;
  final largeImprovement = largeContainsAvg / largeFtsAvg;

  print('Large text - String.contains(): ${largeContainsAvg}µs');
  print('Large text - FTS:               ${largeFtsAvg}µs');
  print('Speedup:                        ${largeImprovement.toStringAsFixed(1)}x\n');

  await db.close();
  print('✓ Benchmark complete');
}
