import 'dart:io';

import 'package:ffastdb/ffastdb.dart';

/// Worker for unclean_exit_test.dart: opens the database, does [mode] and
/// exits WITHOUT close().
///
/// Usage: `dart test/helpers/clean_flag_worker.dart <dir> <name> <mode>`
///   read         — reads only
///   write        — inserts one document
///   write-flush  — inserts one document, then flush()
Future<void> main(List<String> args) async {
  final db = await openDatabase(args[1], directory: args[0], indexes: ['status']);
  final mode = args[2];
  await db.query().where('status').equals('a').find();
  if (mode != 'read') await db.insert({'status': 'new'});
  if (mode == 'write-flush') await db.flush();
  exit(0);
}
