import 'dart:io';

import 'package:ffastdb/ffastdb.dart';

/// Worker for unclean_exit_test.dart: mixes single operations with
/// transactional / batch ones, then exits WITHOUT close() — the normal way a
/// mobile app process ends.
///
/// Usage: `dart test/helpers/unclean_exit_worker.dart <dir> <name> [key]`
Future<void> main(List<String> args) async {
  final db = await openDatabase(
    args[1],
    directory: args[0],
    autoCompactThreshold: 0,
    encryptionKey: args.length > 2 ? args[2] : null,
  );
  await db.insert({'v': 1, 'secret': 'SECRET-PAYLOAD'}); // id 1
  await db.delete(await db.insert({'tmp': true})); // id 2
  await db.transaction(() async {
    await db.update(1, {'v': 2});
  });
  await db.insert({'v': 10}); // id 3
  await db.deleteWhere((q) => q.where('v').equals(2).findIds()); // removes id 1
  await db.updateWhere((q) => q.where('v').equals(10).findIds(), {'v': 11});
  for (int i = 0; i < 40; i++) {
    await db.insert({'filler': i, 'secret': 'SECRET-PAYLOAD'});
  }
  exit(0);
}
