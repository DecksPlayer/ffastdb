import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'benchmarks/bench_result.dart';
import 'benchmarks/ffastdb_bench.dart';
import 'benchmarks/isar_bench.dart';
import 'benchmarks/sembast_bench.dart';

void main() {
  runApp(const BenchmarkApp());
}

class BenchmarkApp extends StatelessWidget {
  const BenchmarkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ffastdb vs isar_community vs sembast',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      home: const BenchmarkPage(),
    );
  }
}

class BenchmarkPage extends StatefulWidget {
  const BenchmarkPage({super.key});

  @override
  State<BenchmarkPage> createState() => _BenchmarkPageState();
}

class _BenchmarkPageState extends State<BenchmarkPage> {
  bool _running = false;
  int _n = 10000;
  final List<String> _log = [];
  final List<BenchResult> _results = [];

  void _log_(String msg) {
    setState(() => _log.insert(0, msg));
  }

  Future<Directory> _freshDir(String name) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/bench_$name');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    return dir;
  }

  Future<void> _runAll() async {
    if (_running) return;
    setState(() {
      _running = true;
      _log.clear();
      _results.clear();
    });

    try {
      _log_('🚀 Running with n=$_n...');

      _log_('📦 ffastdb...');
      final ffastdbDir = await _freshDir('ffastdb');
      final ffastdbResults = await runFfastdbBench(ffastdbDir, _n);
      setState(() => _results.addAll(ffastdbResults));
      for (final r in ffastdbResults) {
        _log_('   $r');
      }

      _log_('📦 isar_community...');
      final isarDir = await _freshDir('isar');
      final isarResults = await runIsarBench(isarDir, _n);
      setState(() => _results.addAll(isarResults));
      for (final r in isarResults) {
        _log_('   $r');
      }

      _log_('📦 sembast...');
      final sembastDir = await _freshDir('sembast');
      final sembastResults = await runSembastBench(sembastDir, _n);
      setState(() => _results.addAll(sembastResults));
      for (final r in sembastResults) {
        _log_('   $r');
      }

      _log_('✅ Done.');
    } catch (e, st) {
      _log_('❌ ERROR: $e');
      _log_('$st');
    } finally {
      setState(() => _running = false);
    }
  }

  /// Groups results by operation so each row shows all 3 engines side by side.
  Map<String, Map<String, BenchResult>> get _byOperation {
    final map = <String, Map<String, BenchResult>>{};
    for (final r in _results) {
      map.putIfAbsent(r.operation, () => {})[r.engine] = r;
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _byOperation;
    const engines = ['ffastdb', 'isar_community', 'sembast'];

    return Scaffold(
      appBar: AppBar(title: const Text('ffastdb vs isar_community vs sembast')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Text('n = '),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  value: _n,
                  items: const [1000, 10000, 100000]
                      .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
                      .toList(),
                  onChanged: _running ? null : (v) => setState(() => _n = v ?? _n),
                ),
                const SizedBox(width: 16),
                FilledButton.icon(
                  onPressed: _running ? null : _runAll,
                  icon: _running
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow),
                  label: const Text('Run All Benchmarks'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (grouped.isNotEmpty) ...[
              const Text('Results (docs/s — higher is better)',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: [
                    const DataColumn(label: Text('Operation')),
                    for (final e in engines) DataColumn(label: Text(e)),
                  ],
                  rows: [
                    for (final entry in grouped.entries)
                      DataRow(cells: [
                        DataCell(Text(entry.key)),
                        for (final e in engines)
                          DataCell(Text(entry.value[e] == null
                              ? '—'
                              : '${(entry.value[e]!.opsPerSec / 1000).toStringAsFixed(1)}k')),
                      ]),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            const Text('Log', style: TextStyle(fontWeight: FontWeight.bold)),
            Expanded(
              child: ListView.builder(
                itemCount: _log.length,
                itemBuilder: (_, i) => Text(_log[i], style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
