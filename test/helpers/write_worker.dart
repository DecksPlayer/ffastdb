/// Writer process for `kill_recovery_test.dart` and `multi_process_lock_test.dart`.
///
/// Opens a database exactly like a production app (`openDatabase`) and writes
/// in a tight loop with no delay. The test kills this process with SIGKILL at
/// a random moment to simulate a real crash (user force-close, Android OOM
/// killer, power loss) in the middle of a `write()` syscall.
///
/// Usage: `write_worker <directory> <name> [mode] [encryptionKey]`
///
/// Modes:
/// - `insert`   (default) single inserts
/// - `batch`    large `insertAll` batches (bulk write path)
/// - `update`   inserts + in-flight `update()` by id
/// - `compact`  inserts + deletes + periodic `compact()` (full file rewrite)
/// - `reindex`  inserts + periodic `reindex()` (index rebuild)
/// - `blob`     inserts with large `Uint8List` payloads (raw bytes path)
/// - `migrate`  opens an EXISTING v1 database with `version: 2` and a
///              non-idempotent migration (increments `counter`) — used by
///              the kill-during-schema-migration test. READY is printed
///              from inside the migration function, on the first migrated
///              doc, so the kill lands mid-migration.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:ffastdb/ffastdb.dart';

/// Deterministic 64 KB payload for blob mode — the test recomputes samples
/// from `n` to detect torn blob writes.
Uint8List blobPayload(int n) {
  final b = Uint8List(64 * 1024);
  for (var j = 0; j < b.length; j++) {
    b[j] = (n * 31 + j) & 0xFF;
  }
  return b;
}

Map<String, dynamic> doc(int i, {bool blob = false}) => {
      'n': i,
      'status': i.isEven ? 'even' : 'odd',
      'payload': blob ? blobPayload(i) : 'doc-$i-${'x' * 64}',
    };

/// The non-idempotent v1→v2 migration used by `migrate` mode and mirrored by
/// the controller test: increments `counter`. If migrations are re-run after
/// a crash, already-migrated docs get `counter == 2` — the test detects it.
Map<String, dynamic> counterMigration(dynamic doc) {
  final d = Map<String, dynamic>.from(doc as Map);
  d['counter'] = (d['counter'] as int? ?? 0) + 1;
  return d;
}

Future<void> main(List<String> args) async {
  final directory = args[0];
  final name = args[1];
  final mode = args.length > 2 ? args[2] : 'insert';
  final encryptionKey = args.length > 3 ? args[3] : null;

  if (mode == 'migrate') {
    var announced = false;
    await openDatabase(
      name,
      directory: directory,
      indexes: ['status'],
      sortedIndexes: ['n'],
      version: 2,
      migrations: {
        1: (doc) {
          // Signal from INSIDE the migration so the kill lands mid-flight.
          if (!announced) {
            announced = true;
            stdout.writeln('READY');
            stdout.flush();
          }
          return counterMigration(doc);
        },
      },
    );
    // If we get here, the migration completed without being killed.
    stdout.writeln('MIGRATION_DONE');
    await stdout.flush();
    // Stay alive — the controller decides when to kill us.
    while (true) {
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  final db = await openDatabase(
    name,
    directory: directory,
    indexes: ['status'],
    sortedIndexes: ['n'],
    compositeIndexes: [
      ['status', 'n'],
    ],
    encryptionKey: encryptionKey,
  );

  // Handshake: tell the controller the DB is open and writes are starting.
  stdout.writeln('READY');
  await stdout.flush();

  switch (mode) {
    case 'batch':
      var base = 0;
      while (true) {
        await db.insertAll(List.generate(200, (k) => doc(base + k)));
        base += 200;
      }
    case 'update':
      var i = 0;
      while (true) {
        await db.insert(doc(i));
        // Doc with n=k always gets ffdbID k+1 (ids are sequential from 1 and
        // never reused), so id i-9 updates the doc inserted 10 inserts ago.
        if (i >= 10) await db.update(i - 9, {'hits': i});
        i++;
      }
    case 'compact':
      var i = 0;
      while (true) {
        await db.insert(doc(i));
        // Sliding window: keep roughly the last 100 docs alive.
        if (i > 100) await db.delete(i - 99); // id of doc n=(i-100)
        if (i % 50 == 0) await db.compact();
        i++;
      }
    case 'reindex':
      var i = 0;
      while (true) {
        await db.insert(doc(i));
        if (i % 25 == 24) await db.reindex('status');
        i++;
      }
    case 'blob':
      var i = 0;
      while (true) {
        await db.insert(doc(i, blob: true));
        i++;
      }
    default: // 'insert'
      var i = 0;
      while (true) {
        await db.insert(doc(i));
        i++;
      }
  }
}
