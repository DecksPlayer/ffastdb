import '../fastdb.dart';
import '../storage/storage_strategy.dart';
import '../storage/web/local_storage_strategy.dart';
import '../storage/web/indexed_db_strategy.dart';
import '../storage/encrypted_storage_strategy.dart';
import '../storage/wal_storage_strategy.dart' show Durability;
import '_singleton_open.dart';

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
  double autoCompactThreshold = 0.3,
  int version = 1,
  Map<int, dynamic Function(dynamic)>? migrations,
  List<String> indexes = const [],
  List<String> sortedIndexes = const [],
  List<String> ftsIndexes = const [],
  List<List<String>> compositeIndexes = const [],
  String? encryptionKey,
  bool useIndexedDb = true,
  void Function(double)? onProgress,
  // Accepted for API parity with native; ignored — IndexedDB commits every
  // flush in its own transaction.
  Durability durability = Durability.normal,
}) async {
  return openSingleton(name, () {
    StorageStrategy baseStorage = useIndexedDb
        ? IndexedDbStorageStrategy(name)
        : LocalStorageStrategy(name);
    if (encryptionKey != null && encryptionKey.isNotEmpty) {
      baseStorage = EncryptedStorageStrategy(baseStorage, encryptionKey);
    }
    return FfastDb.init(
      baseStorage,
      cacheCapacity: cacheCapacity,
      autoCompactThreshold: autoCompactThreshold,
      version: version,
      migrations: migrations,
      indexes: indexes,
      sortedIndexes: sortedIndexes,
      ftsIndexes: ftsIndexes,
      compositeIndexes: compositeIndexes,
      onProgress: onProgress,
      name: name,
    );
  });
}
