# ffastdb — Análisis Técnico Completo

> Análisis exhaustivo del código fuente de `ffastdb` v0.2.7+  
> Basado en: `fastdb.dart`, `_crud_operations.dart`, `_batch_operations.dart`,  
> `_query_operations.dart`, `_storage_manager.dart`, `_index_manager.dart`,  
> `fast_query.dart`, `btree.dart`, `hash_index.dart`, `sorted_index.dart`,  
> `fts_index.dart`, `wal_storage_strategy.dart`, `page_manager.dart`, `fast_serializer.dart`.

---

## Documentos de Análisis

| Documento | Contenido |
|-----------|-----------|
| [BUGS.md](BUGS.md) | 6 bugs confirmados con reproducción y fix propuesto |
| [PERFORMANCE.md](PERFORMANCE.md) | 6 oportunidades de performance con ganancias estimadas |
| [ARCHITECTURE.md](ARCHITECTURE.md) | 7 mejoras de arquitectura y deuda técnica |
| [API_IMPROVEMENTS.md](API_IMPROVEMENTS.md) | 8 mejoras de API/ergonomía (todas non-breaking) |

---

## 🔴 Bugs Críticos — Acción Inmediata

### 1. `deleteImpl` no notifica watchers (1 línea de fix)

```dart
// _crud_operations.dart — agregar al final del try block:
_db._notifyWatchers(doc); // ← una sola línea
```

Los streams reactivos (`watch()`) no se actualizan al borrar documentos. UIs con BLoCs que escuchan watchers **no ven los deletes**.

### 2. `isNull()` siempre retorna vacío

`db.query().where('field').isNull().find()` **siempre retorna `[]`** independientemente de los datos. La feature está completamente rota.

### 3. FTS multi-token AND es O(n×m) — corrección 1 línea

```dart
// fts_index.dart línea ~147:
results.retainAll(matches);         // ACTUAL — O(n×m)
results.retainAll(matches.toSet()); // FIX    — O(n)
```

Con 50,000 documentos y búsquedas de 2+ palabras, esta diferencia es de **segundos vs milisegundos**.

### 4. `QueryCache` es global (contamina tests y multi-DB)

```dart
// fast_query.dart:
static final QueryCache _queryCache = QueryCache(maxSize: 256); // ← BUG
```

En tests paralelos con múltiples instancias, el cache de una instancia puede retornar resultados de otra. Causa falsos positivos/negativos en tests.

---

## 🟢 Quick Wins de Performance

| Fix | Esfuerzo | Ganancia |
|-----|----------|----------|
| `HashIndex.all()` cache invalidable | 1h | 10-100x en queries con sort |
| `getAll()` con `Future.wait` en chunks | 2h | 4-8x en datasets grandes |
| `_toEncodable` fast path primitivos | 30min | 2-10x en arrays grandes |
| `flushDirty()` merge páginas contiguas | 3h | 2-5x en batch inserts |

---

## 📋 Roadmap Sugerido

### Sprint 1 — Bugs (estimado: 2-4h)
- [ ] Fix `deleteImpl` notifica watchers
- [ ] Fix FTS `retainAll` → `retainAll(matches.toSet())`
- [ ] Fix `QueryCache` de static a instancia
- [ ] Fix CRC32 duplicado → `_checksum.dart`

### Sprint 2 — API features (estimado: 1-2 días)
- [ ] Agregar `upsert()` / `upsertWhere()`
- [ ] Exponer `findByIds(List<int>)` público
- [ ] Agregar `watchDocs()` (wrapper sobre `watch()`)
- [ ] Bajar SDK mínimo de `>=3.11.1` a `>=3.3.0`

### Sprint 3 — Performance (estimado: 2-5 días)
- [ ] `HashIndex.all()` cache invalidable
- [ ] `getAll()` paralelo con chunks
- [ ] `sumWhere`/aggregations sin reads de documentos en índices sorted
- [ ] `_toEncodable` fast path para tipos primitivos

### Sprint 4 — Arquitectura (estimado: 1-2 semanas)
- [ ] R/W Lock para reads concurrentes
- [ ] Fix `isNull()` con acceso a `primarySearch`
- [ ] FTS con stopwords y `minTokenLength`
- [ ] `QueryBuilder.watch()` fluido

---

## Estado Actual del Código

```
fastdb v0.2.7+
├── Core: ✅ Sólido — B-Tree, WAL, PageManager funcionan correctamente
├── Queries: ⚠️  QueryCache global, isNull() roto, FTS lento con AND
├── Reactivo: ⚠️  deleteImpl no notifica, _notifyWatchers ignora el doc
├── Performance: ⚠️  reads serializados, getAll() secuencial, HashIndex.all() sin cache
├── API: ✅ Buena base, faltan upsert(), findByIds(), watchDocs()
└── Tests: ✅ Cobertura buena en CRUD, ⚠️ gaps en watchers/FTS/multi-instancia
```

---

## Fortalezas del Código Base

- **B-Tree con WAL**: implementación correcta y con tests sólidos.
- **Compactación**: `compact()` funciona bien para el caso general.
- **Índices múltiples**: HashIndex, SortedIndex, BitmaskIndex, FtsIndex, CompositeIndex — excelente cobertura de casos de uso.
- **API fluida**: `query().where().equals().find()` es ergonómica y expresiva.
- **TypeAdapters**: sistema de serialización personalizada estilo Hive.
- **Plataforma cruzada**: estrategias de storage para IO, Web (IndexedDB), memoria, WAL.
- **Auto-compactación**: threshold configurable para compactar automáticamente.
