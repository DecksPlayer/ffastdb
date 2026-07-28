import 'dart:math';

import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

/// Query-engine fuzzing: random documents and random queries, with the
/// engine's result compared against a naive linear-filter oracle.
///
/// Deterministic (seeded) — a failure prints its seed and is reproducible.
/// Scale up with FFASTDB_FUZZ_SEEDS / FFASTDB_FUZZ_QUERIES.
void main() {
  final seeds =
      int.tryParse(const String.fromEnvironment('FFASTDB_FUZZ_SEEDS')) ?? 20;
  final queryCount =
      int.tryParse(const String.fromEnvironment('FFASTDB_FUZZ_QUERIES')) ??
          500;

  // Small value universes force collisions, nulls, missing fields and
  // duplicate values — the interesting corners.
  const statuses = ['active', 'inactive', 'pending', 'banned'];
  const cities = ['London', 'Paris', 'Berlin', null];

  Map<String, dynamic> randomDoc(Random r, int i) {
    final doc = <String, dynamic>{'seq': i};
    // age: int, sometimes null, sometimes missing, sometimes extreme
    switch (r.nextInt(10)) {
      case 0:
        break; // missing
      case 1:
        doc['age'] = null;
        break;
      case 2:
        doc['age'] = r.nextInt(3); // heavy duplication
        break;
      case 3:
        doc['age'] = 1 << 40 + r.nextInt(1000); // large int
        break;
      case 4:
        doc['age'] = r.nextInt(100) + 0.5; // double among ints
        break;
      default:
        doc['age'] = r.nextInt(100);
    }
    // status: from small set, sometimes missing
    if (r.nextInt(10) > 0) doc['status'] = statuses[r.nextInt(statuses.length)];
    // city: small set with nulls
    if (r.nextInt(10) > 1) {
      final c = cities[r.nextInt(cities.length)];
      if (c != null) doc['city'] = c;
    }
    // score: double, sometimes negative/extreme
    switch (r.nextInt(8)) {
      case 0:
        break;
      case 1:
        doc['score'] = -1e-300;
        break;
      case 2:
        doc['score'] = 1e300;
        break;
      default:
        doc['score'] = r.nextDouble() * 200 - 100;
    }
    // vip: bool, often missing
    if (r.nextInt(3) == 0) doc['vip'] = r.nextBool();
    return doc;
  }

  // ── Oracle: plain linear filter with the same semantics ──
  bool numEq(dynamic a, dynamic b) =>
      a is num && b is num && a.compareTo(b) == 0;

  bool matches(Map<String, dynamic> doc, _Cond c) {
    final v = doc[c.field];
    switch (c.op) {
      case 'eq':
        final w = c.value;
        if (v is num && w is num) return numEq(v, w);
        return v == w;
      case 'between':
        if (v is! num) return false;
        return v.compareTo(c.value as num) >= 0 &&
            v.compareTo(c.value2 as num) <= 0;
      case 'isNull':
        return v == null;
      default:
        throw StateError(c.op);
    }
  }

  test('query engine matches linear-filter oracle on random data', () async {
    for (var seed = 0; seed < seeds; seed++) {
      final r = Random(seed);
      final db = FastDB.forTesting(MemoryStorageStrategy());
      await db.open();
      db.addIndex('status');
      db.addSortedIndex('age');
      db.addCompositeIndex(['city', 'status']);

      final docCount = 100 + r.nextInt(200);
      final docs = List.generate(docCount, (i) => randomDoc(r, i));
      final ids = await db.insertAll(docs);
      final byId = {for (var k = 0; k < docCount; k++) ids[k]: docs[k]};

      for (var q = 0; q < queryCount; q++) {
        final cond = _Cond.random(r);
        final conds = [cond];
        // Half the queries get a second AND condition.
        if (r.nextBool()) conds.add(_Cond.random(r));

        final qb = db.query();
        for (final c in conds) {
          switch (c.op) {
            case 'eq':
              qb.where(c.field).equals(c.value);
            case 'between':
              qb.where(c.field).between(c.value, c.value2);
            case 'isNull':
              qb.where(c.field).isNull();
          }
        }
        final engineIds = (await qb.findIds()).toSet();

        final oracleIds = byId.entries
            .where((e) => conds.every((c) => matches(e.value, c)))
            .map((e) => e.key)
            .toSet();

        expect(engineIds, oracleIds,
            reason:
                'seed=$seed query=$q $conds\nengine: $engineIds\noracle: $oracleIds');
      }

      await db.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

class _Cond {
  _Cond(this.field, this.op, [this.value, this.value2]);

  factory _Cond.random(Random r) {
    const fields = ['age', 'status', 'city', 'score', 'vip'];
    final field = fields[r.nextInt(fields.length)];
    switch (field) {
      case 'age':
        switch (r.nextInt(3)) {
          case 0:
            return _Cond(field, 'eq', r.nextInt(3)); // hits the dup cluster
          case 1:
            return _Cond(field, 'isNull');
          default:
            final lo = r.nextInt(60);
            return _Cond(field, 'between', lo, lo + r.nextInt(60));
        }
      case 'score':
        final lo = r.nextDouble() * 200 - 100;
        return _Cond(field, 'between', lo, lo + r.nextDouble() * 100);
      case 'status':
        return _Cond(
            field, 'eq', ['active', 'inactive', 'pending', 'banned', 'nope'][r.nextInt(5)]);
      case 'city':
        return _Cond(field, 'eq',
            ['London', 'Paris', 'Berlin', 'Madrid'][r.nextInt(4)]);
      default:
        return _Cond(field, 'eq', r.nextBool());
    }
  }

  final String field;
  final String op;
  final dynamic value;
  final dynamic value2;

  @override
  String toString() => op == 'between'
      ? '$field between $value and $value2'
      : '$field $op $value';
}
