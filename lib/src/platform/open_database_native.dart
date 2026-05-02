import 'dart:io' show Directory;
import 'package:path/path.dart' as p;
import '../fastdb.dart';
import '../storage/storage_strategy.dart';
import '../storage/io/io_storage_strategy.dart';
import '../storage/wal_storage_strategy.dart';
import '../storage/encrypted_storage_strategy.dart';

/// Opens (or creates) a named database in [directory].
Future<FastDB> openDatabase(
  String name, {
  String directory = '',
  int cacheCapacity = 256,
  double autoCompactThreshold = double.minPositive,
  int version = 1,
  Map<int, dynamic Function(dynamic)>? migrations,
  List<String> indexes = const [],
  List<String> sortedIndexes = const [],
  List<String> ftsIndexes = const [],
  List<List<String>> compositeIndexes = const [],
  String? encryptionKey,
  void Function(double)? onProgress,
}) async {
  try {
    return FfastDb.instance;
  } on StateError {
    // No live instance in this isolate.
  }

  final dir = directory.isEmpty ? Directory.current.path : directory;
  final path = p.join(dir, '$name.fdb');


  // Normal open as the Owner isolate
  await FfastDb.disposeInstance();

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
    indexes: indexes,
    sortedIndexes: sortedIndexes,
    ftsIndexes: ftsIndexes,
    compositeIndexes: compositeIndexes,
    onProgress: onProgress,
  );

  return db;
}
