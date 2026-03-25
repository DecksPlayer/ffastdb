import 'fastdb.dart';
import 'serialization/type_adapter.dart';
import 'platform/open_database_native.dart'
    if (dart.library.html) 'platform/open_database_web.dart';

/// Global FFastDB instance — the single entry-point to the database,
/// analogous to Hive's top-level `Hive` object.
///
/// **Typical usage:**
/// ```dart
/// // 1. In main(), initialise once:
/// await ffastdb.init('myapp', directory: appDir.path);
///
/// // 2. Register custom TypeAdapters (optional):
/// ffastdb.registerAdapter(PersonAdapter());
///
/// // 3. Use the database anywhere:
/// final db = ffastdb.db;
/// await db.insert({'name': 'Alice', 'age': 30});
/// final doc = await db.findById(1);
///
/// // 4. Close when the app exits:
/// await ffastdb.close();
/// ```
///
/// On **web**, [directory] is ignored — the database is stored in the
/// browser's LocalStorage / in-memory buffer automatically.
// ignore: library_private_types_in_public_api
final FFastDbSingleton ffastdb = FFastDbSingleton._();

/// The type of the global [ffastdb] singleton.
///
/// Do **not** instantiate this class directly — use the [ffastdb] top-level
/// variable instead.
class FFastDbSingleton {
  FFastDbSingleton._();

  FastDB? _db;

  /// Whether the database has been opened via [init].
  bool get isOpen => _db != null;

  /// Opens (or creates) the named database.
  ///
  /// - [name] — database file name (no extension needed).
  /// - [directory] — directory where the `.fdb` files are stored.
  ///   **Required on native platforms; ignored on web.**
  ///   Use `path_provider`'s `getApplicationDocumentsDirectory()` to obtain
  ///   a suitable path in Flutter apps.
  /// - [version] — schema version; increment to trigger [migrations].
  /// - [migrations] — `{fromVersion: migrateFn}` map applied sequentially
  ///   when upgrading from an older schema version.
  ///
  /// Calling [init] a second time while the database is already open returns
  /// the existing instance without re-opening.
  Future<FastDB> init(
    String name, {
    String directory = '',
    int version = 1,
    int cacheCapacity = 256,
    double autoCompactThreshold = 0,
    Map<int, dynamic Function(dynamic)>? migrations,
  }) async {
    if (_db != null) return _db!;
    _db = await openDatabase(
      name,
      directory: directory,
      version: version,
      cacheCapacity: cacheCapacity,
      autoCompactThreshold: autoCompactThreshold,
      migrations: migrations,
    );
    return _db!;
  }

  /// The open [FastDB] instance.
  ///
  /// Throws [StateError] if [init] has not been called yet.
  FastDB get db {
    if (_db == null) {
      throw StateError(
        'FFastDB is not initialized. '
        'Call `await ffastdb.init(name, directory: path)` before accessing ffastdb.db.',
      );
    }
    return _db!;
  }

  /// Registers a [TypeAdapter] for a custom object type.
  ///
  /// Must be called before inserting or querying objects of type [T].
  void registerAdapter<T>(TypeAdapter<T> adapter) => db.registerAdapter(adapter);

  /// Closes the database and resets the singleton so [init] can be called
  /// again (useful in tests or when switching databases).
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
