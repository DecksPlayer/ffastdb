# Mobile Lifecycle — Manual Durability Checklist

Physical tests that cannot be fully automated in CI. Run them on **real
devices** (not only emulators) before each release that touches storage,
WAL, compact, or migrations.

Automated equivalents already in the suite: `kill_recovery_test.dart`
(SIGKILL mid-write for insert / batch / update / compact / reindex / blob /
encrypted), `kill_migration_test.dart`, `enospc_test.dart`. The manual
scenarios below cover platform behaviors those cannot reach.

---

## 1. iOS — suspension & jetsam (system kill)

iOS does not let apps clean up when the system reclaims them, but a
suspended app may be killed at an arbitrary later moment.

1. Open the app, start a heavy write loop (e.g. import 10k documents).
2. Mid-import, press Home (app goes to background/suspended).
3. Open several heavy apps to force memory pressure until jetsam kills
   the suspended app (or leave it suspended overnight).
4. Relaunch.
   - **Expected:** database opens without errors; document count and index
     queries are consistent; no migration/compact is applied twice.

Note: SIGKILL on desktop is a good proxy for jetsam — neither runs Dart
cleanup — so `kill_recovery_test.dart` covers the core risk. What it does
NOT cover: iOS's ~5 s of background time where writes may partially
complete while the OS holds the process. Verify no ANR/hang on relaunch.

## 2. iOS — app terminated by user (swipe up)

1. Start the same write loop.
2. Swipe up to kill the app mid-write.
3. Relaunch — same expectations as above.

## 3. Android — force stop

1. Start the write loop.
2. Settings → Apps → [app] → **Force stop** (kills the process, no cleanup).
3. Relaunch — same expectations.

## 4. Android — low storage behavior

1. Fill the device until "low storage" warnings appear (< 500 MB free).
2. Run the write loop until writes start failing.
   - **Expected:** the write failure surfaces as an exception in app code
     (never silent corruption); on relaunch after freeing space, the
     database is consistent (`enospc_test.dart` is the automated proxy).
3. While still low on space, trigger `compact()` and let it fail.
   - **Expected:** all pre-existing documents intact after relaunch.

## 5. Android — system "cleaner" / scoped storage

Some OEM cleaners delete app files they consider junk.

1. Run a third-party/OEM storage cleaner while the app is closed.
2. Relaunch.
   - **Expected:** if only cache files were touched, the DB opens normally.
     If `.fdb`/`.wal`/`.log` were deleted by the cleaner, the app must treat
     it as a fresh database — never crash on open.

## 6. Both — app update with data (the fcacl path)

1. Install the PREVIOUS release from the store; create real data.
2. Update to the new build (same signing key) without uninstalling.
3. First launch runs any schema migrations — kill the app MID-migration
   (quickly, e.g. during the first seconds).
4. Relaunch.
   - **Expected:** migration completes exactly once per document
     (`kill_migration_test.dart` is the automated proxy).

## 7. Both — battery pull during compact

1. Trigger `compact()` on a large database.
2. Mid-compact, remove battery / hard power-off (or `adb shell reboot`).
3. Reboot and relaunch.
   - **Expected:** database opens; all documents present (pre- or
     post-compact state, never partial).

---

Record results per release in the PR/release notes (device, OS version,
scenario, pass/fail, observations).
