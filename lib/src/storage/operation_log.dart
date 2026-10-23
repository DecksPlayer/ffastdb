import 'dart:io';

/// Deletes the sequential operation log (`<db>.fdb.log`) written by
/// ffastdb <= 0.3.5.
///
/// That log was removed: the WAL already makes every committed write durable,
/// and replaying the log at open() re-applied STALE operations on top of the
/// newer WAL-recovered state (transactions and batch writes were never
/// logged, so e.g. a document removed by `deleteWhere` came back with its old
/// value after an unclean shutdown). It also stored documents in plaintext
/// next to encrypted databases. Every entry it holds is already committed in
/// the WAL/main file, so deleting it is safe.
Future<void> deleteLegacyOperationLog(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) await file.delete();
  } catch (_) {
    // Best effort — a leftover file is never read again.
  }
}
