@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

/// Databases written before the binary document format (JSON records,
/// magic 0x00 0x01) must keep working with no migration step.
///
/// `fixtures/json_v1_format.fdb` was produced by ffastdb 0.3.5 (commit
/// 0e9dcae): one rich document (id 1), 300 documents
/// `{status, age, i}` (ids 2..301, i = id - 2) and id 5 deleted, with a
/// HashIndex on `status` and a SortedIndex on `age`.
void main() {
  late MemoryStorageStrategy storage;

  Future<FastDB> open() async {
    final db = FastDB.forTesting(storage)
      ..addIndex('status')
      ..addSortedIndex('age');
    await db.open();
    return db;
  }

  setUp(() async {
    storage = MemoryStorageStrategy();
    final bytes = File('test/fixtures/json_v1_format.fdb').readAsBytesSync();
    await storage.write(0, bytes);
  });

  void expectRichDoc(dynamic doc) {
    expect(doc['name'], 'Ana Ñandú 🚀');
    expect(doc['big'], 9007199254740993);
    expect(doc['neg'], -123456789012);
    expect(doc['score'], 0.1);
    expect(doc['whole'], 2.0);
    expect(doc['flag'], isTrue);
    expect(doc.containsKey('none'), isTrue);
    expect(doc['when'], DateTime.utc(2024, 5, 6, 7, 8, 9, 123, 456));
    expect(doc['bytes'], Uint8List.fromList([0, 1, 2, 255]));
    expect(doc['tags'], ['x', 1, false, null]);
    expect(doc['nested'], {
      'deep': {'k': 'v'},
      'list': [1, 2],
    });
    expect(doc['escaped'], '\u0000dt:not-a-date');
    expect(doc['empty'], '');
    expect(doc['ffdbID'], 1);
  }

  test('reads JSON-format records and rebuilds indexes from them', () async {
    final db = await open();
    addTearDown(db.close);
    expectRichDoc(await db.findById(1));
    expect(await db.count(), 300);
    expect(await db.findById(5), isNull);
    expect((await db.findById(301))?['i'], 299);
    // 150 even i (id 5 had odd i = 3) + the rich document.
    expect(await db.query().where('status').equals('active').count(), 151);
    // ages 0..9: i in 0..9, 90..99, 180..189, 270..279 minus deleted i = 3.
    expect((await db.query().where('age').between(0, 9).findIds()).length, 39);
  });

  test('mixed v1/v2 records survive updates, reopen and compact', () async {
    var db = await open();
    await db.update(1, {'flag': false}); // rewritten in the binary format
    await db.update(100, {'status': 'archived'});
    await db.insert({'status': 'active', 'age': 5, 'i': -1});
    await db.close();

    db = await open();
    final rich = await db.findById(1);
    expect(rich['flag'], isFalse);
    rich['flag'] = true;
    expectRichDoc(rich);
    expect((await db.findById(100))?['status'], 'archived');
    expect(await db.count(), 301);

    await db.compact(); // single-file compact re-encodes every record (v2)
    expect(await db.count(), 301);
    expect((await db.findById(301))?['i'], 299);
    expect((await db.findById(302))?['i'], -1);
    expect(await db.query().where('status').equals('archived').count(), 1);
    await db.close();
  });
}
