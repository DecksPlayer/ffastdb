// Public barrel exports — users only need: import 'package:ffastdb/ffastdb.dart';
export 'src/fastdb.dart';
export 'src/annotations.dart';
export 'src/ffastdb_singleton.dart';
export 'src/storage/storage_strategy.dart';
export 'src/storage/memory_storage_strategy.dart';
export 'src/storage/wal_storage_strategy.dart';
export 'src/storage/buffered_storage_strategy.dart';
export 'src/storage/encrypted_storage_strategy.dart';
export 'src/storage/web/web_storage_strategy.dart';
export 'src/query/fast_query.dart';
export 'src/platform/open_database.dart';
export 'src/index/secondary_index.dart';
export 'src/index/hash_index.dart';
export 'src/index/sorted_index.dart';
export 'src/index/fts_index.dart';
export 'src/index/bitmask_index.dart';
export 'src/index/composite_index.dart';
// Platform-conditional storage strategies — available via the same import on all platforms.
export 'src/storage/io/io_storage_strategy.dart'
    if (dart.library.js_interop) 'src/storage/web/indexed_db_strategy.dart';