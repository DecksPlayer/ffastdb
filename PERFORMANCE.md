# ffastdb — Análisis de Performance

> Análisis sobre: `_query_operations.dart`, `fastdb.dart`, `hash_index.dart`, `btree.dart`, `page_manager.dart`, `fast_serializer.dart`  
> Versión: v0.2.7+

---

## PERF-1: `getAll()` carga documentos secuencialmente (no en paralelo)

**Archivo:** [`_query_operations.dart`](lib/src/_query_operations.dart)  
**Impacto:** Alto — 10,000 docs ≈ 1 segundo de latencia con cache fría

```dart
Future<List<dynamic>> getAllImpl() async {
  final ids = await _db._primaryIndex.rangeSearch(1, _db._nextId - 1);
  final results = <dynamic>[];
  for (final id in ids) {
    final doc = await _db._findById(id); // ← secuencial: N awaits
    if (doc != null) results.add(doc);
  }
  return results;
}
```

Con disco SSD y cache fría, cada `_findById` puede tomar ~100µs. Con 10,000 documentos eso son **~1 segundo de espera serial**.

**Fix propuesto — lectura paralela con concurrencia limitada:**
```dart
Future<List<dynamic>> getAllImpl() async {
  final ids = await _db._primaryIndex.rangeSearch(1, _db._nextId - 1);
  // Procesar en chunks de 32 para no saturar el event loop
  const chunkSize = 32;
  final results = <dynamic>[];
  for (int i = 0; i < ids.length; i += chunkSize) {
    final chunk = ids.skip(i).take(chunkSize).toList();
    final docs = await Future.wait(chunk.map(_db._findById));
    results.addAll(docs.whereType<dynamic>().where((d) => d != null));
  }
  return results;
}
```

**Ganancia estimada:** 4-8x en datasets grandes con storage real.

---

## PERF-2: `sumWhere`, `avgWhere`, `minWhere`, `maxWhere` leen documentos completos

**Archivo:** [`fastdb.dart` L702-L779](lib/src/fastdb.dart#L702)  
**Impacto:** Alto — N lecturas de documentos completos cuando el valor ya está en el índice

Cada aggregation hace `findIds()` + `N × findById()`. Si el campo está en un `SortedIndex`, el valor ya está disponible en el árbol sin leer el documento completo.

```dart
// ACTUAL — lee todo el documento para extraer un solo campo:
for (final id in ids) {
  final doc = await _findById(id); // ← lectura completa
  if (doc is Map<String, dynamic>) {
    final v = doc[field];
    if (v is num) total += v;
  }
}
```

**Fix propuesto:** Para `SortedIndex`, exponer `index.values()` para aggregations sin tocar el storage:
```dart
// En SortedIndex — nuevo método:
Iterable<MapEntry<int, dynamic>> entries(); // (docId, value) sin leer docs

// En fastdb.dart:
Future<num> sumWhere(queryFn, String field) async {
  final idx = _secondaryIndexes[field];
  if (idx is SortedIndex) {
    // Fast path: O(n) sobre el índice, sin lecturas de storage
    final ids = Set<int>.from(await queryFn(query()));
    return idx.entries()
      .where((e) => ids.contains(e.key) && e.value is num)
      .fold<num>(0, (acc, e) => acc + (e.value as num));
  }
  // Fallback lento para campos sin índice...
}
```

**Ganancia estimada:** 10-50x para aggregations en campos indexados.

---

## PERF-3: `HashIndex.all()` reconstruye la lista completa en cada llamada

**Archivo:** [`hash_index.dart` L283-L291](lib/src/index/hash_index.dart)  
**Impacto:** Medio-Alto — se llama en sort, watchers y condiciones negadas

```dart
@override
List<int> all() {
  final result = <int>[];
  for (final bucket in _buckets) {
    for (final entry in bucket) {
      result.addAll(entry.docIds); // O(total_docs) cada vez
    }
  }
  return result;
}
```

`all()` se llama en:
- `_applySort()` — para cada sort query
- `_notifyWatchersBatch()` — en cada mutación
- Condiciones negadas (`not().equals()`) — requiere complemento

Con 100,000 documentos, esto genera ~400,000 operaciones por consulta.

**Fix propuesto — cache invalidable:**
```dart
class HashIndex {
  List<int>? _allCache; // ← nuevo

  @override
  List<int> all() => _allCache ??= _buildAll();

  List<int> _buildAll() {
    final result = <int>[];
    for (final bucket in _buckets) {
      for (final entry in bucket) result.addAll(entry.docIds);
    }
    return result;
  }

  void add(int docId, dynamic value) {
    _allCache = null; // invalidar en mutación
    // ... lógica existente ...
  }

  void remove(int docId, dynamic value) {
    _allCache = null; // invalidar en mutación
    // ... lógica existente ...
  }
}
```

**Ganancia estimada:** 10-100x en consultas con sort o condiciones negadas frecuentes.

---

## PERF-4: `BTree.rangeSearch` mantiene `seenIds` Set para todos los docs

**Archivo:** [`btree.dart` L565-L610](lib/src/index/btree.dart)  
**Impacto:** Bajo-Medio — overhead de memoria y tiempo para `getAll()`

```dart
// rangeSearch mantiene dos Sets que crecen a N elementos:
final Set<int> visited = {}; // páginas visitadas
final Set<int> seenIds = {}; // IDs deduplicados
```

Para un B-Tree correctamente formado, `seenIds` nunca debería tener duplicados. Este overhead existe solo como guardia de corrupción.

**Fix propuesto:**
```dart
Future<List<int>> rangeSearch(int low, int high, {bool skipDedupe = false}) async {
  final Set<int>? seenIds = skipDedupe ? null : {};
  // ... usar seenIds solo si no es null ...
}

// En getAll() — usar path sin dedupe:
final ids = await _primaryIndex.rangeSearch(1, _nextId - 1, skipDedupe: true);
```

---

## PERF-5: `PageManager.flushDirty()` escribe páginas en serie (una a una)

**Archivo:** [`page_manager.dart` L137-L142](lib/src/storage/page_manager.dart)  
**Impacto:** Medio — bottleneck en `commitBatch` con muchas dirty pages

```dart
Future<void> flushDirty() async {
  for (final entry in _dirtyPages.entries) {
    await storage.write(entry.key * pageSize, entry.value); // serial
  }
  _dirtyPages.clear();
}
```

Con `insertAll(5000)` puede haber hasta 1,000 dirty pages. Los writes en serie desperdician la capacidad de IO concurrente del sistema operativo.

**Fix propuesto — merge de páginas contiguas:**
```dart
Future<void> flushDirty() async {
  if (_dirtyPages.isEmpty) return;
  
  // Ordenar páginas y agrupar contiguas para un solo write por rango
  final sorted = _dirtyPages.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  
  int rangeStart = sorted.first.key;
  final rangeData = BytesBuilder();
  rangeData.add(sorted.first.value);
  
  for (int i = 1; i < sorted.length; i++) {
    if (sorted[i].key == sorted[i-1].key + 1) {
      rangeData.add(sorted[i].value); // página contigua → merge
    } else {
      await storage.write(rangeStart * pageSize, rangeData.takeBytes());
      rangeStart = sorted[i].key;
      rangeData.add(sorted[i].value);
    }
  }
  await storage.write(rangeStart * pageSize, rangeData.takeBytes());
  _dirtyPages.clear();
}
```

**Ganancia estimada:** 2-5x en flushes con muchas páginas contiguas (común en inserts secuenciales).

---

## PERF-6: `fast_serializer.dart` usa try/catch para detección de tipos Firebase en cada valor

**Archivo:** [`fast_serializer.dart`](lib/src/serialization/fast_serializer.dart)  
**Impacto:** Medio — path lento para documentos con arrays de muchos elementos

Los tres bloques `try/catch` en `_toEncodable` para Firebase `Timestamp`, `GeoPoint`, y `DocumentReference` se ejecutan para **cada valor** en el documento, incluyendo `String`, `int`, `bool` que nunca son Firebase objects.

```dart
// ACTUAL — 3 try/catch por cada valor del documento:
dynamic _toEncodable(dynamic value) {
  try { return (value as Timestamp).toDate()... } catch (_) {}
  try { return (value as GeoPoint)... } catch (_) {}
  try { return (value as DocumentReference)... } catch (_) {}
  return value;
}
```

**Fix propuesto — dispatch en O(1) por tipo:**
```dart
dynamic _toEncodable(dynamic value) {
  if (value is String || value is num || value is bool || value is Null) {
    return value; // fast path — tipos primitivos comunes
  }
  if (value is DateTime) return value.toIso8601String();
  // Solo intentar Firebase si el tipo no es primitivo:
  try { return _encodeFirebaseType(value); } catch (_) {}
  return value;
}
```

**Ganancia estimada:** 2-10x en serialización de documentos con arrays grandes de primitivos.

---

## Resumen de Oportunidades

| # | Área | Impacto | Esfuerzo | Ganancia Estimada |
|---|------|---------|----------|-------------------|
| PERF-1 | `getAll()` paralelo | 🔴 Alto | Bajo | 4-8x |
| PERF-2 | Aggregations sin reads | 🔴 Alto | Medio | 10-50x |
| PERF-3 | `HashIndex.all()` cache | 🟡 Medio | Bajo | 10-100x |
| PERF-4 | `rangeSearch` sin dedupe | 🟢 Bajo | Muy bajo | 5-20% |
| PERF-5 | `flushDirty()` merge páginas | 🟡 Medio | Medio | 2-5x |
| PERF-6 | Serializer fast path tipos | 🟡 Medio | Bajo | 2-10x |

---

## Benchmarks Reproducibles

Para medir el impacto real de cada fix, ejecutar:

```bash
dart run benchmark/main.dart
```

Los benchmarks deberían incluir:
- `getAll_10k`: 10,000 documentos, medir latencia total
- `query_indexed_100k`: query por campo indexado con 100k docs
- `fts_search_and`: búsqueda FTS con 2 tokens AND en 50k docs  
- `aggregation_sum`: `sumWhere` sobre campo indexado vs no indexado
- `insertAll_5k`: batch insert de 5,000 documentos

> Ver directorio [`benchmark/`](benchmark/) para implementaciones actuales.
