import 'dart:io' show Directory;
import 'package:path/path.dart' as p;
import '../fastdb.dart';
import '../storage/storage_strategy.dart';
import '../storage/io/io_storage_strategy.dart';
import '../storage/wal_storage_strategy.dart';
import '../storage/encrypted_storage_strategy.dart';

/// Opens (or creates) a named database in [directory].
///
/// Uses [IoStorageStrategy] + [WalStorageStrategy] for full durability and
/// crash recovery. A `.fdb`, `.fdb.wal`, and `.fdb.lock` sidecar are created
/// inside [directory].
///
/// [directory] is optional. When omitted (or empty), defaults to the current
/// working directory. On web/WASM this parameter is ignored automatically
/// (see `open_database_web.dart`).
///
/// [indexes] registers hash (O(1) equality) secondary indexes on the listed
/// fields before the database file is opened, so they are populated during
/// startup from persisted or rebuilt state.
///
/// [sortedIndexes] registers sorted (O(log n) range/order) secondary indexes.
Future<FastDB> openDatabase(
  String name, {
  String directory = '',
  int cacheCapacity = 256,
  double autoCompactThreshold = 0,
  int version = 1,
  Map<int, dynamic Function(dynamic)>? migrations,
  List<String> indexes = const [],
  List<String> sortedIndexes = const [],
  String? encryptionKey,
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

  final dir = directory.isEmpty ? Directory.current.path : directory;
  final path = p.join(dir, '$name.fdb');
  StorageStrategy storage = WalStorageStrategy(
    main: IoStorageStrategy(path),
    wal: IoStorageStrategy('$path.wal'),
  );

  if (encryptionKey != null && encryptionKey.isNotEmpty) {
    storage = EncryptedStorageStrategy(storage, encryptionKey);
  }

  final db = await FfastDb.init(
    storage,
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
