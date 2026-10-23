import '../fastdb.dart';

Future<FastDB>? _opening;
String? _openingKey;

/// Opens the database identified by [key] (its path on native, its name on
/// the web) as the global singleton, with [open].
///
/// - The live singleton is reused only when it IS that database. Before, any
///   live instance was returned, so `openDatabase('b')` with `'a'` open
///   handed out `'a'` and the caller silently wrote into the wrong database.
///   A different database replaces it (the singleton holds one at a time).
/// - Concurrent calls for the same database (e.g. a BLoC and a repository at
///   startup) share one in-flight open instead of racing for the file lock.
Future<FastDB> openSingleton(String key, Future<FastDB> Function() open) async {
  while (_opening != null && _openingKey != key) {
    try {
      await _opening;
    } catch (_) {}
  }
  final inFlight = _opening;
  if (inFlight != null) return inFlight;

  try {
    final existing = FfastDb.instance; // throws if none or closed
    if (existing.name == key) return existing;
  } on StateError {
    // No live instance.
  }

  // Registered with NO await since the checks above: a concurrent call must
  // find this open in flight (an await here let two opens race for the lock).
  final future = () async {
    await FfastDb.disposeInstance();
    return open();
  }();
  _opening = future;
  _openingKey = key;
  try {
    return await future;
  } finally {
    if (identical(_opening, future)) {
      _opening = null;
      _openingKey = null;
    }
  }
}
