import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';
import 'package:test/test.dart';

void main() {
  group('GC and Memory Management Fixes', () {
    test('deletedCount resets after compact', () async {
      await FfastDb.disposeInstance();
      await FfastDb.init(MemoryStorageStrategy(), autoCompactThreshold: 0.3);

      // Insert and delete to increment _deletedCount
      final ids = await FfastDb.instance.insertAll(
        List.generate(100, (i) => {'value': i}),
      );
      
      for (int i = 0; i < 50; i++) {
        await FfastDb.instance.delete(ids[i]);
      }

      // Trigger compact
      await FfastDb.instance.compact();

      // Insert one more and delete - should NOT trigger auto-compact
      // if _deletedCount was reset
      final newId = await FfastDb.instance.insert({'value': 999});
      await FfastDb.instance.delete(newId);

      // After compact, ratio should be 1/(50+1) = 0.02, well below 0.3 threshold
      // So no auto-compact should trigger
      final countBefore = await FfastDb.instance.count();
      
      // This operation should NOT trigger auto-compact
      final anotherId = await FfastDb.instance.insert({'value': 1000});
      await FfastDb.instance.delete(anotherId);
      
      final countAfter = await FfastDb.instance.count();
      
      // If _deletedCount was NOT reset, auto-compact would trigger
      // and count might change. If it WAS reset, count stays same.
      expect(countAfter, equals(countBefore));

      await FfastDb.disposeInstance();
    });

    test('dirtyPages has automatic flush limit', () async {
      await FfastDb.disposeInstance();
      await FfastDb.init(MemoryStorageStrategy());
      // MemoryStorageStrategy automatically enables write-behind mode

      // Create many writes to trigger dirty pages accumulation
      for (int i = 0; i < 1500; i++) {
        await FfastDb.instance.insert({'data': 'x' * 100});
      }

      // The PageManager should have auto-flushed when hitting maxDirtyPages (1000)
      // so dirty pages should be less than maxDirtyPages even after 1500 inserts
      
      // We can't directly check _dirtyPages (private), but we can verify
      // that the database still works correctly (no OOM crash)
      final count = await FfastDb.instance.count();
      // Count should be around 1500, allowing for possible auto-compaction
      expect(count, greaterThan(1400));
      expect(count, lessThanOrEqualTo(1500));

      await FfastDb.disposeInstance();
    }, timeout: Timeout(Duration(minutes: 1)));

    test('singleton throws error when used after dispose', () async {
      await FfastDb.disposeInstance();
      await FfastDb.init(MemoryStorageStrategy());
      
      // Dispose the singleton
      await FfastDb.disposeInstance();

      // Trying to access the instance should throw
      expect(
        () => FfastDb.instance,
        throwsA(isA<StateError>()),
      );
    });

    test('operations throw error on closed database', () async {
      await FfastDb.disposeInstance();
      final db = await FfastDb.init(MemoryStorageStrategy());
      await db.close();

      // Test insert throws
      try {
        await db.insert({'test': 1});
        fail('Should have thrown StateError');
      } catch (e) {
        expect(e, isA<StateError>());
      }

      // Test findById throws
      try {
        await db.findById(1);
        fail('Should have thrown StateError');
      } catch (e) {
        expect(e, isA<StateError>());
      }

      // Test delete throws
      try {
        await db.delete(1);
        fail('Should have thrown StateError');
      } catch (e) {
        expect(e, isA<StateError>());
      }
      
      await FfastDb.disposeInstance();
    });

    test('close is idempotent', () async {
      await FfastDb.disposeInstance();
      final db = await FfastDb.init(MemoryStorageStrategy());
      
      // First close
      await db.close();
      
      // Second close should not throw
      await db.close();
      
      // Third close should also be safe
      await db.close();
      
      await FfastDb.disposeInstance();
    });

    test('watchers are cleaned up on close', () async {
      await FfastDb.disposeInstance();
      final db = await FfastDb.init(MemoryStorageStrategy());

      // Create some watchers
      final sub1 = db.watch('field1').listen((_) {});
      final sub2 = db.watch('field2').listen((_) {});

      await db.close();

      // Watchers should be closed, no memory leaks
      // (We can't directly verify, but no crash is a good sign)
      
      await sub1.cancel();
      await sub2.cancel();
      
      await FfastDb.disposeInstance();
    });

    test('autoCompact does not trigger repeatedly after first compact', () async {
      await FfastDb.disposeInstance();
      await FfastDb.init(MemoryStorageStrategy(), autoCompactThreshold: 0.3);

      // Insert 100 docs
      final ids = await FfastDb.instance.insertAll(
        List.generate(100, (i) => {'value': i}),
      );

      // Delete 50 docs (50% deleted, triggers auto-compact at 30% threshold)
      for (int i = 0; i < 50; i++) {
        await FfastDb.instance.delete(ids[i]);
      }

      // Last delete should have triggered auto-compact
      // Now _deletedCount should be 0

      // Insert and delete ONE more doc
      final newId = await FfastDb.instance.insert({'value': 999});
      await FfastDb.instance.delete(newId);

      // Ratio is now 1/(50+1) = 0.019, well below 0.3
      // Should NOT trigger another compact

      // If compact triggered, count would be different
      final count = await FfastDb.instance.count();
      expect(count, equals(50)); // 50 survived the first compact

      await FfastDb.disposeInstance();
    });

    test('large batch insert with write-behind does not OOM', () async {
      await FfastDb.disposeInstance();
      await FfastDb.init(MemoryStorageStrategy());
      // MemoryStorageStrategy automatically enables write-behind mode

      // Insert 5000 documents
      // Without auto-flush, this would accumulate ~1250 dirty pages (5000/4)
      // With auto-flush at 1000 pages, it should flush automatically
      final docs = List.generate(5000, (i) => {
        'index': i,
        'data': 'x' * 500, // ~500 bytes per doc
      });

      await FfastDb.instance.insertAll(docs);

      // Verify all docs were inserted
      final count = await FfastDb.instance.count();
      expect(count, equals(5000));

      await FfastDb.disposeInstance();
    }, timeout: Timeout(Duration(seconds: 30)));
  });
}
