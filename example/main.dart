import 'dart:io';
import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/io/io_storage_strategy.dart';
import 'package:ffastdb/src/storage/wal_storage_strategy.dart';

/// Minimal FastDB example showing the core API.
void main() async {
  final dir = Directory.systemTemp.createTempSync('fastdb_example_');
  final db = await FfastDb.init(
    WalStorageStrategy(
      main: IoStorageStrategy('${dir.path}/mydb.fdb'),
      wal: IoStorageStrategy('${dir.path}/mydb.fdb.wal'),
    ),
  );

  // ── Register secondary indexes before open() ─────────────────────────────
  db.addSortedIndex('age');   // range / sort queries
  db.addIndex('city');        // O(1) equality lookup

  // ── Insert ───────────────────────────────────────────────────────────────
  final aliceId = await db.insert({'name': 'Alice', 'age': 30, 'city': 'Paris'});
  final bobId   = await db.insert({'name': 'Bob',   'age': 25, 'city': 'London'});
  await db.insert({'name': 'Carol', 'age': 35, 'city': 'Paris'});

  print('Inserted Alice as ID $aliceId, Bob as ID $bobId');

  // ── Batch insert ─────────────────────────────────────────────────────────
  final extraIds = await db.insertAll([
    {'name': 'Dave',  'age': 28, 'city': 'Berlin'},
    {'name': 'Eve',   'age': 22, 'city': 'Paris'},
  ]);
  print('Batch inserted IDs: $extraIds');

  // ── Find by primary key ───────────────────────────────────────────────────
  final alice = await db.findById(aliceId);
  print('findById($aliceId): $alice');

  // ── Query with secondary indexes ──────────────────────────────────────────
  // All people in Paris (hash index equality)
  final parisIds = db.query().where('city').equals('Paris').findIds();
  print('People in Paris (IDs): $parisIds');

  // People aged 25–30 (sorted index range)
  final ageIds = db.query().where('age').between(25, 30).findIds();
  print('People aged 25–30 (IDs): $ageIds');

  // Sorted by age descending, limit 2
  final topTwo = db.query()
      .where('age').greaterThan(0)
      .sortBy('age', descending: true)
      .limit(2)
      .findIds();
  print('Top 2 eldest (IDs): $topTwo');

  // ── Update ───────────────────────────────────────────────────────────────
  await db.update(aliceId, {'age': 31, 'city': 'Tokyo'});
  final updatedAlice = await db.findById(aliceId);
  print('After update: $updatedAlice');

  // ── Transaction (atomic) ─────────────────────────────────────────────────
  try {
    await db.transaction(() async {
      await db.insert({'name': 'Frank', 'age': 40, 'city': 'Rome'});
      throw Exception('Simulate failure'); // rolls back the insert
    });
  } catch (_) {}
  final countAfterRollback = await db.count();
  print('Count after rolled-back transaction: $countAfterRollback'); // Frank not there

  // ── Delete + compact ──────────────────────────────────────────────────────
  await db.delete(bobId);
  await db.compact(); // reclaim space from deleted/updated docs
  print('Count after delete + compact: ${await db.count()}');

  // ── Reactive watcher ─────────────────────────────────────────────────────
  final subscription = db.watch('city').listen((ids) {
    print('city index changed, affected IDs: $ids');
  });

  await db.insert({'name': 'Grace', 'age': 27, 'city': 'Paris'}); // fires watcher
  await subscription.cancel();

  // ── Close (persists everything) ───────────────────────────────────────────
  await FfastDb.disposeInstance();
  print('Done.');

  // Clean up temp directory
  await dir.delete(recursive: true);
}
