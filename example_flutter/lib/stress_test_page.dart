import 'dart:math';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:ffastdb/ffastdb.dart';
import 'package:path_provider/path_provider.dart';
// Internal imports for diagnostics
import 'package:ffastdb/src/index/hash_index.dart';
import 'package:ffastdb/src/index/sorted_index.dart';
import 'package:ffastdb/src/index/fts_index.dart';
import 'package:ffastdb/src/index/bitmask_index.dart';
import 'package:ffastdb/src/index/composite_index.dart';

/// Top-level function for background isolate / worker post synthesis.
List<Map<String, dynamic>> _generatePostsBatch(Map<String, dynamic> params) {
  final int count = params['count'] as int;
  final List<int> userIds = List<int>.from(params['userIds'] as List);
  final List<String> phrases = List<String>.from(params['phrases'] as List);
  final int seed = params['seed'] as int;

  final random = Random(seed);
  final batchPosts = <Map<String, dynamic>>[];
  final nowMs = DateTime.now().millisecondsSinceEpoch;

  for (int i = 0; i < count; i++) {
    final uId = userIds[random.nextInt(userIds.length)];
    final phrase = phrases[random.nextInt(phrases.length)];
    batchPosts.add({
      'type': 'post',
      'userId': uId,
      'content': phrase,
      'likes': random.nextInt(500),
      'timestamp': nowMs - random.nextInt(100 * 3600 * 1000),
    });
  }
  return batchPosts;
}

/// Top-level function for background isolate / worker duplicate analysis.
Map<String, int> _countPhrasesInBackground(List<String> contents) {
  final counts = <String, int>{};
  for (final content in contents) {
    counts[content] = (counts[content] ?? 0) + 1;
  }
  return counts;
}

class QueryCondition {
  String field;
  String operator;
  String value;
  QueryCondition({
    required this.field,
    required this.operator,
    required this.value,
  });
}

class StressTestPage extends StatefulWidget {
  final FastDB db;
  const StressTestPage({super.key, required this.db});

  @override
  State<StressTestPage> createState() => _StressTestPageState();
}

class _StressTestPageState extends State<StressTestPage> {
  final List<String> _logs = [];
  bool _running = false;
  double _progress = 0;
  int _totalDocs = 0;

  // Results from searches
  List<dynamic> _searchResults = [];
  bool _isStreamingAll = false;

  // Dynamic Query Builder
  final List<QueryCondition> _conditions = [
    QueryCondition(field: 'type', operator: 'equals', value: 'post'),
  ];

  // Search Controls
  final TextEditingController _searchController = TextEditingController();
  String _selectedType = 'all';
  double _minLikes = 0;
  bool _onlyFeatured = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _log(String msg) {
    // Millisecond-resolution timestamp — with only whole seconds you can't
    // tell a 200ms step from a 900ms one just by reading two log lines.
    final ts = DateTime.now().toString().split(' ').last.substring(0, 12);
    // debugPrint (not dart:developer's log()) — log() only shows in
    // DevTools' Logging view, never in the plain `flutter run` / IDE debug
    // console. debugPrint shows in both, and also throttles output so a
    // burst of lines (like this loop) doesn't get silently dropped by the
    // Android/iOS log pipe the way a raw print() can.
    debugPrint('[ffastdb.stress] $msg');
    setState(() {
      _logs.insert(0, '$ts - $msg');
    });
  }

  @override
  void initState() {
    super.initState();
    _refreshCount();
    // Auto-load if empty
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final count = await widget.db.count();
      if (count == 0) {
        _setupComplexDB();
      } else {
        // Note: on every restart AFTER the first successful seed, this is
        // the ONLY branch that runs — _setupComplexDB() (and all its
        // per-step timing logs) does NOT run again, since it only seeds
        // when the DB is empty. If you're not seeing step-by-step logs on
        // hot restart, this is why: there's nothing left to seed. What you
        // WILL always see, on every restart, are the "[ffastdb] openDatabase"
        // lines printed from main() — that's the thing to watch for timing.
        _log('ℹ️ Database already contains $count documents (not re-seeding).');
      }
    });
  }

  Future<void> _refreshCount() async {
    final count = await widget.db.count();
    setState(() => _totalDocs = count);
  }

  Future<void> _setupComplexDB({bool useIsolates = false}) async {
    if (_running) return;
    setState(() {
      _running = true;
      _progress = 0;
      _logs.clear();
      _searchResults.clear();
    });

    // Per-step timing: which of these phases is actually slow — the
    // deleteWhere() wipe, the posts insertAll loop, or something after it —
    // instead of just knowing the whole thing took a while.
    final totalSw = Stopwatch()..start();
    final stepSw = Stopwatch()..start();
    void logStep(String msg) {
      _log('$msg (${stepSw.elapsedMilliseconds}ms)');
      stepSw.reset();
    }

    try {
      final modeStr = useIsolates
          ? (kIsWeb ? 'Web Worker (compute)' : 'Background Isolate')
          : 'Main Thread';
      _log('🚀 Wiping and rebuilding Complex DB using [$modeStr]...');
      // Clear existing data to ensure a clean state for the new indexes
      await widget.db.deleteWhere((q) => q.rangeSearch(1, 0x7FFFFFFF));
      logStep('🗑️ Wipe done');

      final random = Random();

      // 1. Indexes are now globally registered in main.dart

      // 2. Create Users
      _log('👤 Creating 1000 users...');
      final usersToInsert = <Map<String, dynamic>>[];
      for (int i = 0; i < 1000; i++) {
        usersToInsert.add({
          'type': 'user',
          'name': 'User $i',
          'email': 'user_$i@example.com',
          'followers': random.nextInt(1000),
          'joinedAt': DateTime.now()
              .subtract(Duration(days: random.nextInt(365)))
              .millisecondsSinceEpoch,
        });
      }
      final userIds = await widget.db.insertAll(usersToInsert);
      logStep('👤 Users insertAll done');

      final basePhrases = [
        "Exploring the hidden gems of the city.",
        "Coding is like magic but with logic.",
        "The sun sets beautifully over the horizon.",
        "Fresh coffee is the best way to start the day.",
        "Learning a new language opens up the world.",
        "Music has a way of healing the soul.",
        "Photography captures moments that are gone forever.",
        "Traveling helps you find yourself.",
        "Cooking is an art, baking is a science.",
        "The mountains are calling and I must go.",
        "Reading a good book is like a dream you can hold.",
        "Kindness costs nothing but means everything.",
        "Digital databases are the backbone of modern tech.",
        "FastDB is becoming really stable now.",
        "A simple smile can change someone's day.",
        "The ocean waves are incredibly soothing.",
        "Technology is best when it brings people together.",
        "Nature never goes out of style.",
        "Strive for progress, not perfection.",
        "Innovation distinguishes between a leader and a follower.",
        "Stay curious and keep learning.",
        "The best time to plant a tree was 20 years ago.",
        "Dream big and dare to fail.",
        "Focus on the journey, not the destination.",
        "Every day is a second chance.",
        "Believe you can and you're halfway there.",
        "Good things take time.",
        "Happiness depends upon ourselves.",
        "Life is short, make it sweet.",
        "Simplicity is the ultimate sophistication.",
        "Adventure awaits around every corner.",
        "Autumn leaves are falling like pieces into place.",
        "Winter is coming, stay warm.",
        "Spring brings new beginnings.",
        "Summer nights are made for memories.",
        "Quiet the mind and the soul will speak.",
        "Work hard in silence, let success be your noise.",
        "Be the change you wish to see.",
        "Don't count the days, make the days count.",
        "Everything you can imagine is real.",
        "Impossible is just an opinion.",
        "Keep your head in the clouds and feet on the ground.",
        "Make today amazing.",
        "Never stop dreaming.",
        "Nothing is impossible.",
        "Opportunities don't happen, you create them.",
        "Quality is not an act, it is a habit.",
        "Success is a journey, not a destination.",
        "The power of imagination makes us infinite.",
        "Wait for the right moment, but don't wait forever.",
        "Your only limit is your mind.",
        "Do what you love, love what you do.",
        "Eat well, travel often.",
        "Follow your heart.",
        "Get outside and enjoy the fresh air.",
        "Live every moment.",
        "Love more, worry less.",
        "Positive vibes only.",
        "Think outside the box.",
        "Write your own story.",
        "Be yourself.",
        "Choose joy.",
        "Create your own sunshine.",
        "Do more of what makes you happy.",
        "Enjoy the little things.",
        "Happy days are here again.",
        "Life is beautiful.",
        "Make it happen.",
        "Stay humble, work hard.",
        "Today is a gift.",
        "Wherever you go, go with all your heart.",
        "Your vibe attracts your tribe.",
        "Art is the stored honey of the human soul.",
        "Be brave, be bold.",
        "Collect moments, not things.",
        "Doubt kills more dreams than failure ever will.",
        "Fear is a liar.",
        "Give every day the chance to be the most beautiful.",
        "He who has a why to live can bear almost any how.",
        "I am the master of my fate.",
        "Knowledge is power.",
        "Lead from the heart.",
        "No pressure, no diamonds.",
        "One day or day one. You decide.",
        "Peace begins with a smile.",
        "Realize deeply that the present moment is all you have.",
        "Say yes to new adventures.",
        "The future depends on what you do today.",
        "Unity is strength.",
        "Victory is sweetest when you've known defeat.",
        "Wake up and be awesome.",
        "Yesterday's home runs don't win today's games.",
        "Zeal is the fire of the soul.",
        "A goal without a plan is just a wish.",
        "Be kind to yourself.",
        "Create something every day.",
        "Don't let yesterday take up too much of today.",
        "Every moment is a fresh beginning.",
        "Follow your dreams.",
        "Go for it.",
      ];

      final subjects = [
        'The cat',
        'A developer',
        'My friend',
        'The robot',
        'An alien',
        'The database',
        'A ninja',
        'The superhero',
        'A dinosaur',
        'The chef',
        'A hacker',
        'The wizard',
        'An astronaut',
        'The detective',
        'A pirate',
      ];
      final verbs = [
        'jumps over',
        'debugs',
        'loves',
        'destroys',
        'creates',
        'analyzes',
        'hides from',
        'fights',
        'eats',
        'cooks',
        'hacks',
        'enchants',
        'explores',
        'investigates',
        'steals',
      ];
      final objects = [
        'the lazy dog',
        'the complex code',
        'a pizza',
        'the whole system',
        'a beautiful artwork',
        'the big data',
        'the shadows',
        'the evil villain',
        'a giant asteroid',
        'a tasty meal',
        'the mainframe',
        'a magical potion',
        'the galaxy',
        'a mysterious clue',
        'the hidden treasure',
      ];

      final phrases = List.generate(400, (i) {
        if (i < basePhrases.length) return basePhrases[i];
        return '${subjects[random.nextInt(subjects.length)]} ${verbs[random.nextInt(verbs.length)]} ${objects[random.nextInt(objects.length)]}.';
      });

      _log('📝 Creating 98000 posts with 400 possible phrases...');
      final postIds = <int>[];
      const totalPosts = 98000;
      const batchSize = 10000;
      
      for (int start = 0; start < totalPosts; start += batchSize) {
        final end = min(start + batchSize, totalPosts);
        final count = end - start;

        List<Map<String, dynamic>> batchPosts;
        if (useIsolates) {
          final mode = kIsWeb ? 'Web Worker (compute)' : 'Isolate';
          _log('   🧵 [$mode] Synthesizing ${start + 1}..$end in background...');
          batchPosts = await compute(_generatePostsBatch, {
            'count': count,
            'userIds': userIds,
            'phrases': phrases,
            'seed': random.nextInt(1000000),
          });
        } else {
          batchPosts = <Map<String, dynamic>>[];
          for (int i = start; i < end; i++) {
            final uId = userIds[random.nextInt(userIds.length)];
            final phrase = phrases[random.nextInt(phrases.length)];
            batchPosts.add({
              'type': 'post',
              'userId': uId,
              'content': phrase,
              'likes': random.nextInt(500),
              'timestamp': DateTime.now()
                  .subtract(Duration(hours: random.nextInt(100)))
                  .millisecondsSinceEpoch,
            });
          }
        }
        // Splits synthesis (CPU, building the Dart maps) from insertAll
        // (the DB write) — if ONE of these two is what's slow, this tells
        // you which, instead of a single number covering both.
        logStep('   🧪 Synthesized ${start + 1}..$end');

        _log('   💾 Inserting posts ${start + 1} to $end into FastDB...');
        final ids = await widget.db.insertAll(batchPosts);
        postIds.addAll(ids);
        logStep('   💾 insertAll ${start + 1}..$end done');
        setState(() => _progress = 0.1 + (end / totalPosts) * 0.7); // Progress from 0.1 to 0.8
        await Future.delayed(Duration.zero);
      }

      // 4. Create Comments
      _log('💬 Creating 1000 comments...');
      final commentsToInsert = <Map<String, dynamic>>[];
      for (int i = 0; i < 1000; i++) {
        final pId = postIds[random.nextInt(postIds.length)];
        final uId = userIds[random.nextInt(userIds.length)];
        commentsToInsert.add({
          'type': 'comment',
          'postId': pId,
          'userId': uId,
          'text': 'Comment #$i on post $pId',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        if (i % 250 == 0) setState(() => _progress = 0.8 + (i / 1000 * 0.15));
      }
      await widget.db.insertAll(commentsToInsert);
      logStep('💬 Comments insertAll done');
      setState(() => _progress = 0.95);

      _log('✨ Complex DB Loaded Successfully! Total: ${totalSw.elapsedMilliseconds}ms');
      _log('📊 Post-Load Diagnostics:');
      for (final entry in widget.db.indexes.all.entries) {
        _log('   Index [${entry.key}]: size=${entry.value.size}');
      }

      _refreshCount();
    } catch (e) {
      _log('❌ ERROR: $e');
    } finally {
      setState(() {
        _running = false;
        _progress = 1.0;
      });
    }
  }

  Future<void> _testSearches() async {
    _log('🔍 Running Relationship Queries...');

    // 1. Find all posts from a specific user
    final user5Posts = await widget.db
        .query()
        .where('type')
        .equals('post')
        .where('userId')
        .equals(5) // Assuming ID 5 is a user
        .find();
    _log('   Found ${user5Posts.length} posts for User ID 5');

    // 2. Find popular posts (>400 likes) containing "apple"
    final popularApplePosts = await widget.db
        .query()
        .where('type')
        .equals('post')
        .where('likes')
        .greaterThan(400)
        .where('content')
        .fts('apple')
        .find();
    _log('   Found ${popularApplePosts.length} popular posts matching "apple"');

    setState(() {
      _searchResults = popularApplePosts;
      _isStreamingAll = false;
    });
  }

  Future<void> _runDynamicQuery() async {
    _log('🏗️ Building and running dynamic query...');
    setState(() => _running = true);
    try {
      final results = await widget.db.find((q) {
        if (_conditions.isEmpty) return Future.value(<int>[]);

        // Start with the first condition
        final first = _conditions.first;
        var builder = _applyOperator(
          q.where(first.field),
          first.operator,
          first.value,
        );

        // Chain the rest with AND
        for (int i = 1; i < _conditions.length; i++) {
          final cond = _conditions[i];
          builder = _applyOperator(
            builder.and(cond.field),
            cond.operator,
            cond.value,
          );
        }

        return builder.findIds();
      });

      _log('   Found ${results.length} matches.');
      setState(() {
        _searchResults = results;
        _isStreamingAll = false;
      });
    } catch (e) {
      _log('❌ Query Error: $e');
    } finally {
      setState(() => _running = false);
    }
  }

  QueryBuilder _applyOperator(FieldCondition condition, String op, String val) {
    switch (op) {
      case 'equals':
        return condition.equals(_parseValue(val));
      case 'notEquals':
        return condition.not().equals(_parseValue(val));
      case 'greaterThan':
        return condition.greaterThan(int.tryParse(val) ?? 0);
      case 'lessThan':
        return condition.lessThan(int.tryParse(val) ?? 0);
      case 'contains':
        return condition.contains(val);
      case 'startsWith':
        return condition.startsWith(val);
      case 'fts':
        return condition.fts(val);
      case 'isNotNull':
        return condition.isNotNull();
      default:
        return condition.isNotNull();
    }
  }

  dynamic _parseValue(String val) {
    if (val == 'true') return true;
    if (val == 'false') return false;
    final n = num.tryParse(val);
    if (n != null) return n;
    return val;
  }


  void _showStats() {
    _log('📊 DATABASE STATUS:');
    _log('   Total Documents: $_totalDocs');
    _log('   Active Indexes: ${widget.db.indexes.all.length}');
    for (final entry in widget.db.indexes.all.entries) {
      final idx = entry.value;
      String type = 'UNKNOWN';
      if (idx is FtsIndex)
        type = 'FTS';
      else if (idx is HashIndex)
        type = 'HASH';
      else if (idx is SortedIndex)
        type = 'SORT';
      else if (idx is BitmaskIndex)
        type = 'MASK';
      else if (idx is CompositeIndex)
        type = 'COMP';

      _log('   [$type] ${entry.key}: size=${idx.size}');
      if (idx is FtsIndex) {
        _log('     -> ${idx.stats()}');
      }
    }
  }

  Future<void> _checkDuplicates({bool useIsolate = true}) async {
    final modeStr = useIsolate
        ? (kIsWeb ? 'Web Worker (compute)' : 'Background Isolate')
        : 'Main Thread';
    _log('🔍 Checking for repeated posts using [$modeStr]...');
    setState(() => _running = true);
    try {
      final posts = await widget.db.query().where('type').equals('post').find();
      final contents = posts.map((p) => p['content']?.toString() ?? '').toList();

      final Map<String, int> counts;
      if (useIsolate) {
        counts = await compute(_countPhrasesInBackground, contents);
      } else {
        counts = _countPhrasesInBackground(contents);
      }

      final duplicates = counts.entries.where((e) => e.value > 1).toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      _log('✅ Found ${duplicates.length} phrases that repeat.');
      for (int i = 0; i < min(5, duplicates.length); i++) {
        _log('   "${duplicates[i].key}" -> ${duplicates[i].value} times');
      }

      // Show them in the search results
      if (duplicates.isNotEmpty) {
        final mostRepeated = duplicates.first.key;
        final matchingIds = await widget.db.find(
          (q) => q.where('content').equals(mostRepeated).findIds(),
        );
        setState(() {
          _searchResults = matchingIds;
          _isStreamingAll = false;
        });
      }
    } catch (e) {
      _log('❌ Error checking duplicates: $e');
    } finally {
      setState(() => _running = false);
    }
  }

  Future<void> _searchAll() async {
    _log('📡 Toggling Streaming for all documents...');
    setState(() => _isStreamingAll = true);
  }

  Future<void> _evolveSchema() async {
    _log('🧬 Evolving Schema: Adding "isFeatured" field to all posts...');
    setState(() => _running = true);

    try {
      final updated = await widget.db.updateWhere(
        (q) => q.where('type').equals('post').findIds(),
        {'isFeatured': true, 'v': 2}, // Adding new fields!
      );
      _log('✅ Updated $updated posts with new fields.');

      // Verify one
      final sample = await widget.db
          .query()
          .where('type')
          .equals('post')
          .findFirst();
      _log(
        '   Sample post after evolution: ${sample?['isFeatured'] == true ? "HAS isFeatured" : "MISSING"}',
      );
    } catch (e) {
      _log('❌ ERROR: $e');
    } finally {
      setState(() => _running = false);
    }
  }

  Future<void> _manualInsert() async {
    final controller = TextEditingController(
      text: '{"type": "custom", "name": "Test", "data": {"key": "value"}}',
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Insert Custom JSON'),
        content: TextField(
          controller: controller,
          maxLines: 5,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Insert'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final data = jsonDecode(controller.text);
        final id = await widget.db.insert(data);
        _log('✅ Manually inserted ID $id with custom schema.');
        _refreshCount();
      } catch (e) {
        _log('❌ Invalid JSON or Error: $e');
      }
    }
  }

  Future<void> _factoryReset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Factory Reset'),
        content: const Text(
          'This will COMPLETELY WIPE the database file and RESTART the instance. Use this if the database is corrupted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('WIPE EVERYTHING'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() => _running = true);
      try {
        _log('🧨 Wiping storage strategies...');
        // Truncate to 0
        await widget.db.storage.truncate(0);
        if (widget.db.dataStorage != null)
          await widget.db.dataStorage!.truncate(0);

        _log('♻️ Re-initializing database...');
        await FfastDb.disposeInstance();

        // On web we don't have a path, just a name
        // We can just call openDatabase from main.dart if we had it,
        // but here we can just reload the page or tell the user.
        _log('✅ Database wiped. Please RELOAD the page/app to continue.');

        if (mounted) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (_) => const AlertDialog(
              title: Text('Reset Complete'),
              content: Text(
                'The database has been physically wiped. Please reload the application to start fresh.',
              ),
            ),
          );
        }
      } catch (e) {
        _log('❌ ERROR during reset: $e');
      } finally {
        setState(() => _running = false);
      }
    }
  }

  /// Closes the DB and reopens it, comparing query results before and after
  /// on every index type (Hash, Sorted, FTS, Composite).
  ///
  /// This is the exact round-trip (saveIndexes() at close → loadIndexes() at
  /// open) where FTS and Composite indexes were found coming back silently
  /// EMPTY at scale — no exception, just zero results, which is why it took
  /// a dedicated check like this to catch instead of showing up as a crash.
  /// A "Reload DB" run alone never exercises this: it rebuilds indexes from
  /// documents in memory and never round-trips through the persisted blob.
  ///
  /// WARNING: closes `widget.db`. Every other screen holds its OWN reference
  /// to the same (now stale) instance — there's no live way to hand them a
  /// new one, so this always ends with a "restart the app" prompt, exactly
  /// like Factory Reset above.
  Future<void> _verifyPersistence() async {
    if (_running) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Verificar persistencia'),
        content: const Text(
          'Esto CIERRA la base de datos, la vuelve a abrir, y compara los '
          'resultados de una consulta por cada tipo de índice (Hash, Sorted, '
          'FTS, Composite) antes y después. Vas a necesitar hacer un HOT '
          'RESTART de la app al terminar — las otras pantallas quedan con '
          'una referencia vieja a la base.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Verificar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _running = true);
    final results = <String, bool>{};
    try {
      _log('🔒 Verificando persistencia: tomando snapshot ANTES de cerrar...');

      final beforeCount = await widget.db.count();
      final beforeHash =
          (await widget.db.query().where('type').equals('post').find()).length;
      final beforeSorted =
          (await widget.db.query().where('likes').between(0, 100).find())
              .length;
      final beforeFts =
          (await widget.db.query().where('content').fts('cat').find())
              .length;
      final samplePost =
          await widget.db.query().where('type').equals('post').limit(1).find();
      final sampleUserId =
          samplePost.isNotEmpty ? samplePost.first['userId'] as int? : null;
      final beforeComposite = sampleUserId == null
          ? -1
          : (await widget.db
                  .query()
                  .where('type')
                  .equals('post')
                  .where('userId')
                  .equals(sampleUserId)
                  .find())
              .length;

      _log('   count=$beforeCount hash=$beforeHash sorted=$beforeSorted '
          'fts=$beforeFts composite=$beforeComposite (userId=$sampleUserId)');

      _log('🔒 Cerrando la base de datos...');
      await widget.db.close();

      _log('🔓 Reabriendo...');
      String dir = '';
      if (!kIsWeb) {
        final appDir = await getApplicationDocumentsDirectory();
        dir = appDir.path;
      }
      final reopened = await openDatabase(
        'wordnotes',
        directory: dir,
        version: 1,
        indexes: const ['type', 'userId', 'postId'],
        sortedIndexes: const ['word', 'content', 'likes'],
        ftsIndexes: const ['content'],
        compositeIndexes: const [
          ['type', 'userId'],
        ],
      );

      final afterCount = await reopened.count();
      final afterHash =
          (await reopened.query().where('type').equals('post').find()).length;
      final afterSorted =
          (await reopened.query().where('likes').between(0, 100).find())
              .length;
      final afterFts =
          (await reopened.query().where('content').fts('cat').find()).length;
      final afterComposite = sampleUserId == null
          ? -1
          : (await reopened
                  .query()
                  .where('type')
                  .equals('post')
                  .where('userId')
                  .equals(sampleUserId)
                  .find())
              .length;

      _log('   count=$afterCount hash=$afterHash sorted=$afterSorted '
          'fts=$afterFts composite=$afterComposite');

      results['count (B-Tree)'] = beforeCount == afterCount;
      results['type (Hash)'] = beforeHash == afterHash;
      results['likes (Sorted)'] = beforeSorted == afterSorted;
      results['content (FTS)'] = beforeFts == afterFts;
      results['type+userId (Composite)'] = beforeComposite == afterComposite;

      for (final entry in results.entries) {
        _log('${entry.value ? '✅' : '❌'} ${entry.key}: '
            '${entry.value ? 'coincide' : 'NO COINCIDE — se perdieron datos al recargar'}');
      }

      await reopened.close();
      await FfastDb.disposeInstance();
    } catch (e) {
      _log('❌ ERROR durante la verificación: $e');
      results['exception'] = false;
    } finally {
      setState(() => _running = false);
      final allPassed = results.values.every((v) => v);
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
            title: Text(allPassed ? '✅ Todo coincide' : '❌ Se encontraron diferencias'),
            content: Text(
              '${allPassed ? 'Los 5 chequeos coinciden antes y después de cerrar/reabrir.' : 'Revisá el log — algún índice no sobrevivió el cierre/reapertura.'}'
              '\n\nLa base quedó cerrada. Hacé un HOT RESTART para seguir usando la app.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _massiveUpdate() async {
    _log('⚡ Massive Update: Modifying all posts...');
    setState(() => _running = true);
    try {
      final start = DateTime.now();
      final updated = await widget.db
          .updateWhere((q) => q.where('type').equals('post').findIds(), {
            'massivelyUpdated': true,
            'lastUpdateTs': DateTime.now().millisecondsSinceEpoch,
          });
      final duration = DateTime.now().difference(start).inMilliseconds;
      _log('✅ Updated $updated posts in $duration ms.');
      _refreshCount();
    } catch (e) {
      _log('❌ ERROR: $e');
    } finally {
      setState(() => _running = false);
    }
  }

  Future<void> _massiveDelete() async {
    _log('🗑️ Massive Delete: Deleting all posts...');
    setState(() => _running = true);
    try {
      final start = DateTime.now();
      final deleted = await widget.db.deleteWhere(
        (q) => q.where('type').equals('post').findIds(),
      );
      final duration = DateTime.now().difference(start).inMilliseconds;
      _log('✅ Deleted $deleted posts in $duration ms.');
      _refreshCount();
    } catch (e) {
      _log('❌ ERROR: $e');
    } finally {
      setState(() => _running = false);
    }
  }

  Future<void> _clearAll() async {
    setState(() => _running = true);
    try {
      _log('🗑️ Wiping DB...');
      await widget.db.clear();
      await _refreshCount();
      _log('✅ DB is now completely empty.');
    } catch (e) {
      _log('❌ ERROR: $e');
    } finally {
      setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Complex DB Validator'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refreshCount),
          IconButton(
            icon: const Icon(Icons.warning_amber_rounded),
            onPressed: _factoryReset,
            color: Colors.orange,
            tooltip: 'Factory Reset (Corrupted DB)',
          ),
          IconButton(
            icon: const Icon(Icons.delete_forever),
            onPressed: _clearAll,
            tooltip: 'Clear All Docs',
          ),
        ],
      ),
      body: Column(
        children: [
          if (_running) LinearProgressIndicator(value: _progress),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _StatTile(label: 'Total Docs', value: '$_totalDocs'),
                _StatTile(
                  label: 'Search Results',
                  value: '${_searchResults.length}',
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '🛠️ Dynamic Query Builder',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        TextButton.icon(
                          onPressed: () => setState(
                            () => _conditions.add(
                              QueryCondition(
                                field: 'type',
                                operator: 'equals',
                                value: '',
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.add),
                          label: const Text('Add Condition'),
                        ),
                      ],
                    ),
                    const Divider(),
                    ..._conditions.asMap().entries.map((entry) {
                      final i = entry.key;
                      final cond = entry.value;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Row(
                          children: [
                            if (i > 0)
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 4),
                                child: Text(
                                  'AND',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.blue,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            Expanded(
                              flex: 2,
                              child: DropdownButton<String>(
                                isExpanded: true,
                                value: cond.field,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.black,
                                ),
                                items:
                                    [
                                          'type',
                                          'userId',
                                          'postId',
                                          'likes',
                                          'content',
                                          'isFeatured',
                                          'username',
                                        ]
                                        .map(
                                          (f) => DropdownMenuItem(
                                            value: f,
                                            child: Text(f),
                                          ),
                                        )
                                        .toList(),
                                onChanged: (v) =>
                                    setState(() => cond.field = v!),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              flex: 2,
                              child: DropdownButton<String>(
                                isExpanded: true,
                                value: cond.operator,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.black,
                                ),
                                items:
                                    [
                                          'equals',
                                          'notEquals',
                                          'greaterThan',
                                          'lessThan',
                                          'contains',
                                          'startsWith',
                                          'fts',
                                          'isNotNull',
                                        ]
                                        .map(
                                          (o) => DropdownMenuItem(
                                            value: o,
                                            child: Text(o),
                                          ),
                                        )
                                        .toList(),
                                onChanged: (v) =>
                                    setState(() => cond.operator = v!),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              flex: 3,
                              child: TextField(
                                style: const TextStyle(fontSize: 12),
                                decoration: const InputDecoration(
                                  hintText: 'Value',
                                  isDense: true,
                                ),
                                onChanged: (v) => cond.value = v,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.remove_circle_outline,
                                color: Colors.red,
                                size: 20,
                              ),
                              onPressed: () =>
                                  setState(() => _conditions.removeAt(i)),
                            ),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _running ? null : _runDynamicQuery,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('EXECUTE DYNAMIC QUERY'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue[100],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              children: [
                ActionChip(
                  avatar: const Icon(Icons.auto_awesome, size: 16),
                  label: const Text('Reload DB (Main Thread)'),
                  onPressed: _running ? null : () => _setupComplexDB(useIsolates: false),
                ),
                ActionChip(
                  avatar: const Icon(Icons.memory, size: 16),
                  label: Text(kIsWeb ? 'Reload DB (Web Worker)' : 'Reload DB (Isolate)'),
                  backgroundColor: Colors.blue[100],
                  onPressed: _running ? null : () => _setupComplexDB(useIsolates: true),
                ),
                ActionChip(
                  avatar: const Icon(Icons.search, size: 16),
                  label: const Text('Test Searches'),
                  onPressed: _running ? null : _testSearches,
                ),
                ActionChip(
                  avatar: const Icon(Icons.list, size: 16),
                  label: const Text('Search All'),
                  onPressed: _running ? null : _searchAll,
                ),
                ActionChip(
                  avatar: const Icon(Icons.upgrade, size: 16),
                  label: const Text('Evolve Schema'),
                  onPressed: _running ? null : _evolveSchema,
                ),
                ActionChip(
                  avatar: const Icon(Icons.bar_chart, size: 16),
                  label: const Text('Show Stats'),
                  onPressed: _showStats,
                ),
                ActionChip(
                  avatar: const Icon(Icons.copy, size: 16),
                  label: Text(kIsWeb ? 'Duplicates (Worker)' : 'Duplicates (Isolate)'),
                  onPressed: _running ? null : () => _checkDuplicates(useIsolate: true),
                ),
                ActionChip(
                  avatar: const Icon(Icons.add_circle_outline, size: 16),
                  label: const Text('Manual Insert'),
                  onPressed: _running ? null : _manualInsert,
                ),
                ActionChip(
                  avatar: const Icon(Icons.flash_on, size: 16),
                  label: const Text('Massive Update'),
                  onPressed: _running ? null : _massiveUpdate,
                  backgroundColor: Colors.yellow[200],
                ),
                ActionChip(
                  avatar: const Icon(Icons.delete_sweep, size: 16),
                  label: const Text('Massive Delete'),
                  onPressed: _running ? null : _massiveDelete,
                  backgroundColor: Colors.red[200],
                ),
                ActionChip(
                  avatar: const Icon(Icons.published_with_changes, size: 16),
                  label: const Text('Verificar persistencia'),
                  onPressed: _running ? null : _verifyPersistence,
                  backgroundColor: Colors.purple[100],
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: Row(
              children: [
                // Logs side
                Expanded(
                  flex: 1,
                  child: Container(
                    color: Colors.grey[900],
                    child: ListView.builder(
                      itemCount: _logs.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        child: Text(
                          _logs[i],
                          style: const TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 10,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Results side
                Expanded(
                  flex: 1,
                  child: _isStreamingAll
                      ? StreamBuilder<List<dynamic>>(
                          stream: widget.db
                              .watch('type')
                              .asyncMap((_) => widget.db.getAll()),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData)
                              return const Center(
                                child: CircularProgressIndicator(),
                              );
                            final docs = snapshot.data!;
                            return ListView.builder(
                              prototypeItem: _buildResultItem({
                                'type': 'post',
                                'id': 0,
                                'content': 'A',
                                'likes': 0,
                                'isFeatured': false,
                              }),
                              itemCount: docs.length,
                              itemBuilder: (_, i) => _buildResultItem(docs[i]),
                            );
                          },
                        )
                      : ListView.builder(
                          prototypeItem: _buildResultItem({
                            'type': 'post',
                            'id': 0,
                            'content': 'A',
                            'likes': 0,
                            'isFeatured': false,
                          }),
                          itemCount: _searchResults.length,
                          itemBuilder: (_, i) =>
                              _buildResultItem(_searchResults[i]),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultItem(dynamic item) {
    if (item == null) return const SizedBox.shrink();
    final type = item['type']?.toString().toUpperCase() ?? 'UNK';

    String title = 'No content';
    String subtitle = '';
    Color color = Colors.grey;

    if (item['type'] == 'user') {
      title = item['name']?.toString() ?? 'Unknown User';
      subtitle = item['email']?.toString() ?? '';
      color = Colors.blue;
    } else if (item['type'] == 'post') {
      title = item['content']?.toString() ?? 'Empty Post';
      subtitle = 'Likes: ${item['likes']} | Featured: ${item['isFeatured']}';
      color = Colors.green;
    } else if (item['type'] == 'comment') {
      title = (item['text'] ?? item['content'])?.toString() ?? 'Empty Comment';
      subtitle = 'On Post: ${item['postId']}';
      color = Colors.orange;
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: ListTile(
        dense: true,
        leading: CircleAvatar(
          radius: 12,
          backgroundColor: color.withAlpha(50),
          child: Text(
            type.isNotEmpty ? type[0] : '?',
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        title: Text(
          title,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 9)),
        trailing: Text(
          '#${item['id']}',
          style: const TextStyle(fontSize: 8, color: Colors.grey),
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  const _StatTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
