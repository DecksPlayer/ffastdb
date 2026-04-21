import 'package:ffastdb/ffastdb.dart';

void main() async {
  final db = FastDB(MemoryStorageStrategy());
  await db.open();

  print('╔══════════════════════════════════════════════════════════════╗');
  print('║    FastDB Bloom Filter Optimization Benchmark               ║');
  print('║    Testing negative query performance                       ║');
  print('╚══════════════════════════════════════════════════════════════╝\n');

  // Seed with diverse status values
  const docCount = 10000;
  const statuses = ['active', 'inactive', 'pending', 'archived', 'deleted'];

  print('Seeding $docCount documents with status distribution...');
  for (int i = 0; i < docCount; i++) {
    final status = statuses[i % statuses.length];
    await db.insert({'id': i, 'status': status});
  }
  print('✓ Seeded\n');

  // Add a HashIndex on 'status'
  db.addIndex('status');

  // Benchmark 1: Find all "inactive" documents
  print('BENCHMARK 1: Positive query - find all "inactive"');
  print('──────────────────────────────────────────────');

  final positiveTimes = <int>[];
  for (int i = 0; i < 10; i++) {
    final sw = Stopwatch()..start();
    final results = await db.query()
      .where('status')
      .equals('inactive')
      .find();
    sw.stop();
    positiveTimes.add(sw.elapsedMicroseconds);
  }

  final positiveAvg =
      positiveTimes.reduce((a, b) => a + b) ~/ positiveTimes.length;
  print('Average: ${positiveAvg}µs');
  print('Result set size: ~${docCount ~/ statuses.length} docs\n');

  // Benchmark 2: Find all NOT "inactive" documents (uses Bloom Filter!)
  print('BENCHMARK 2: Negative query - find all NOT "inactive"');
  print('──────────────────────────────────────────────────');

  final negativeTimes = <int>[];
  for (int i = 0; i < 10; i++) {
    final sw = Stopwatch()..start();
    final results = await db.query()
      .where('status')
      .not()
      .equals('inactive')
      .find();
    sw.stop();
    negativeTimes.add(sw.elapsedMicroseconds);
  }

  final negativeAvg =
      negativeTimes.reduce((a, b) => a + b) ~/ negativeTimes.length;
  print('Average: ${negativeAvg}µs');
  print('Result set size: ~${docCount - (docCount ~/ statuses.length)} docs\n');

  // Benchmark 3: Multiple negative queries
  print('BENCHMARK 3: Multiple negative queries (NOT active AND NOT pending)');
  print('─────────────────────────────────────────────────────────────────');

  final multiNegativeTimes = <int>[];
  for (int i = 0; i < 5; i++) {
    final sw = Stopwatch()..start();
    final results = await db.query()
      .where('status')
      .not()
      .equals('active')
      .where('status')
      .not()
      .equals('pending')
      .find();
    sw.stop();
    multiNegativeTimes.add(sw.elapsedMicroseconds);
  }

  final multiNegativeAvg =
      multiNegativeTimes.reduce((a, b) => a + b) ~/ multiNegativeTimes.length;
  print('Average: ${multiNegativeAvg}µs\n');

  // Summary
  print('PERFORMANCE SUMMARY');
  print('───────────────────');
  print('Positive query (find "inactive"):     ${positiveAvg}µs');
  print('Negative query (NOT "inactive"):      ${negativeAvg}µs');
  print('Multiple negatives (NOT & NOT):       ${multiNegativeAvg}µs');
  print('');
  print('Bloom Filter enables:');
  print('  ✓ O(1) "definitely not contains" checks');
  print('  ✓ ~10 bits per unique value vs 200+ bits for HashSet');
  print('  ✓ Fast elimination of non-matching values');
  print('  ✓ ~1% false positive rate on typical datasets\n');

  await db.close();
  print('✓ Benchmark complete');
}
