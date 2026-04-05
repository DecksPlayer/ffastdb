import '../fastdb.dart';
import '../storage/storage_strategy.dart';
import '../storage/web/local_storage_strategy.dart';
import '../storage/web/indexed_db_strategy.dart';
import '../storage/encrypted_storage_strategy.dart';

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
  int cacheCapacity = 64,
  double autoCompactThreshold = 0,
  int version = 1,
  Map<int, dynamic Function(dynamic)>? migrations,
  List<String> indexes = const [],
  List<String> sortedIndexes = const [],
  String? encryptionKey,
  bool useIndexedDb = true,
}) async {
  // Guard: if a live instance already exists, reuse it.
  // Calling disposeInstance() unconditionally was the root cause of
  // "Bad state: Cannot perform operations on a closed database" errors
  // when openDatabase / ffastdb.init was called from multiple code paths
  // during app startup (e.g., from BLoC + repository simultaneously).
  try {
    return FfastDb.instance; // throws StateError if null or closed
  } on StateError {
    // No live instance — fall through to create one.
  }

  // Clean up any stale closed instance before opening a new one.
  await FfastDb.disposeInstance();

  StorageStrategy baseStorage = useIndexedDb
      ? IndexedDbStorageStrategy(name)
      : LocalStorageStrategy(name);

  if (encryptionKey != null && encryptionKey.isNotEmpty) {
    baseStorage = EncryptedStorageStrategy(baseStorage, encryptionKey);
  }

  final db = await FfastDb.init(
    baseStorage,
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
