// ignore_for_file: avoid_print

// Standalone functional smoke test for the 3 benchmark implementations,
// bypassing path_provider (which needs a running Flutter engine) so it can
// run as a plain `dart run` — much faster to iterate on than a full
// `flutter run -d windows` cycle. Uses a small n; the Flutter UI drives the
// real n=10k/100k runs.
import 'dart:io';
import 'package:isar_community/isar.dart';
import 'package:flutter_benchmark/benchmarks/ffastdb_bench.dart';
import 'package:flutter_benchmark/benchmarks/isar_bench.dart';
import 'package:flutter_benchmark/benchmarks/sembast_bench.dart';

Future<void> main() async {
  await Isar.initializeIsarCore(download: true);

  const n = 500;
  final dir = Directory.systemTemp.createTempSync('flutter_benchmark_smoke');

  print('--- ffastdb ---');
  final ffastdbDir = Directory('${dir.path}/ffastdb')..createSync();
  for (final r in await runFfastdbBench(ffastdbDir, n)) {
    print('  $r');
  }

  print('--- isar_community ---');
  final isarDir = Directory('${dir.path}/isar')..createSync();
  for (final r in await runIsarBench(isarDir, n)) {
    print('  $r');
  }

  print('--- sembast ---');
  final sembastDir = Directory('${dir.path}/sembast')..createSync();
  for (final r in await runSembastBench(sembastDir, n)) {
    print('  $r');
  }

  try {
    dir.deleteSync(recursive: true);
  } catch (_) {}
  print('--- DONE ---');
}
