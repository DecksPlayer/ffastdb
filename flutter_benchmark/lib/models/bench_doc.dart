import 'package:isar_community/isar.dart';

part 'bench_doc.g.dart';

/// Shared document shape across all three benchmarks:
/// `{name: String, age: int, city: String (indexed)}`.
/// Isar needs it as a typed, code-generated collection — ffastdb and
/// Sembast use the equivalent `Map<String, dynamic>` directly.
@collection
class BenchDoc {
  Id id = Isar.autoIncrement;

  late String name;
  late int age;

  @Index()
  late String city;
}
