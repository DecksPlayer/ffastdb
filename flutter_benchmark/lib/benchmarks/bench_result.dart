/// One measured operation for one database engine.
class BenchResult {
  final String engine;
  final String operation;
  final int n;
  final int elapsedMs;

  BenchResult({
    required this.engine,
    required this.operation,
    required this.n,
    required this.elapsedMs,
  });

  double get opsPerSec => elapsedMs == 0 ? double.infinity : n / elapsedMs * 1000;

  @override
  String toString() =>
      '$engine.$operation(n=$n): ${elapsedMs}ms (${opsPerSec.toStringAsFixed(0)} ops/s)';
}
