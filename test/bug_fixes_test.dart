// Tests de regresión para los bugs encontrados en la auditoría (FIX_PLAN.md).
// Cada test referencia su ID de hallazgo (F<fase>.<n>).
// Estos tests FALLAN antes del fix correspondiente y deben PASAR después.
import 'dart:io';
import 'dart:typed_data';

import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';
import 'package:ffastdb/src/storage/io/io_storage_strategy.dart';
import 'package:ffastdb/src/storage/page_manager.dart';
import 'package:test/test.dart';

/// Storage espía que extiende el de memoria pero reporta
/// needsExplicitFlush=true (simula IndexedDB/IO), contando flushes
/// y truncates y grabando el orden de eventos async.
class _FlushSpy extends MemoryStorageStrategy {
  int flushes = 0;
  int truncates = 0;
  final List<String> events = [];

  @override
  bool get needsExplicitFlush => true;

  @override
  Future<void> write(int offset, Uint8List data) {
    events.add('w:$offset');
    return super.write(offset, data);
  }

  @override
  Future<void> flush() async {
    flushes++;
    events.add('flush');
    await super.flush();
  }

  @override
  Future<void> truncate(int size) {
    truncates++;
    return super.truncate(size);
  }
}

void main() {
  late FastDB db;

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  group('FASE 1 — Críticos', () {
    test('F1.1: getAll/count no pierden el último doc tras bulkLoad (N=229)', () async {
      db = FastDB.forTesting(MemoryStorageStrategy());
      await db.open();
      final ids = await db.insertAll(List.generate(229, (i) => {'n': i}));
      expect(ids.length, 229);
      expect((await db.getAll()).length, 229,
          reason: 'rangeSearch pierde la última clave cuando keys.last == high');
      expect(await db.count(), 229);
      final rs = await db.rangeSearch(1, 229);
      expect(rs.contains(229), isTrue);
    });

    test('F1.2: BufferedStorageStrategy no descarta escrituras contenidas', () async {
      final buf = BufferedStorageStrategy(MemoryStorageStrategy());
      await buf.open();
      await buf.write(0, Uint8List.fromList([1, 1, 1, 1, 1, 1, 1, 1]));
      await buf.write(2, Uint8List.fromList([9, 9])); // contenida, más reciente
      await buf.commit();
      final r = await buf.read(0, 8);
      expect(r, [1, 1, 9, 9, 1, 1, 1, 1],
          reason: 'la escritura contenida más reciente debe ganar');
      // Mismo offset dos veces: la última gana
      await buf.write(0, Uint8List.fromList([1, 2, 3, 4]));
      await buf.write(0, Uint8List.fromList([5, 6, 7, 8]));
      await buf.commit();
      final r2 = await buf.read(0, 4);
      expect(r2, [5, 6, 7, 8]);
      await buf.close();
    });

    test('F1.3: write-through tras write-behind no revive dirty page obsoleta', () async {
      final mem = MemoryStorageStrategy();
      await mem.open();
      final pm = PageManager(mem);
      final pageA = Uint8List(PageManager.pageSize)..[0] = 0xAA;
      final pageB = Uint8List(PageManager.pageSize)..[0] = 0xBB;
      pm.writeBehind = true;
      await pm.writePage(5, pageA); // queda dirty (obsoleta tras el siguiente write)
      pm.setWriteBehind(false);
      await pm.writePage(5, pageB); // write-through: disco = B
      await pm.flushDirty(); // con el bug: escribe A obsoleto encima de B
      final disk = await mem.read(5 * PageManager.pageSize, PageManager.pageSize);
      expect(disk[0], 0xBB,
          reason: 'la dirty page obsoleta no debe sobrescribir el dato nuevo');
    });

    test('F1.4: Encrypted(WAL) agrupa escrituras en UNA transacción WAL', () async {
      final path = 'test_bf_enc_wal.fdb';
      final spyWal = _FlushSpy();
      final db = FastDB.forTesting(
        EncryptedStorageStrategy(
          WalStorageStrategy(
            main: IoStorageStrategy(path),
            wal: spyWal,
          ),
          'test-password',
        ),
      );
      await db.open();
      spyWal.truncates = 0; // ignorar los de open()
      await db.insert({'a': 1});
      expect(spyWal.truncates, lessThanOrEqualTo(1),
          reason:
              'con el wrapper cifrado no detectado, cada escritura interna abre su propia tx WAL (truncate por commit)');
      await db.close();
      for (final ext in ['', '.wal', '.lock', '.port', '.log']) {
        final f = File('$path$ext');
        if (f.existsSync()) f.deleteSync();
      }
    });

    test('F1.5: la query cache no se comparte entre instancias de FastDB', () async {
      final db1 = FastDB.forTesting(MemoryStorageStrategy());
      await db1.open();
      db1.addIndex('status');
      await db1.insert({'status': 'active'});

      final db2 = FastDB.forTesting(MemoryStorageStrategy());
      await db2.open();
      db2.addIndex('status');

      // Poblar la caché con la query de db1 DESPUÉS de abrir db2
      final r1 = await db1.query().where('status').equals('active').findIds();
      expect(r1.length, 1);
      final r2 = await db2.query().where('status').equals('active').findIds();
      expect(r2, isEmpty,
          reason: 'db2 está vacía: no debe recibir resultados cacheados de db1');

      await db1.close();
      db = db2; // para tearDown
    });

    test('F1.6: condición sobre campo sin índice hace full-scan con filtrado', () async {
      db = FastDB.forTesting(MemoryStorageStrategy());
      await db.open();
      db.addIndex('status');
      await db.insert({'status': 'active', 'age': 30});
      await db.insert({'status': 'active', 'age': 10});
      await db.insert({'status': 'inactive', 'age': 30});

      // Sin índice en 'age', una sola condición:
      final solo = await db.query().where('age').equals(30).find();
      expect(solo.length, 2, reason: 'full-scan debe encontrar ambos age=30');

      // Mezcla indexada + no indexada:
      final mixta = await db
          .query()
          .where('status').equals('active')
          .where('age').equals(30)
          .find();
      expect(mixta.length, 1,
          reason: 'la condición sin índice no debe descartarse');
      expect(mixta.first['age'], 30);

      // Rango sin índice:
      final rango = await db.query().where('age').between(5, 35).find();
      expect(rango.length, 3);

      // isNull sin índice: todos los docs carecen del campo → todos
      final nulo = await db.query().where('email').isNull().find();
      expect(nulo.length, 3);
    });
  });

  group('FASE 2 — Altos', () {
    test('F2.1: WAL lee sus propias escrituras dentro de una transacción', () async {
      final path = 'test_bf_wal_ryw.fdb';
      db = FastDB.forTesting(
        WalStorageStrategy(
          main: IoStorageStrategy(path),
          wal: IoStorageStrategy('$path.wal'),
        ),
      );
      await db.open();
      await db.transaction(() async {
        final id = await db.insert({'v': 42});
        final doc = await db.findById(id);
        expect(doc, isNotNull,
            reason: 'read-your-writes: la tx debe ver sus escrituras pendientes');
        expect(doc['v'], 42);
        // También updates de docs existentes dentro de la tx:
        await db.update(id, {'v': 43});
        final doc2 = await db.findById(id);
        expect(doc2['v'], 43);
      });
      await db.close();
      for (final ext in ['', '.wal', '.lock', '.port', '.log']) {
        final f = File('$path$ext');
        if (f.existsSync()) f.deleteSync();
      }
    });

    test('F2.2: delete() hace flush en storages con needsExplicitFlush', () async {
      final spy = _FlushSpy();
      db = FastDB.forTesting(spy);
      await db.open();
      final id = await db.insert({'a': 1});
      final afterInsert = spy.flushes;
      expect(afterInsert, greaterThan(0));
      await db.delete(id);
      expect(spy.flushes, greaterThan(afterInsert),
          reason: 'delete debe flushear como insert/update (durabilidad web)');
    });

    test('F2.3: header se guarda ANTES del flush (no después)', () async {
      final spy = _FlushSpy();
      db = FastDB.forTesting(spy);
      await db.open();
      spy.events.clear();
      await db.insert({'a': 1});
      expect(spy.events.isNotEmpty, isTrue);
      expect(spy.events.last, 'flush',
          reason:
              'el header (rootPage/nextId) debe quedar durable en el mismo flush que el documento');
    });

    test('F2.5: la clave de caché distingue tipos (1 vs "1")', () async {
      db = FastDB.forTesting(MemoryStorageStrategy());
      await db.open();
      db.addIndex('v');
      final idInt = await db.insert({'v': 1});
      final idStr = await db.insert({'v': '1'});
      final rInt = await db.query().where('v').equals(1).findIds();
      final rStr = await db.query().where('v').equals('1').findIds();
      expect(rInt, [idInt]);
      expect(rStr, [idStr],
          reason: 'equals(1) y equals("1") no pueden compartir entrada de caché');
    });

    test('F2.6: los resultados cacheados son inmutables (no envenenan la caché)', () async {
      db = FastDB.forTesting(MemoryStorageStrategy());
      await db.open();
      db.addSortedIndex('age');
      await db.insert({'age': 30});
      await db.insert({'age': 30});
      final r1 = await db.query().where('age').equals(30).findIds();
      final r2 = await db.query().where('age').equals(30).findIds(); // cache hit
      expect(r1, orderedEquals(r2));
      // Mutar un resultado debe fallar (protección anti-aliasing de la caché):
      expect(() => r1.sort((a, b) => b.compareTo(a)), throwsUnsupportedError,
          reason: 'los resultados congelados no pueden mutarse ni envenenar la caché');
      // Y la caché sigue intacta:
      final r3 = await db.query().where('age').equals(30).findIds();
      expect(r3, orderedEquals(r2));
      // Si se necesita mutar, basta copiar:
      final mutable = r1.toList()..sort((a, b) => b.compareTo(a));
      expect(mutable.length, 2);
    });

    test('F2.7: SortedIndex/BitmaskIndex serializan int64 sin truncar', () {
      final micros = 1750000000000000; // ~2025 en micros, > 2^31
      final sorted = SortedIndex('ts');
      sorted.add(1, micros);
      sorted.add(2, micros + 1000);
      final restored = SortedIndex.deserialize(sorted.serialize());
      expect(restored.lookup(micros), [1]);
      expect(restored.lookup(micros + 1000), [2]);
      expect(restored.range(micros, micros + 1000).length, 2);

      final bit = BitmaskIndex('flag');
      bit.add(1, micros);
      final restoredBit = BitmaskIndex.deserialize(bit.serialize());
      expect(restoredBit.lookup(micros), [1]);
    });

    test('F2.8: _writeValue falla rápido con tipos no soportados', () {
      final idx = SortedIndex('d');
      idx.add(1, DateTime.now());
      expect(() => idx.serialize(), throwsArgumentError,
          reason: 'mejor un error explícito que un blob de índice corrupto');
    });

    test('F2.9: composite key sin colisiones de delimitador ni de tipos', () async {
      db = FastDB.forTesting(MemoryStorageStrategy());
      await db.open();
      db.addCompositeIndex(['a', 'b']);
      final id1 = await db.insert({'a': 'x|y', 'b': 'z'});
      await db.insert({'a': 'x', 'b': 'y|z'});
      final r = await db
          .query()
          .where('a').equals('x|y')
          .where('b').equals('z')
          .findIds();
      expect(r, [id1], reason: "'a|b','c' y 'a','b|c' no pueden colisionar");

      final id3 = await db.insert({'a': 1, 'b': '1'});
      await db.insert({'a': '1', 'b': 1});
      final r2 = await db
          .query()
          .where('a').equals(1)
          .where('b').equals('1')
          .findIds();
      expect(r2, [id3], reason: '1 (int) y "1" (String) no pueden colisionar');
    });

    test('F2.10: count() ignora limit/offset de forma consistente', () async {
      db = FastDB.forTesting(MemoryStorageStrategy());
      await db.open();
      db.addIndex('s');
      db.addIndex('t');
      for (int i = 0; i < 5; i++) {
        await db.insert({'s': 'a', 't': 'b'});
      }
      // Fast path (1 condición)
      expect(await db.query().where('s').equals('a').count(), 5);
      expect(await db.query().where('s').equals('a').limit(2).count(), 5);
      // Slow path (2 condiciones) — antes devolvía 2 con limit(2)
      expect(
          await db
              .query()
              .where('s').equals('a')
              .where('t').equals('b')
              .limit(2)
              .count(),
          5);
    });

    test('F2.11: upsert respeta el id manual', () async {
      db = FastDB.forTesting(MemoryStorageStrategy());
      await db.open();
      final id = await db.upsert(10, {'name': 'Alice'});
      expect(id, 10);
      final doc = await db.findById(10);
      expect(doc, isNotNull);
      expect(doc['name'], 'Alice');
      // El siguiente id auto-incremental continúa desde 11
      final id2 = await db.insert({'name': 'Bob'});
      expect(id2, 11);
    });
  });

  group('FASE 3 — Medios', () {
    test('F3.3: not().isNull() equivale a isNotNull()', () async {
      db = FastDB.forTesting(MemoryStorageStrategy());
      await db.open();
      db.addIndex('email');
      await db.insert({'email': 'a@b.c'});
      await db.insert({'name': 'sin email'});
      final r = await db.query().where('email').not().isNull().find();
      expect(r.length, 1);
      expect(r.first['email'], 'a@b.c');
    });

    test('F3.5: put con id < 1 lanza ArgumentError', () async {
      db = FastDB.forTesting(MemoryStorageStrategy());
      await db.open();
      await expectLater(db.put(0, {'v': 1}), throwsArgumentError);
      await expectLater(db.put(-5, {'v': 1}), throwsArgumentError);
    });

    test('F3.7: comparador unificado — 1==1.0 y tipos mixtos no crashean', () async {
      db = FastDB.forTesting(MemoryStorageStrategy());
      await db.open();
      db.addIndex('v');
      db.addSortedIndex('v2');
      await db.insert({'v': 1, 'v2': 1});
      await db.insert({'v': 1.0, 'v2': 1.0});
      // numéricamente iguales en ambos tipos de índice
      final rHash = await db.query().where('v').equals(1).findIds();
      expect(rHash.length, 2, reason: 'equals(1) casa 1 y 1.0 numéricamente');
      final rSorted = await db.query().where('v2').equals(1.0).findIds();
      expect(rSorted.length, 2);
      // Campo de tipo mixto no debe romper el SortedIndex
      await db.insert({'v2': 'texto'});
      final all = await db.getAll();
      expect(all.length, 3);
    });

    test('F3.10: startsWith con prefijo terminado en U+FFFF', () async {
      db = FastDB.forTesting(MemoryStorageStrategy());
      await db.open();
      db.addSortedIndex('s');
      await db.insert({'s': 'a\u{FFFF}x'});
      await db.insert({'s': 'b'});
      final r = await db.query().where('s').startsWith('a\u{FFFF}').findIds();
      expect(r.length, 1);
    });

    test('F3.13: rollback de transaction revierte índices secundarios', () async {
      db = FastDB.forTesting(MemoryStorageStrategy());
      await db.open();
      db.addIndex('status');
      await db.insert({'status': 'a'});
      try {
        await db.transaction(() async {
          await db.insert({'status': 'b'});
          throw StateError('rollback forzado');
        });
      } on StateError {
        // esperado
      }
      final r = await db.query().where('status').equals('b').findIds();
      expect(r, isEmpty,
          reason: 'el rollback debe deshacer también los índices secundarios');
      expect(await db.count(), 1);
    });
  });
}
