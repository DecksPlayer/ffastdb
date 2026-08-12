// ignore_for_file: avoid_print

import 'dart:io';
import 'package:isar_community/isar.dart';
import 'package:flutter_benchmark/benchmarks/bench_result.dart';
import 'package:flutter_benchmark/benchmarks/ffastdb_bench.dart';
import 'package:flutter_benchmark/benchmarks/isar_bench.dart';
import 'package:flutter_benchmark/benchmarks/sembast_bench.dart';

Future<void> main(List<String> args) async {
  await Isar.initializeIsarCore(download: true);

  int n = 10000;
  if (args.isNotEmpty) {
    n = int.tryParse(args[0]) ?? 10000;
  }

  print('====================================================');
  print(' Running DB Benchmark: ffastdb vs isar_community vs sembast (n=$n)');
  print('====================================================\n');

  final tempDir = Directory.systemTemp.createTempSync('flutter_benchmark_cli');

  try {
    print('📦 Running ffastdb benchmark...');
    final ffastdbDir = Directory('${tempDir.path}/ffastdb')..createSync();
    final ffastdbResults = await runFfastdbBench(ffastdbDir, n);

    print('📦 Running isar_community benchmark...');
    final isarDir = Directory('${tempDir.path}/isar')..createSync();
    final isarResults = await runIsarBench(isarDir, n);

    print('📦 Running sembast benchmark...');
    final sembastDir = Directory('${tempDir.path}/sembast')..createSync();
    final sembastResults = await runSembastBench(sembastDir, n);

    final allResults = [...ffastdbResults, ...isarResults, ...sembastResults];

    // Group by operation
    final map = <String, Map<String, BenchResult>>{};
    for (final r in allResults) {
      map.putIfAbsent(r.operation, () => {})[r.engine] = r;
    }

    final engines = ['ffastdb', 'isar_community', 'sembast'];

    print('\n### Benchmark Results (n=$n)\n');
    print('| Operation | ffastdb | isar_community | sembast |');
    print('|---|---|---|---|');

    for (final entry in map.entries) {
      final op = entry.key;
      final row = engines.map((e) {
        final res = entry.value[e];
        if (res == null) return '—';
        final opsK = (res.opsPerSec / 1000).toStringAsFixed(1);
        return '${opsK}k ops/s (${res.elapsedMs}ms)';
      }).join(' | ');
      print('| $op | $row |');
    }
  } finally {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  }

  print('\n✅ Benchmark complete.');
}
