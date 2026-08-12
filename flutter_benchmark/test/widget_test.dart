import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_benchmark/main.dart';

void main() {
  testWidgets('BenchmarkPage renders with the Run All Benchmarks button', (tester) async {
    await tester.pumpWidget(const BenchmarkApp());
    expect(find.text('Run All Benchmarks'), findsOneWidget);
  });
}
