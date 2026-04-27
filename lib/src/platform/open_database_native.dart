import 'dart:io' show Directory;
import 'package:path/path.dart' as p;
import '../fastdb.dart';
import '../storage/storage_strategy.dart';
import '../storage/io/io_storage_strategy.dart';
import '../storage/wal_storage_strategy.dart';
import '../storage/encrypted_storage_strategy.dart';
import 'isolate_coordinator.dart';

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

  // Multi-Isolate Support: Check if another Isolate is already managing this DB.
  final ownerPort = await IsolateCoordinator.findOwnerPort(name, dir);
  if (ownerPort != null) {
    // Validate the socket server is actually alive before committing to proxy
    // mode.  A stale .fdb.port file left by a crashed owner isolate (or a
    // test that closed the DB without calling coordinator.stop()) would
    // otherwise cause every subsequent open to get a SocketException.
    final portAlive = await IsolateCoordinator.isPortAlive(ownerPort);
    if (portAlive) {
      // We are a Proxy isolate.
      StorageStrategy storage = WalStorageStrategy(
        main: IoStorageStrategy(path),
        wal: IoStorageStrategy('$path.wal'),
      );
      final db = FastDB(storage);
      // Injected proxy handler: forwards to the Socket server.
      db.setProxyHandler((type, params) => SocketProxy(ownerPort).call(type, params));
      await db.open(version: version);
      return db;
    } else {
      // Stale port file — delete it and fall through to normal open.
      await IsolateCoordinator.deletePortFile(name, dir);
    }
  }

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

  // Register this instance as the Owner (start socket server)
  final coordinator = IsolateCoordinator(name, dir, db);
  await coordinator.register();
  
  return db;
}
