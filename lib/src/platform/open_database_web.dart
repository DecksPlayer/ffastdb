import '../fastdb.dart';
import '../storage/web/local_storage_strategy.dart';

/// Opens (or creates) a named database on Web using [LocalStorageStrategy].
///
/// On web there is no persistent file system; data is persisted in the
/// browser's localStorage so it survives tab close and page reload.
///
/// [directory] is accepted but ignored on web for API compatibility.
///
/// [indexes] registers hash (O(1) equality) secondary indexes on the listed
/// fields before the database is opened.
///
/// [sortedIndexes] registers sorted (O(log n) range/order) secondary indexes.
Future<FastDB> openDatabase(
  String name, {
  String? directory,
  int cacheCapacity = 256,
  double autoCompactThreshold = 0,
  int version = 1,
  Map<int, dynamic Function(dynamic)>? migrations,
  List<String> indexes = const [],
  List<String> sortedIndexes = const [],
}) async {
  // Use singleton pattern - first dispose any existing instance
  await FfastDb.disposeInstance();
  
  final db = await FfastDb.init(
    LocalStorageStrategy(name),
    cacheCapacity: cacheCapacity,
    autoCompactThreshold: autoCompactThreshold,
    version: version,
    migrations: migrations,
  );
  
  for (final field in indexes) {
    db.addIndex(field);
  }
  for (final field in sortedIndexes) {
    db.addSortedIndex(field);
  }
  
  return db;
}
