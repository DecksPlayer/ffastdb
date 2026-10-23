import 'dart:math';
import 'dart:typed_data';

import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

/// Storage that only guarantees what was flushed. A "power loss" keeps the
/// flushed bytes plus a RANDOM SUBSET, in RANDOM ORDER, of the writes issued
/// since the last flush — what an OS page cache and a reordering disk may do.
class PowerLossStorage implements StorageStrategy {
  final MemoryStorageStrategy _live = MemoryStorageStrategy();
  Uint8List _durable;
  final List<(int, Uint8List?)> _unflushed = []; // (offset, data) | (size, null) = truncate

  PowerLossStorage([Uint8List? initial]) : _durable = initial ?? Uint8List(0) {
    if (_durable.isNotEmpty) _live.write(0, _durable);
  }

  /// The storage as it would be found after a power loss now.
  PowerLossStorage crash(Random rnd) {
    var bytes = Uint8List.fromList(_durable);
    final survivors = [..._unflushed.where((_) => rnd.nextBool())]..shuffle(rnd);
    for (final (pos, data) in survivors) {
      if (data == null) {
        if (pos < bytes.length) bytes = Uint8List.fromList(bytes.sublist(0, pos));
      } else {
        if (pos + data.length > bytes.length) {
          bytes = Uint8List(pos + data.length)..setRange(0, bytes.length, bytes);
        }
        bytes.setRange(pos, pos + data.length, data);
      }
    }
    return PowerLossStorage(bytes);
  }

  @override
  Future<void> write(int offset, Uint8List data) async {
    _unflushed.add((offset, Uint8List.fromList(data)));
    await _live.write(offset, data);
  }

  @override
  Future<void> truncate(int size) async {
    _unflushed.add((size, null));
    await _live.truncate(size);
  }

  @override
  Future<void> flush() async {
    _durable = await _live.read(0, await _live.size);
    _unflushed.clear();
  }

  @override
  Future<Uint8List> read(int offset, int size) => _live.read(offset, size);
  @override
  Future<int> get size => _live.size;
  @override
  Future<void> open() async {}
  @override
  Future<void> close() => flush();
  @override
  StorageStrategy? get innerStorage => null;
  @override
  int? get sizeSync => null;
  @override
  Uint8List? readSync(int offset, int size) => null;
  @override
  bool writeSync(int offset, Uint8List data) => false;
  @override
  bool get needsExplicitFlush => true;
}

FastDB openDb(PowerLossStorage main, PowerLossStorage wal, Durability d) =>
    FastDB.forTesting(WalStorageStrategy(main: main, wal: wal, durability: d))
      ..addIndex('s');

Future<Map<int, Map>> snapshot(FastDB db) async => {
      for (final d in await db.getAll()) d['ffdbID'] as int: Map.of(d as Map),
    };

void main() {
  for (final durability in Durability.values) {
    test('power loss never corrupts (${durability.name})', () async {
      for (int seed = 0; seed < 12; seed++) {
        final rnd = Random(seed);
        var main = PowerLossStorage(), wal = PowerLossStorage();
        var db = openDb(main, wal, durability);
        await db.open();

        final states = <Map<int, Map>>[await snapshot(db)];
        final opCount = 20 + rnd.nextInt(60);
        for (int op = 0; op < opCount; op++) {
          final ids = states.last.keys.toList();
          final r = rnd.nextInt(10);
          if (r < 4 || ids.isEmpty) {
            await db.insert({'s': 'v${rnd.nextInt(4)}', 'n': op});
          } else if (r < 6) {
            await db.update(ids[rnd.nextInt(ids.length)], {'s': 'u${rnd.nextInt(4)}'});
          } else if (r < 8) {
            await db.delete(ids[rnd.nextInt(ids.length)]);
          } else if (r < 9) {
            await db.insertAll([for (int i = 0; i < 30; i++) {'s': 'b', 'n': i}]);
          } else {
            await db.transaction(() async {
              await db.insert({'s': 'tx'});
              if (ids.isNotEmpty) await db.delete(ids.first);
            });
          }
          if (rnd.nextInt(15) == 0) await db.flush();
          states.add(await snapshot(db));
        }

        // Power loss after the last completed operation; reopen.
        main = main.crash(rnd);
        wal = wal.crash(rnd);
        db = openDb(main, wal, durability);
        await db.open();
        final recovered = await snapshot(db);

        String show(Map<int, Map> m) => (m.keys.toList()..sort()).join(',');
        if (durability == Durability.full) {
          expect(show(recovered), show(states.last), reason: 'seed $seed');
        }
        final match = states.lastIndexWhere((s) =>
            show(s) == show(recovered) &&
            s.keys.every((id) => s[id]!['s'] == recovered[id]!['s']));
        expect(match, isNot(-1),
            reason: 'seed $seed: recovered state is not any committed state');
        // Indexes agree with the data.
        for (final v in {'v0', 'v1', 'v2', 'v3', 'b', 'tx'}) {
          expect(await db.query().where('s').equals(v).count(),
              recovered.values.where((d) => d['s'] == v).length,
              reason: 'seed $seed, s=$v');
        }
        await db.close();
      }
    });
  }

  test('normal durability defers the main-file write until a checkpoint',
      () async {
    final main = MemoryStorageStrategy(), wal = MemoryStorageStrategy();
    final w = WalStorageStrategy(main: main, wal: wal, durability: Durability.normal);
    await w.open();
    await w.write(0, Uint8List.fromList([1, 2, 3]));
    expect(await main.size, 0, reason: 'not applied yet');
    expect(await w.read(0, 3), [1, 2, 3], reason: 'visible to reads');
    expect(await w.size, 3);
    await w.flush(); // checkpoint
    expect(await main.read(0, 3), [1, 2, 3]);
    expect(await wal.size, 0);
  });
}
