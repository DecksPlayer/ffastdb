# ffastdb — Bugs Confirmados

> Análisis técnico sobre el código fuente.  
> **Versión analizada:** v0.3.1  
> **Última revisión:** 2026-08-03

> **📌 NOTA:** Los bugs BUG-1 a BUG-6 del registro histórico **están todos corregidos** en el código actual. Este documento ahora refleja el estado real del repositorio con los bugs todavía abiertos.

---

## Estado del registro histórico (BUG-1 a BUG-6)

| Bug | Severidad | Estado | Verificación |
|-----|-----------|--------|-------------|
| BUG-1: `_notifyWatchers` ignoraba `doc` | 🔴 Media | ✅ Corregido | [`fastdb.dart` L1052-1083](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L1052) — filtra por campo con dot-notation |
| BUG-2: `isNull()` siempre vacío | 🔴 Alta | ✅ Corregido | [`fast_query.dart` L1100-1103](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/query/fast_query.dart#L1100) — complemento vía `rangeSearch` |
| BUG-3: `deleteImpl` no notificaba watchers | 🔴 Alta | ✅ Corregido | [`_crud_operations.dart` L219](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/_crud_operations.dart#L219) — `_notifyWatchers(doc)` |
| BUG-4: FTS `retainAll` O(n×m) | 🔴 Alta | ✅ Corregido | [`fts_index.dart` L31](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/index/fts_index.dart#L31) — `_tokenIndex` es `Map<String, Set<int>>` |
| BUG-5: `HashIndex.lookup` copia innecesaria | 🟡 Media | ✅ Corregido | `lookupCount()` implementado |
| BUG-6: `bulkLoad` sin WAL fallback | 🔴 Media | ✅ Corregido | [`btree.dart` L206-213](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/index/btree.dart#L206) — free-list antes de rebuild |

---

## Bugs Abiertos — Estado actual (v0.3.1)

---

## OPEN-1: `_readAt` silencia corrupción de CRC32 con `return null`

**Archivo:** [`fastdb.dart` L1137-1139](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L1137)  
**Severidad:** 🔴 Crítica

```dart
// ACTUAL — corrupción silenciosa:
if (fullData.length >= totalSize) {
  final storedCrc = _readInt32(fullData, 4 + length);
  if (storedCrc != _crc32(fullData.sublist(4, 4 + length))) return null; // ← falla silenciosa
}
```

**Impacto:** `findById(id)` retorna `null` cuando el documento está corrupto en disco. El usuario asume que el documento no existe. La corrupción por I/O parcial, truncación o bit-flip pasa desapercibida en producción. No hay log, no hay excepción, no hay alerta.

**Fix:**
```dart
if (fullData.length >= totalSize) {
  final storedCrc = _readInt32(fullData, 4 + length);
  final computedCrc = _crc32(fullData.sublist(4, 4 + length));
  if (storedCrc != computedCrc) {
    throw StateError(
      'FastDB: CRC32 mismatch at offset $offset '
      '(expected 0x${computedCrc.toRadixString(16)}, '
      'got 0x${storedCrc.toRadixString(16)}). '
      'Document may be corrupted.',
    );
  }
}
```

---

## OPEN-2: `deleteWhere` no notifica watchers en path exitoso

**Archivo:** [`fastdb.dart` L1249-1296](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L1249)  
**Severidad:** 🔴 Crítica

```dart
// ACTUAL — path de éxito de deleteWhere (L1281-1289):
_batchMode = false;
await _pageManager.flushDirty();
await storage.flush();
await _saveHeader();
_queryCache.clear();
// ← _notifyWatchersBatch() AUSENTE
if (_autoCompactThreshold > 0) {
  await _maybeAutoCompact();
}
return count;
```

**Impacto:** Los `StreamController` registrados vía `db.watch('campo')` **nunca reciben eventos** cuando se eliminan documentos con `deleteWhere`. Las UIs reactivas muestran datos ya borrados hasta el próximo insert/update.

> **Nota:** `deleteImpl` individual ya fue corregido en v0.2.8 (BUG-3). Este bug es específico al path batch de `deleteWhere`.

**Fix (1 línea):**
```dart
_queryCache.clear();
_notifyWatchersBatch(); // ← agregar aquí
```

---

## OPEN-3: `OperationLog` se escribe ANTES del commit WAL

**Archivo:** [`_crud_operations.dart` L14-19, L74-77, L137-140, L188-191](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/_crud_operations.dart#L14)  
**Severidad:** 🟠 Alta

```dart
// ACTUAL — insertImpl y demás: log ANTES del WAL
if (!_db._inTransaction && !_db._batchMode && !_db._isReplayingOpLog) {
  await _db._opLog.log('insert', id: id, data: doc);  // ← escrito primero
}
if (hasWal) await wal.beginTransaction();
try {
  // ...
  if (hasWal) await wal.commit();
```

**Impacto:** Si el proceso cae entre el `_opLog.log()` y el `wal.commit()`, `_replayOpLog()` intentará reinsertar una operación que nunca se completó. Puede sobreescribir documentos existentes o incrementar `_nextId` incorrectamente. Afecta `insertImpl`, `putImpl`, `updateImpl` y `deleteImpl`.

**Fix:** Mover el log al final del try, post-commit:
```dart
if (hasWal) await wal.beginTransaction();
try {
  // ... operación completa ...
  if (hasWal) await wal.commit();
  // Solo logear DESPUÉS del commit exitoso:
  if (!_db._inTransaction && !_db._batchMode && !_db._isReplayingOpLog) {
    await _db._opLog.log('insert', id: id, data: doc);
  }
  return id;
} catch (e) {
  if (hasWal) await wal.rollback();
  rethrow;
}
```

---

## OPEN-4: `_serialize` usa `doc.cast<String, dynamic>()` lazy

**Archivo:** [`fastdb.dart` L1188-1192](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L1188)  
**Severidad:** 🟠 Alta

```dart
// ACTUAL — rama "doc ya tiene el ID correcto":
} else {
  map = doc.cast<String, dynamic>(); // ← NO valida tipos, solo crea una vista lazy
}
```

`Map.cast<K,V>()` no convierte ni valida en el momento del call — crea una vista con casting diferido. Si el mapa tiene claves no-`String` (Firebase, jsonDecode sin tipado), el error aparece dentro del serializer en un punto difícil de trazar.

**Fix (2 líneas):**
```dart
final map = Map<String, dynamic>.from(doc as Map);
if (id != null) map['ffdbID'] = id;
```

---

## OPEN-5: `_replayOpLog` silencia todos los errores

**Archivo:** [`fastdb.dart` L498-500](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L498)  
**Severidad:** 🟡 Media

```dart
// ACTUAL
} catch (_) {
  // Skip failed replays
}
```

**Impacto:** Si el replay falla (storage corrupto, schema incompatible), el usuario no tiene forma de saberlo. El replay continúa sobre un estado inconsistente.

**Fix:**
```dart
} catch (e, st) {
  assert(() {
    print('[ffastdb] Warning: replay of ${op.type}(id=${op.id}) failed: $e\n$st');
    return true;
  }());
}
```

---

## Tests de Regresión Recomendados

```dart
// test/regression_test.dart

test('deleteWhere notifica watchers', () async {
  db.addIndex('status');
  await db.insert({'status': 'active'});
  await db.insert({'status': 'active'});
  final events = <List<int>>[];
  db.watch('status').listen(events.add);
  await db.deleteWhere((q) => q.where('status').equals('active').findIds());
  await Future.delayed(Duration.zero);
  expect(events.length, greaterThan(1)); // initial + delete batch
  expect(events.last, isEmpty);
});

test('_readAt lanza StateError en CRC32 corrupto', () async {
  // Escribir doc válido
  final id = await db.insert({'name': 'Alice'});
  // Corromper el archivo en disco (flip bits en el payload)
  // ... (setup específico según storage) ...
  expect(() => db.findById(id), throwsStateError);
});

test('oplog no reinsertan docs en crash-recovery', () async {
  // 1. Insertar doc
  // 2. Simular crash post-oplog pre-commit
  // 3. Reabrir → doc no debe duplicarse
});
```

---

## Resumen final

| Bug | Severidad | Estado |
|-----|-----------|--------|
| OPEN-1: CRC32 mismatch silencioso | 🔴 Crítica | ❌ Abierto |
| OPEN-2: `deleteWhere` sin notificar watchers | 🔴 Crítica | ❌ Abierto |
| OPEN-3: OperationLog antes del WAL commit | 🟠 Alta | ❌ Abierto |
| OPEN-4: `_serialize` cast lazy | 🟠 Alta | ❌ Abierto |
| OPEN-5: replay errors silenciados | 🟡 Media | ❌ Abierto |
| BUG-1: `_notifyWatchers` ignoraba `doc` | 🔴 Media | ✅ Corregido (v0.2.8) |
| BUG-2: `isNull()` siempre vacío | 🔴 Alta | ✅ Corregido (v0.2.8) |
| BUG-3: `deleteImpl` no notificaba | 🔴 Alta | ✅ Corregido (v0.2.8) |
| BUG-4: FTS `retainAll` O(n×m) | 🔴 Alta | ✅ Corregido (v0.2.8) |
| BUG-5: `HashIndex.lookup` copia extra | 🟡 Media | ✅ Corregido |
| BUG-6: `bulkLoad` sin free-list | 🔴 Media | ✅ Corregido (v0.3.0) |


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
