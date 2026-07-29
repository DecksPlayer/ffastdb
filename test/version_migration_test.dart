@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

/// Cross-version migration test: a database file written by the PREVIOUS
/// package version (the committed code in git HEAD) must open and behave
/// correctly under the CURRENT code.
///
/// This mirrors what happens when an app updates the ffastdb dependency:
/// end users already have `.fdb` files on disk written by the old version.
///
/// How it works:
///  1. `git archive HEAD` → extract → `dart pub get` (read-only for this repo)
///  2. A generator script compiled against THAT source writes a database
///     with documents of every supported type (including Uint8List payloads,
///     which the old serializer stored as JSON int arrays)
///  3. The current code opens the frozen files and runs an integrity suite
const _generatorSource = r'''
import 'dart:io';
import 'dart:typed_data';
import 'package:ffastdb/ffastdb.dart';

Future<void> main(List<String> args) async {
  final dir = args[0];
  final db = await openDatabase(
    'legacy',
    directory: dir,
    version: 1,
    indexes: ['status'],
    sortedIndexes: ['n'],
  );

  final docs = List.generate(500, (i) => {
        'n': i,
        'status': i.isEven ? 'even' : 'odd',
        'name': 'user-$i',
        'created': DateTime.utc(2024, 1, 1).add(Duration(minutes: i)),
        'payload': Uint8List.fromList(List.generate(256, (j) => (i + j) & 0xFF)),
        'tags': ['t${i % 5}', 'common'],
        'score': i * 1.5,
        'active': i % 3 != 0,
        'note': i % 10 == 0 ? null : 'note-$i',
      });
  await db.insertAll(docs);
  await db.close();
  stdout.writeln('DONE');
  await stdout.flush();
}
''';

void main() {
  test('opens a database written by the previous package version', () async {
    final tmp = Directory.systemTemp.createTempSync('ffastdb_vermig_');
    final oldSrc = Directory('${tmp.path}/old_src')..createSync();
    final dbDir = Directory('${tmp.path}/db')..createSync();
    try {
      // ── 1. Freeze the previous version's source code ──
      final zip = File('${tmp.path}/head.zip');
      var r = await Process.run('git',
          ['archive', '--format=zip', '--output=${zip.path}', 'HEAD']);
      expect(r.exitCode, 0, reason: 'git archive failed: ${r.stderr}');

      r = await Process.run('tar', ['-xf', zip.path, '-C', oldSrc.path]);
      expect(r.exitCode, 0, reason: 'tar extract failed: ${r.stderr}');

      r = await Process.run(Platform.resolvedExecutable, ['pub', 'get'],
          workingDirectory: oldSrc.path);
      expect(r.exitCode, 0,
          reason: 'pub get failed: ${r.stdout}\n${r.stderr}');

      // ── 2. Generate the legacy database with the OLD code ──
      final gen = File('${oldSrc.path}/gen_legacy_db.dart');
      await gen.writeAsString(_generatorSource);
      r = await Process.run(Platform.resolvedExecutable, [gen.path, dbDir.path],
          workingDirectory: oldSrc.path);
      expect(r.exitCode, 0,
          reason: 'generator failed: ${r.stdout}\n${r.stderr}');
      expect(r.stdout, contains('DONE'));

      // ── 3. Open with CURRENT code — integrity suite ──
      final db = await openDatabase(
        'legacy',
        directory: dbDir.path,
        version: 1,
        indexes: ['status'],
        sortedIndexes: ['n'],
      );

      final all = await db.getAll();
      expect(all.length, 500);

      final seen = <int>{};
      for (final doc in all) {
        final n = doc['n'] as int;
        expect(seen.add(n), isTrue);
        expect(doc['status'], n.isEven ? 'even' : 'odd');
        expect(doc['name'], 'user-$n');
        expect(doc['created'], isA<DateTime>(),
            reason: 'DateTime must survive the version jump');
        expect(doc['score'], n * 1.5);
        expect(doc['active'], n % 3 != 0);
        expect(doc['tags'], contains('common'));
        if (n % 10 == 0) {
          expect(doc['note'], isNull);
        } else {
          expect(doc['note'], 'note-$n');
        }

        // BACKWARD COMPAT: the old serializer stored Uint8List as a JSON
        // int array. The new code must still read those bytes correctly —
        // as a List with identical content (new writes use the blob format).
        final payload = doc['payload'];
        expect(payload, isA<List<dynamic>>(),
            reason: 'legacy blob for n=$n should read back as List');
        final bytes = (payload as List).cast<int>();
        expect(bytes.length, 256);
        for (var j = 0; j < 256; j++) {
          expect(bytes[j], (n + j) & 0xFF,
              reason: 'legacy blob corrupted at byte $j (n=$n)');
        }
      }

      // Indexes loaded/rebuilt from the old file must answer queries.
      final even =
          (await db.query().where('status').equals('even').find()).length;
      final odd =
          (await db.query().where('status').equals('odd').find()).length;
      expect(even + odd, 500);
      expect((await db.query().where('n').between(-1, 1 << 62).find()).length,
          500);

      // The old file must keep accepting writes under the new code —
      // including new-format blobs.
      final newId = await db.insert({
        'n': 9999,
        'status': 'odd',
        'payload': Uint8List.fromList([1, 2, 3, 4]),
      });
      final newDoc = await db.findById(newId);
      expect(newDoc['payload'], isA<Uint8List>(),
          reason: 'new writes must use the blob format');

      await db.close();

      // ── 4. Reopen once more: everything persists across the upgrade ──
      final db2 = await openDatabase(
        'legacy',
        directory: dbDir.path,
        version: 1,
        indexes: ['status'],
        sortedIndexes: ['n'],
      );
      expect(await db2.count(), 501);
      expect((await db2.findById(newId))['payload'], isA<Uint8List>());
      await db2.close();
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
