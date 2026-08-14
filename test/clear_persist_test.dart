import 'dart:io';
import 'package:test/test.dart';
import 'package:ffastdb/ffastdb.dart';

void main() {
  late Directory tmp;
  late String dbPath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('clear_repro_');
    dbPath = '${tmp.path}/clear_repro.fdb';
    await FfastDb.disposeInstance();
    await ffastdb.close();
  });

  tearDown(() async {
    await ffastdb.close();
    await FfastDb.disposeInstance();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('singleton: insert -> clear -> delete files -> re-init -> count', () async {
    // 1) init + insert
    await ffastdb.init('clear_repro', directory: tmp.path);
    final db = ffastdb.db;
    await db.insertAll([
      {'type': 'user', 'name': 'A'},
      {'type': 'post', 'title': 'B'},
    ]);
    expect(await db.count(), 2);
    final id1 = await db.insert({'type': 'user', 'name': 'C'});
    print('inserted id=$id1, count=${await db.count()}');

    // 2) clear via singleton
    await ffastdb.db.clear();
    final afterClear = await ffastdb.db.count();
    print('count after clear (same instance): $afterClear');
    expect(afterClear, 0);
    expect(await ffastdb.db.getAll(), isEmpty);
    expect(await ffastdb.db.findById(1), isNull);

    // 3) user's native step: delete files on disk WHILE db is still open
    final files = [
      File(dbPath),
      File('$dbPath.wal'),
      File('$dbPath.log'),
      File('$dbPath.lock'),
    ];
    for (final f in files) {
      try {
        if (await f.exists()) {
          await f.delete();
          print('deleted: ${f.path}');
        }
      } catch (e) {
        print('FAILED to delete ${f.path}: $e');
      }
    }

    // 4) user does NOT call ffastdb.close(); only resets their own wrapper state.
    //    Next code path tries to init again — but singleton already open.
    final dbAgain = await ffastdb.init('clear_repro', directory: tmp.path);
    print('re-init returned same instance? ${identical(dbAgain, db)}');
    final countReinit = await dbAgain.count();
    print('count after re-init via singleton: $countReinit');
    expect(countReinit, 0, reason: 'Re-init via singleton must not resurrect data');
    expect(await dbAgain.getAll(), isEmpty);

    final newId = await dbAgain.insert({'type': 'user', 'name': 'D'});
    print('new id after clear+re-init: $newId');
    expect(await dbAgain.count(), 1);
  });
}