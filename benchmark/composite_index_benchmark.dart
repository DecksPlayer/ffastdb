import 'package:ffastdb/ffastdb.dart';

void main() async {
  final db = FastDB(MemoryStorageStrategy());
  await db.open();

  print('╔════════════════════════════════════════════════════════════╗');
  print('║        FastDB Composite Index Benchmark                  ║');
  print('╚════════════════════════════════════════════════════════════╝\n');

  // Seed database with 10k users
  final users = List.generate(10000, (i) => {
    'id': i,
    'name': 'User $i',
    'age': 20 + (i % 50),
    'city': ['London', 'Paris', 'Tokyo', 'Berlin', 'Barcelona'][i % 5],
    'status': ['active', 'inactive'][i % 2],
    'score': (i * 7) % 100,
  });

  print('Seeding ${users.length} documents...');
  for (final user in users) {
    await db.insert(user);
  }
  print('✓ Database seeded\n');

  // Benchmark 1: WITHOUT Composite Index
  print('BENCHMARK 1: Multi-field AND Query WITHOUT Composite Index');
  print('────────────────────────────────────────────────────────────');
  
  // Create single-field indexes
  db.addIndex('city');
  db.addIndex('status');

  final noCompositeTimes = <int>[];
  for (int i = 0; i < 50; i++) {
    final sw = Stopwatch()..start();
    await db.query()
      .where('city').equals('London')
      .where('status').equals('active')
      .findIds();
    sw.stop();
    noCompositeTimes.add(sw.elapsedMicroseconds);
  }

  final noCompositeAvg = noCompositeTimes.reduce((a, b) => a + b) ~/ noCompositeTimes.length;
  final noCompositeMin = noCompositeTimes.reduce((a, b) => a < b ? a : b);
  final noCompositeMax = noCompositeTimes.reduce((a, b) => a > b ? a : b);

  print('Without composite index (50 runs):');
  print('  Min:  ${noCompositeMin}µs');
  print('  Avg:  ${noCompositeAvg}µs');
  print('  Max:  ${noCompositeMax}µs\n');

  // Benchmark 2: WITH Composite Index
  print('BENCHMARK 2: Multi-field AND Query WITH Composite Index');
  print('──────────────────────────────────────────────────────────');
  
  // Create composite index
  db.addCompositeIndex(['city', 'status']);

  final compositeTimes = <int>[];
  for (int i = 0; i < 50; i++) {
    final sw = Stopwatch()..start();
    await db.query()
      .where('city').equals('London')
      .where('status').equals('active')
      .findIds();
    sw.stop();
    compositeTimes.add(sw.elapsedMicroseconds);
  }

  final compositeAvg = compositeTimes.reduce((a, b) => a + b) ~/ compositeTimes.length;
  final compositeMin = compositeTimes.reduce((a, b) => a < b ? a : b);
  final compositeMax = compositeTimes.reduce((a, b) => a > b ? a : b);

  print('With composite index (50 runs):');
  print('  Min:  ${compositeMin}µs');
  print('  Avg:  ${compositeAvg}µs');
  print('  Max:  ${compositeMax}µs\n');

  // Summary
  print('PERFORMANCE IMPROVEMENT');
  print('───────────────────────');
  final improvement = noCompositeAvg / compositeAvg;
  print('Average speedup: ${improvement.toStringAsFixed(1)}x');
  print('Min speedup:     ${(noCompositeMin / compositeMin).toStringAsFixed(1)}x');
  print('Max speedup:     ${(noCompositeMax / compositeMax).toStringAsFixed(1)}x\n');

  // Benchmark 3: 3-field Composite Index
  print('BENCHMARK 3: 3-field Composite Index (city + status + age_range)');
  print('──────────────────────────────────────────────────────────────────');
  
  // Simulate age range bucketing
  db.addCompositeIndex(['city', 'status', 'age']);

  final time3field = <int>[];
  for (int i = 0; i < 30; i++) {
    final sw = Stopwatch()..start();
    await db.query()
      .where('city').equals('London')
      .where('status').equals('active')
      .where('age').equals(25 + (i % 20))
      .findIds();
    sw.stop();
    time3field.add(sw.elapsedMicroseconds);
  }

  final avg3field = time3field.reduce((a, b) => a + b) ~/ time3field.length;
  print('3-field composite index average: ${avg3field}µs');
  print('Speedup vs 2-field: ${(compositeAvg / avg3field).toStringAsFixed(1)}x\n');

  await db.close();
  print('✓ Benchmark complete');
}
