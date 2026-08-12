import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:ffastdb/ffastdb.dart';
import 'package:path_provider/path_provider.dart';
import 'stress_test_page.dart';

// ─── Entry point ────────────────────────────────────────────────────────────

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // debugPrint (not dart:developer's log()) — log() only shows up in
  // DevTools' Logging view, never in the plain `flutter run` / IDE debug
  // console. debugPrint shows in both, and on every hot restart (main()
  // genuinely re-runs on hot restart — the isolate is torn down and
  // recreated, so nothing here is "stale").
  debugPrint('[ffastdb] main() start');

  // On web/WASM the directory is ignored — openDatabase() uses localStorage.
  // On native, path_provider gives a suitable persistent directory.
  String dir = '';
  if (!kIsWeb) {
    final appDir = await getApplicationDocumentsDirectory();
    dir = appDir.path;
  }

  // Timed + progress-logged open: if open() is slow, this tells you WHY —
  // either it's stuck rebuilding secondary indexes (progress ticks below,
  // which only happens when the last shutdown wasn't clean — e.g. a Flutter
  // hot restart, which never calls db.close()) or something else entirely
  // (in which case you'll only see the start/end lines with a big gap).
  final openSw = Stopwatch()..start();
  debugPrint('[ffastdb] openDatabase: starting…');
  double lastLoggedProgress = -1;
  final db = await openDatabase(
    'wordnotes',
    directory: dir,
    version: 1,
    indexes: ['type', 'userId', 'postId'],
    sortedIndexes: ['word', 'content', 'likes'],
    ftsIndexes: ['content'],
    compositeIndexes: [['type', 'userId']],
    onProgress: (p) {
      // rebuildSecondaryIndexes() reports 0.0..1.0 — only fires on a dirty
      // (unclean-shutdown) open, so seeing this at all is itself a signal.
      if (p - lastLoggedProgress >= 0.1 || p >= 1.0) {
        lastLoggedProgress = p;
        debugPrint(
          '[ffastdb] openDatabase: rebuilding indexes ${(p * 100).toStringAsFixed(0)}% '
          '(${openSw.elapsedMilliseconds}ms elapsed)',
        );
      }
    },
  );
  openSw.stop();
  debugPrint(
    '[ffastdb] openDatabase: done in ${openSw.elapsedMilliseconds}ms, ${await db.count()} docs',
  );

  runApp(WordAnnotatorApp(db: db));
}

// ─── App root ────────────────────────────────────────────────────────────────

class WordAnnotatorApp extends StatelessWidget {
  const WordAnnotatorApp({super.key, required this.db});
  final FastDB db;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Anotador de Palabras',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4A6FA5)),
        useMaterial3: true,
      ),
      home: WordListPage(db: db),
    );
  }
}

// ─── Word list page ──────────────────────────────────────────────────────────

class WordListPage extends StatefulWidget {
  const WordListPage({super.key, required this.db});
  final FastDB db;

  @override
  State<WordListPage> createState() => _WordListPageState();
}

class _WordListPageState extends State<WordListPage> {
  List<Map<String, dynamic>> _entries = [];
  String _search = '';
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // NOT rangeSearch() + findById() per id: that fetches EVERY document in
    // the whole database (including the stress-test page's ~100k seeded
    // posts/users/comments, which share this same DB) one network/disk
    // round-trip at a time, just to throw almost all of them away below.
    // With 100k stress-test docs present this alone is what looked like the
    // app being "stuck blank" after a fast-looking open() — not the DB open,
    // but this screen's own load path. `word` already has a sorted index
    // (registered in main()), so ask the DB to filter server-side instead:
    // only docs that HAVE a `word` field come back at all.
    final docs = await widget.db.query().where('word').isNotNull().find();
    final maps = <Map<String, dynamic>>[];
    for (final doc in docs) {
      if (doc is Map<String, dynamic> && doc['word'] is String && doc['note'] is String) {
        maps.add({...doc, '__dbId': doc['ffdbID']});
      }
    }
    maps.sort((a, b) =>
        (a['word'] as String).toLowerCase().compareTo(
          (b['word'] as String).toLowerCase(),
        ));
    if (mounted) setState(() => _entries = maps);
  }

  List<Map<String, dynamic>> get _filtered {
    if (_search.isEmpty) return _entries;
    final q = _search.toLowerCase();
    return _entries
        .where((e) =>
            (e['word'] as String).toLowerCase().contains(q) ||
            (e['note'] as String).toLowerCase().contains(q))
        .toList();
  }

  Future<void> _openForm({Map<String, dynamic>? entry}) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => WordForm(db: widget.db, entry: entry),
    );
    if (saved == true) _load();
  }

  Future<void> _delete(Map<String, dynamic> entry) async {
    final id = entry['__dbId'] as int?;
    if (id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Eliminar'),
        content: Text('¿Eliminar "${entry['word']}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Eliminar')),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.db.delete(id);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Anotador de Palabras'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.speed),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => StressTestPage(db: widget.db)),
            ),
            tooltip: 'Stress Test',
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SearchBar(
              controller: _searchCtrl,
              hintText: 'Buscar palabra o nota…',
              leading: const Icon(Icons.search),
              trailing: [
                if (_search.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _searchCtrl.clear();
                      setState(() => _search = '');
                    },
                  ),
              ],
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
        ),
      ),
      body: items.isEmpty
          ? Center(
              child: Text(
                _search.isEmpty
                    ? 'Aún no hay palabras.\nToca + para agregar la primera.'
                    : 'Sin resultados para "$_search".',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: items.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final e = items[i];
                return ListTile(
                  title: Text(
                    e['word'] as String,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    e['note'] as String,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _openForm(entry: e),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        color: Theme.of(context).colorScheme.error,
                        onPressed: () => _delete(e),
                      ),
                    ],
                  ),
                  onTap: () => _openForm(entry: e),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(Icons.add),
        label: const Text('Nueva palabra'),
      ),
    );
  }
}

// ─── Add / Edit form (bottom sheet) ─────────────────────────────────────────

class WordForm extends StatefulWidget {
  const WordForm({super.key, required this.db, this.entry});
  final FastDB db;
  final Map<String, dynamic>? entry;

  @override
  State<WordForm> createState() => _WordFormState();
}

class _WordFormState extends State<WordForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _wordCtrl;
  late final TextEditingController _noteCtrl;
  bool _saving = false;

  bool get _isEdit => widget.entry != null;

  @override
  void initState() {
    super.initState();
    _wordCtrl = TextEditingController(text: widget.entry?['word'] as String? ?? '');
    _noteCtrl = TextEditingController(text: widget.entry?['note'] as String? ?? '');
  }

  @override
  void dispose() {
    _wordCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final data = {
      'word': _wordCtrl.text.trim(),
      'note': _noteCtrl.text.trim(),
      'updatedAt': DateTime.now(),
    };

    if (_isEdit) {
      await widget.db.update(widget.entry!['__dbId'] as int, data);
    } else {
      await widget.db.insert({...data, 'createdAt': DateTime.now()});
    }

    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + bottom),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _isEdit ? 'Editar palabra' : 'Nueva palabra',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _wordCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Palabra',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.abc),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Ingresa una palabra' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _noteCtrl,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Anotación',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.notes),
                alignLabelWithHint: true,
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Ingresa una anotación' : null,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: Text(_isEdit ? 'Guardar cambios' : 'Agregar'),
            ),
          ],
        ),
      ),
    );
  }
}


class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // TRY THIS: Try running your application with "flutter run". You'll see
        // the application has a purple toolbar. Then, without quitting the app,
        // try changing the seedColor in the colorScheme below to Colors.green
        // and then invoke "hot reload" (save your changes or press the "hot
        // reload" button in a Flutter-supported IDE, or press "r" if you used
        // the command line to start the app).
        //
        // Notice that the counter didn't reset back to zero; the application
        // state is not lost during the reload. To reset the state, use hot
        // restart instead.
        //
        // This works for code too, not just values: Most code changes can be
        // tested with just a hot reload.
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  void _incrementCounter() {
    setState(() {
      // This call to setState tells the Flutter framework that something has
      // changed in this State, which causes it to rerun the build method below
      // so that the display can reflect the updated values. If we changed
      // _counter without calling setState(), then the build method would not be
      // called again, and so nothing would appear to happen.
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      appBar: AppBar(
        // TRY THIS: Try changing the color here to a specific color (to
        // Colors.amber, perhaps?) and trigger a hot reload to see the AppBar
        // change color while the other colors stay the same.
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
      ),
      body: Center(
        // Center is a layout widget. It takes a single child and positions it
        // in the middle of the parent.
        child: Column(
          // Column is also a layout widget. It takes a list of children and
          // arranges them vertically. By default, it sizes itself to fit its
          // children horizontally, and tries to be as tall as its parent.
          //
          // Column has various properties to control how it sizes itself and
          // how it positions its children. Here we use mainAxisAlignment to
          // center the children vertically; the main axis here is the vertical
          // axis because Columns are vertical (the cross axis would be
          // horizontal).
          //
          // TRY THIS: Invoke "debug painting" (choose the "Toggle Debug Paint"
          // action in the IDE, or press "p" in the console), to see the
          // wireframe for each widget.
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
