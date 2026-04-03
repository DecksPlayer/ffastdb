/// Platform-aware database opener.
///
/// On mobile/desktop (dart:io available): wraps [IoStorageStrategy] + WAL.
/// On web (dart:html available):          wraps [WebStorageStrategy].
///
/// Import `package:ffastdb/ffastdb.dart` and call [openDatabase] directly:
///
/// ```dart
/// import 'package:ffastdb/ffastdb.dart';
/// import 'package:path_provider/path_provider.dart';
///
/// Future<FastDB> initDb() async {
///   // path_provider is only called on native — ignored on web.
///   final dir = await getApplicationDocumentsDirectory();
///   return openDatabase('myapp', directory: dir.path, version: 1);
/// }
/// ```
library;

export 'open_database_native.dart'
    if (dart.library.js_interop) 'open_database_web.dart';
