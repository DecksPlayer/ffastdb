# ffastdb — Bugs Confirmados

> Análisis técnico sobre el código fuente: `fastdb.dart`, `_crud_operations.dart`, `fast_query.dart`, `fts_index.dart`, `hash_index.dart`, `btree.dart`.
> Versión analizada: v0.2.7+

> **⚠️ NOTA (2026-07-27):** Este documento es histórico. La auditoría completa y el plan de corrección vigente están en [`FIX_PLAN.md`](FIX_PLAN.md). Los bugs de este documento ya están corregidos en el código actual (ver tabla Resumen).

---

## BUG-1: `_notifyWatchers` ignora el parámetro `doc`

**Archivo:** [`fastdb.dart` L826-L828](lib/src/fastdb.dart#L826)  
**Severidad:** 🔴 Media  

```dart
// ACTUAL — el parámetro `doc` se recibe pero NUNCA se usa:
void _notifyWatchers(dynamic doc) {
  if (_batchMode) return;
  _notifyWatchersBatch(); // ← siempre emite TODOS los IDs del campo
}
```

**Impacto:** Cada insert/update/delete notifica a **todos** los watchers de **todos** los campos con **todos** los IDs indexados. No filtra por el documento modificado ni por si el campo watched cambió realmente. En aplicaciones con miles de documentos, genera trabajo innecesario en cada mutación.

**Fix propuesto:**
```dart
void _notifyWatchers(dynamic doc) {
  if (_batchMode) return;
  if (doc is Map<String, dynamic>) {
    // Solo notificar los watchers cuyo campo está en el doc modificado
    for (final field in _watchers.keys) {
      if (doc.containsKey(field)) {
        final stream = _watchers[field];
        final idx = _secondaryIndexes[field];
        if (stream != null && idx != null) stream.add(idx.all());
      }
    }
  } else {
    _notifyWatchersBatch(); // fallback para TypeAdapters
  }
}
```

---

## BUG-2: `isNull()` en `QueryBuilder` siempre retorna lista vacía

**Archivo:** [`fast_query.dart` L716-L728](lib/src/query/fast_query.dart)  
**Severidad:** 🔴 Alta

```dart
// ACTUAL — isNull() siempre retorna lista vacía:
@override
Iterable<int> evaluate(SecondaryIndex index) {
  if (!nullExpected) {
    return index.all(); // isNotNull → OK
  }
  return const []; // isNull → SIEMPRE VACÍO ← BUG
}
```

**Impacto:** `db.query().where('email').isNull().find()` retorna siempre `[]`, aunque existan documentos sin el campo `email`. La operación es completamente inútil en su forma actual.

**Fix propuesto:**  
El `QueryBuilder` necesita acceso a un `primarySearch` para computar el complemento: `primaryIds.difference(indexedIds)`.

```dart
// En QueryBuilder — agregar referencia a primarySearch:
class QueryBuilder {
  final Future<List<int>> Function(int, int) _primarySearch; // rangeSearch existente

  Iterable<int> _evaluateIsNull(SecondaryIndex index, int maxId) {
    final indexedIds = Set<int>.from(index.all());
    // primarySearch(1, maxId) da todos los IDs vivos:
    return _allPrimaryIds.difference(indexedIds); // documentos sin el campo
  }
}
```

---

## BUG-3: `deleteImpl` no notifica watchers

**Archivo:** [`_crud_operations.dart` L162-L200](lib/src/_crud_operations.dart)  
**Severidad:** 🔴 Alta

```dart
Future<bool> deleteImpl(int id) async {
  // ... elimina del índice primario y secundarios ...
  if (!_db._batchMode) {
    await _db._saveHeader();
    QueryBuilder.clearCache();
    // ← FALTA: _db._notifyWatchers(doc);
  }
}
```

**Impacto:** Los watchers registrados con `db.watch('field')` **no se notifican al borrar documentos**. Las UIs que dependen de streams reactivos se desincronizan silenciosamente tras un delete.

**Fix propuesto:**
```dart
Future<bool> deleteImpl(int id) async {
  final doc = await _db._findById(id); // leer ANTES de borrar
  // ... lógica de borrado ...
  if (!_db._batchMode) {
    await _db._saveHeader();
    QueryBuilder.clearCache();
    _db._notifyWatchers(doc); // ← AGREGAR
  }
  return true;
}
```

---

## BUG-4: `FtsIndex._runSearch` usa `retainAll` con `List` — O(n×m)

**Archivo:** [`fts_index.dart` L133-L158](lib/src/index/fts_index.dart)  
**Severidad:** 🔴 Alta (performance crítica)

```dart
final results = <int>{};
bool first = true;
for (final token in tokens) {
  final matches = _tokenIndex[token] ?? []; // ← List<int>
  if (first) {
    results.addAll(matches);
    first = false;
  } else {
    results.retainAll(matches); // ← O(n×m) porque matches es List
  }
}
```

`Set.retainAll` con un `List<T>` como argumento verifica pertenencia con `contains()` lineal sobre la lista. Con 10,000 docs y 50 tokens, esto es **500,000 operaciones de búsqueda lineal**.

**Fix (1 línea):**
```dart
results.retainAll(matches.toSet()); // O(n) en vez de O(n×m)
```

---

## BUG-5: `HashIndex.lookup` retorna copia innecesaria siempre

**Archivo:** [`hash_index.dart` L196-L211](lib/src/index/hash_index.dart)  
**Severidad:** 🟡 Media

```dart
@override
List<int> lookup(dynamic value) {
  // ...
  return List<int>.from(entry.docIds); // ← copia SIEMPRE, aunque solo se necesite .length
}
```

El comentario justifica la copia defensiva para evitar mutación del índice. Sin embargo, para el hot path de `.count()` solo se necesita `.length`, y la copia materializa toda la lista innecesariamente.

**Fix propuesto:** Exponer un método `lookupCount()` que retorne directamente `entry.docIds.length` sin copiar, o una `UnmodifiableListView`:
```dart
int lookupCount(dynamic value) {
  // ... misma lógica de hash lookup ...
  return entry?.docIds.length ?? 0; // O(1), sin copia
}
```

---

## BUG-6: `BTree.bulkLoad` hace inserts individuales sin WAL cuando el árbol es grande

**Archivo:** [`btree.dart` L186-L191](lib/src/index/btree.dart)  
**Severidad:** 🔴 Media

```dart
} else {
  // Fall back to individual inserts for large trees
  for (final entry in sortedEntries) {
    await insert(entry.key, entry.value); // ← sin protección WAL
  }
  return;
}
```

Cuando el árbol tiene ≥500 entradas y se llama a `insertAll` con >5,000 documentos, el `bulkLoad` hace miles de inserts individuales sin transacción WAL. Si el proceso se interrumpe a mitad, el árbol puede quedar en estado inconsistente.

**Fix:** El caller (`_BatchOperations.commitBatch`) ya gestiona el WAL si existe. Asegurarse de que el path de fallback esté envuelto en la misma transacción WAL.

---

## Tests Recomendados para Regresiones

```dart
// test/regression_test.dart

test('deleteImpl notifica watchers', () async {
  db.addIndex('status');
  await db.insert({'status': 'active'});
  final events = <List<int>>[];
  db.watch('status').listen(events.add);
  await db.delete(1);
  await Future.delayed(Duration.zero);
  expect(events.length, 2); // initial + delete
  expect(events.last, isEmpty);
});

test('isNull retorna documentos sin el campo', () async {
  db.addIndex('email');
  await db.insert({'name': 'Alice', 'email': 'alice@test.com'});
  await db.insert({'name': 'Bob'}); // sin email
  final results = await db.query().where('email').isNull().find();
  expect(results.length, 1);
  expect(results.first['name'], 'Bob');
});

test('FTS retainAll correcto con AND multi-token', () async {
  db.addFtsIndex('text');
  await db.insert({'text': 'hello world foo'});
  await db.insert({'text': 'hello bar'});
  await db.insert({'text': 'world baz'});
  final results = await db.query().where('text').fts('hello world').find();
  expect(results.length, 1); // solo el primero tiene AMBAS palabras
});
```

---

## Resumen

| Bug | Severidad | Esfuerzo Fix | Estado |
|-----|-----------|-------------|--------|
| BUG-1: `_notifyWatchers` ignora `doc` | 🔴 Media | Bajo (10 líneas) | ✅ Corregido (filtra por campo) |
| BUG-2: `isNull()` siempre vacío | 🔴 Alta | Medio | ✅ Corregido (complemento vía rangeSearch) |
| BUG-3: `deleteImpl` no notifica | 🔴 Alta | Muy bajo (1 línea) | ✅ Corregido |
| BUG-4: FTS `retainAll` O(n×m) | 🔴 Alta | Muy bajo (1 línea) | ✅ Corregido (`matches.toSet()`) |
| BUG-5: `HashIndex.lookup` copia innecesaria | 🟡 Media | Bajo | ✅ Corregido (`lookupCount`) |
| BUG-6: `bulkLoad` sin WAL fallback | 🔴 Media | Bajo | ⚠️ Parcial (ver FIX_PLAN.md F3.14) |
