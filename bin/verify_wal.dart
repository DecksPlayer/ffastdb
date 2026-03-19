import 'dart:typed_data';
import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';
import 'package:ffastdb/src/storage/wal_storage_strategy.dart';

void main() async {
  print('=== FastDB WAL Crash Recovery Test ===\n');

  // ─── Shared in-memory storage (simulates a real file pair: main + wal) ───
  final mainStorage = MemoryStorageStrategy();
  final walStorage = MemoryStorageStrategy();

  // ─── Phase 1: Normal operation with WAL ──────────────────────────────────
  print('Phase 1: Normal operation with WAL protection...');
  {
    final wal = WalStorageStrategy(main: mainStorage, wal: walStorage);
    final db = FastDB(wal, cacheCapacity: 256);
    db.addIndex('city');
    await db.open();

    await db.insertAll([
      {'name': 'Alice', 'city': 'London', 'age': 30},
      {'name': 'Bob', 'city': 'Paris', 'age': 25},
      {'name': 'Clara', 'city': 'Tokyo', 'age': 28},
    ]);

    await db.checkpoint(); // Flush WAL → main, clear WAL
    print('  Inserted 3 docs and checkpointed WAL.');
    print('  WAL size after checkpoint: ${await walStorage.size} bytes (should be 0)');

    await db.close();
  }

  // ─── Phase 2: Simulate crash MID-TRANSACTION ─────────────────────────────
  print('\nPhase 2: Simulating crash mid-transaction...');
  {
    final wal = WalStorageStrategy(main: mainStorage, wal: walStorage);

    // Start a transaction manually
    await wal.open();
    await wal.beginTransaction();

    // Write some data to WAL (simulate an incomplete write)
    final fakeData = Uint8List.fromList(List.generate(50, (i) => i));
    await wal.write(99999, fakeData);

    // ⚡ CRASH: Never call commit() — simulates app killed mid-write
    print('  Crash! Transaction was NOT committed (no COMMIT marker in WAL).');
    print('  WAL size before recovery: ${await walStorage.size} bytes');
    // Don't call close — just abandon
  }

  // ─── Phase 3: Reopen — WAL recovery should discard incomplete tx ─────────
  print('\nPhase 3: Reopening database (WAL recovery)...');
  {
    final wal = WalStorageStrategy(main: mainStorage, wal: walStorage);
    final db = FastDB(wal, cacheCapacity: 256);
    db.addIndex('city');
    await db.open(); // This triggers _recover() internally

    print('  Database reopened successfully.');
    print('  WAL size after recovery: ${await walStorage.size} bytes');

    // The 3 original docs should still be there
    final alice = await db.findById(1);
    final bob = await db.findById(2);
    final clara = await db.findById(3);

    print('\n  Verifying data integrity after crash recovery:');
    print('  ID 1 → ${alice?['name']} (expected: Alice)');
    print('  ID 2 → ${bob?['name']} (expected: Bob)');
    print('  ID 3 → ${clara?['name']} (expected: Clara)');

    // The corrupt write to offset 99999 should NOT be there
    final corrupt = await db.findById(9999);
    print('\n  Corrupt write (ID 9999) → $corrupt (expected: null)');

    if (alice?['name'] == 'Alice' && bob?['name'] == 'Bob' &&
        clara?['name'] == 'Clara' && corrupt == null) {
      print('\n✅ WAL crash recovery PASSED — data integrity maintained!');
    } else {
      print('\n❌ WAL crash recovery FAILED');
    }

    await db.close();
  }

  // ─── Phase 4: Normal write after recovery ────────────────────────────────
  print('\nPhase 4: Post-recovery write works normally...');
  {
    final wal = WalStorageStrategy(main: mainStorage, wal: walStorage);
    final db = FastDB(wal, cacheCapacity: 256);
    await db.open();

    final id = await db.insert({'name': 'Dana', 'city': 'Sydney', 'age': 22});
    final dana = await db.findById(id);
    print('  Inserted: $dana');
    print('  ✅ Post-recovery writes work correctly!');

    await db.close();
  }

  print('\n=== WAL Test Complete ===');
}
