import 'dart:async';
import 'dart:typed_data';

import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

/// In-memory storage whose writes can be made to fail on demand.
class FlakyStorage extends MemoryStorageStrategy {
  bool failWrites = false;

  @override
  Future<void> write(int offset, Uint8List data) {
    if (failWrites) throw StateError('injected write failure');
    return super.write(offset, data);
  }

  @override
  bool writeSync(int offset, Uint8List data) {
    if (failWrites) throw StateError('injected write failure');
    return super.writeSync(offset, data);
  }
}

class Point {
  final int x;
  Point(this.x);
}

class PointAdapter extends TypeAdapter<Point> {
  @override
  int get typeId => 9;
  @override
  Point read(BinaryReader reader) => Point(reader.readDynamic() as int);
  @override
  void write(BinaryWriter writer, Point obj) => writer.writeDynamic(obj.x);
}

void main() {
  late FlakyStorage storage;
  late FastDB db;

  setUp(() async {
    storage = FlakyStorage();
    db = FastDB.forTesting(storage)..addIndex('status');
    await db.open();
  });

  tearDown(() => db.close());

  /// Starts a transaction that inserts a document and then waits on
  /// [release] before failing — it stays open until the test releases it.
  Future<void> openFailingTransaction(Completer<void> release) {
    return db.transaction(() async {
      await db.insert({'status': 'tx'});
      await release.future;
      throw StateError('abort');
    }).then((_) {}, onError: (_) {});
  }

  group('transaction isolation', () {
    test('writes from another caller are not rolled back with the tx',
        () async {
      final release = Completer<void>();
      final tx = openFailingTransaction(release);
      await Future.delayed(const Duration(milliseconds: 10));
      final other = db.insert({'status': 'other'}); // must wait for the tx
      release.complete();
      final otherId = await other;
      await tx;
      expect((await db.findById(otherId))?['status'], 'other');
      expect(await db.query().where('status').equals('tx').count(), 0);
    });

    test('a second transaction waits for the open one', () async {
      final release = Completer<void>();
      final tx = openFailingTransaction(release);
      await Future.delayed(const Duration(milliseconds: 10));
      final second = db.transaction(() => db.insert({'status': 'second'}));
      release.complete();
      final id = await second;
      await tx;
      expect((await db.findById(id))?['status'], 'second');
    });

    test('query() does not see uncommitted (later rolled back) writes',
        () async {
      final release = Completer<void>();
      final tx = openFailingTransaction(release);
      await Future.delayed(const Duration(milliseconds: 10));
      final indexed = db.query().where('status').equals('tx').findIds();
      final scanned = db.query().where('missing').isNull().find();
      final docs = db.query().where('status').equals('tx').find();
      release.complete();
      await tx;
      expect(await indexed, isEmpty);
      expect(await docs, isEmpty);
      expect(await scanned, isEmpty);
    });

    test('query() inside a transaction sees the transaction\'s writes',
        () async {
      final ids = await db.transaction(() async {
        await db.insert({'status': 'inside'});
        return db.query().where('status').equals('inside').findIds();
      });
      expect(ids, [1]);
    });

    test('update/put/delete of a document inserted in the same transaction',
        () async {
      late int a, b, c;
      await db.transaction(() async {
        a = await db.insert({'status': 'a', 'v': 1});
        await db.update(a, {'v': 2});
        b = await db.insert({'status': 'b'});
        expect(await db.delete(b), isTrue);
        c = await db.insert({'status': 'c', 'v': 1});
        await db.put(c, {'status': 'c', 'v': 3});
        expect(await db.count(), 2);
      });
      expect((await db.findById(a))?['v'], 2);
      expect(await db.findById(b), isNull);
      expect((await db.findById(c))?['v'], 3);
      expect(await db.count(), 2);
      expect(await db.query().where('status').equals('b').count(), 0);
    });

    test('rolled-back inserts leave no trace', () async {
      await db.insert({'status': 'keep'});
      await expectLater(
        db.transaction(() async {
          for (int i = 0; i < 500; i++) {
            await db.insert({'status': 'tx'});
          }
          throw StateError('abort');
        }),
        throwsStateError,
      );
      expect(await db.count(), 1);
      expect(await db.findById(2), isNull);
      expect(await db.query().where('status').equals('tx').count(), 0);
      final id = await db.insert({'status': 'after'});
      expect(id, 2);
      expect((await db.findById(1))?['status'], 'keep');
    });

    test('query cache is invalidated by a committed transaction', () async {
      await db.insert({'status': 'a'});
      expect(await db.query().where('status').equals('a').findIds(), [1]);
      await db.transaction(() => db.insert({'status': 'a'}));
      expect(await db.query().where('status').equals('a').findIds(), [1, 2]);
    });
  });

  test('migration in single-file mode does not overwrite B-Tree pages',
      () async {
    final mem = MemoryStorageStrategy();
    var db = FastDB.forTesting(mem);
    await db.open();
    // Sentinel + 254 ids = a FULL root leaf: the migration's first re-insert
    // splits it and allocates pages right where the next documents go.
    for (int i = 0; i < 254; i++) {
      await db.insert({'n': i, 'pad': 'p' * 20});
    }
    await db.close();

    db = FastDB.forTesting(mem);
    await db.open(version: 2, migrations: {
      1: (doc) => {...doc as Map<String, dynamic>, 'v': 2},
    });
    addTearDown(db.close);
    for (int id = 1; id <= 254; id++) {
      final doc = await db.findById(id);
      expect(doc?['n'], id - 1, reason: 'id $id');
      expect(doc?['v'], 2);
    }
  });

  group('failed bulk operations roll back completely', () {
    test('deleteWhere', () async {
      await db.insertAll([
        for (int i = 0; i < 600; i++) {'status': i.isEven ? 'even' : 'odd'},
      ]);
      await expectLater(
        db.deleteWhere((q) {
          storage.failWrites = true; // fails while committing the deletes
          return q.where('status').equals('even').findIds();
        }),
        throwsStateError,
      );
      storage.failWrites = false;

      expect(await db.count(), 600);
      expect(await db.query().where('status').equals('even').count(), 300);
      for (int id = 1; id <= 600; id++) {
        expect(await db.findById(id), isNotNull, reason: 'id $id');
      }
      final id = await db.insert({'status': 'after'});
      expect((await db.findById(id))?['status'], 'after');
    });

    test('updateWhere', () async {
      db.registerAdapter(PointAdapter());
      await db.insert({'status': 'a', 'n': 1});
      await db.insert({'status': 'a', 'n': 2});
      await db.put(3, Point(7)); // not a Map: update() throws on it
      await expectLater(
        db.updateWhere((_) => [1, 2, 3], {'status': 'b'}),
        throwsUnsupportedError,
      );
      expect((await db.findById(1))?['status'], 'a');
      expect((await db.findById(2))?['status'], 'a');
      expect(await db.query().where('status').equals('a').count(), 2);
      expect(await db.query().where('status').equals('b').count(), 0);
      expect((await db.findById(3) as Point).x, 7);
    });
  });
}
