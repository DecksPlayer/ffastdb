@TestOn('vm')
library;

import 'dart:io';

import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

void main() {
  late Directory dirA, dirB;

  setUp(() {
    dirA = Directory.systemTemp.createTempSync('ffastdb_open_a_');
    dirB = Directory.systemTemp.createTempSync('ffastdb_open_b_');
  });

  tearDown(() async {
    await FfastDb.disposeInstance();
    for (final d in [dirA, dirB]) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  test('opening a different database never hands out the open one', () async {
    final a = await openDatabase('a', directory: dirA.path);
    await a.insert({'who': 'a'});

    final b = await openDatabase('b', directory: dirB.path);
    expect(identical(a, b), isFalse);
    await b.insert({'who': 'b'});
    expect(await b.count(), 1);
    expect(File('${dirB.path}/b.fdb').existsSync(), isTrue);
    // The replaced database fails loudly instead of being written to.
    expect(() => a.insert({'who': 'late'}), throwsStateError);

    await b.close();
    final reopened = await openDatabase('a', directory: dirA.path);
    expect(await reopened.count(), 1);
  });

  test('the same database is reused, also by concurrent opens', () async {
    final results = await Future.wait([
      openDatabase('a', directory: dirA.path),
      openDatabase('a', directory: dirA.path),
    ]);
    expect(identical(results[0], results[1]), isTrue);
    expect(identical(await openDatabase('a', directory: dirA.path), results[0]),
        isTrue);
  });

  test('ffastdb.init switches databases', () async {
    final a = await ffastdb.init('a', directory: dirA.path);
    await a.insert({'who': 'a'});
    final b = await ffastdb.init('b', directory: dirB.path);
    expect(identical(a, b), isFalse);
    expect(await b.count(), 0);
    expect(identical(ffastdb.db, b), isTrue);
    await ffastdb.close();
  });
}
