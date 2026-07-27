# ffastdb — Reglas de Proyecto para Gemini

## Descripción del Proyecto

`ffastdb` es una base de datos NoSQL embebida, pura Dart, de alto rendimiento, para Flutter y aplicaciones Dart.

- **Package:** `ffastdb` en pub.dev
- **Versión actual:** 0.2.7+
- **Plataformas:** Web, Android, iOS, Windows, Linux, macOS
- **Repositorio:** `c:\Users\gonoj\OneDrive\Documentos\GitHub\fastdb`

---

## REGLA FUNDAMENTAL: Velocidad Primero, Sin Sobre-Ingeniería

> ffastdb existe para ser **rápido**. Todo cambio debe preservar o mejorar el rendimiento.

**SÍ hacer:**
- Separar código en clases y archivos helpers enfocados
- Usar `part` files para secciones de `FastDB` (patrón ya establecido)
- Código directo y funcional con propósito claro
- Benchmarkear antes y después de cambios significativos

**NO hacer:**
- Agregar DI containers, repositories, ni capas de abstracción sobre la DB
- Crear wrappers que agreguen indirección sin beneficio de performance
- Agregar features no solicitados
- Usar `dart:io` directamente en código compartido

---

## Soporte Cross-Platform (CRÍTICO)

Todo código DEBE funcionar en todas las plataformas:

| Plataforma | Estrategia de Storage | Gate de Import |
|------------|----------------------|----------------|
| Android / iOS / Windows / Linux / macOS | `IoStorageStrategy` + `WalStorageStrategy` | `dart.library.io` |
| Web (browser) | `IndexedDbStorageStrategy` | `dart.library.js_interop` |
| Tests | `MemoryStorageStrategy` | siempre disponible |

**Reglas cross-platform:**
1. NUNCA usar `dart:io` directamente en código compartido
2. SIEMPRE usar imports condicionales para código específico de plataforma
3. El hub de imports condicionales es `lib/src/platform/open_database.dart`
4. En Web, el parámetro `directory` se ignora silenciosamente
5. El barrel export `lib/ffastdb.dart` usa `export ... if (dart.library.js_interop)` para estrategias de storage

---

## Estructura del Proyecto

```
lib/
├── ffastdb.dart                     ← export público (usuarios importan esto)
└── src/
    ├── fastdb.dart                  ← clase FastDB principal
    ├── _crud_operations.dart        ← part: insert, update, delete
    ├── _query_operations.dart       ← part: find, getAll, count
    ├── _batch_operations.dart       ← part: insertAll, batch mode
    ├── _index_manager.dart          ← part: addIndex, reindex
    ├── _storage_manager.dart        ← part: compact, migrations
    ├── ffastdb_singleton.dart       ← singleton global ffastdb
    ├── annotations.dart
    ├── query/fast_query.dart        ← QueryBuilder con CBO y cache
    ├── index/                       ← HashIndex, SortedIndex, BitmaskIndex, FtsIndex, CompositeIndex, BTree
    ├── serialization/               ← TypeAdapter, FastSerializer, BinaryIO
    └── storage/                     ← StorageStrategy + implementaciones
```

---

## Patrones de API

### Inicialización recomendada (Flutter)

```dart
// Singleton — patrón recomendado
await ffastdb.init('myapp', directory: dir.path);

// Con índices declarados upfront (se persisten al cerrar limpiamente)
final db = await FastDB.init(
  IoStorageStrategy('${dir.path}/myapp.fdb'),
  indexes: ['status', 'userId'],
  sortedIndexes: ['createdAt'],
  version: 2,
  migrations: { 2: (doc) => {...doc, 'migrated': true} },
);
```

### Tests — SIEMPRE usar MemoryStorageStrategy

```dart
final db = FastDB.forTesting(MemoryStorageStrategy());
await db.open();
// ... test ...
await db.close();
```

### Query API

```dart
// Fluent (preferido) — resuelve documentos directamente
final docs = await db.query()
  .where('status').equals('active')
  .sortBy('createdAt', descending: true)
  .limit(20)
  .find();

// Count O(1)
final n = await db.query().where('status').equals('active').count();

// Explain (verificar plan durante desarrollo)
print(db.query().where('status').equals('active').explain());
```

### Índices

```dart
db.addIndex('field');                     // HashIndex — O(1) equals
db.addSortedIndex('field');               // SortedIndex — O(log n) range/sort
db.addCompositeIndex(['city', 'status']); // CompositeIndex — AND multi-campo
db.addFtsIndex('field');                  // FTS — búsqueda de texto
```

---

## Bugs Conocidos — Arreglar en la Fuente, No Workarounds

| Bug | Ubicación | Fix |
|-----|-----------|-----|
| `deleteImpl` no notifica watchers | `_crud_operations.dart` | Agregar `_db._notifyWatchers(doc)` |
| `isNull()` siempre retorna vacío | `fast_query.dart` | Computar complemento vía primarySearch |
| `FtsIndex.retainAll(List)` es O(n×m) | `fts_index.dart` L~147 | `retainAll(matches.toSet())` |
| `QueryCache` es `static` (global) | `fast_query.dart` L52 | Mover a campo de instancia |

Ver `BUGS.md` para detalles completos.

---

## Reglas de Testing

```bash
dart test test/                           # todos los tests
dart test test/fastdb_test.dart           # test principal
dart test test/ --name "batch"            # filtrar por nombre
dart analyze                              # linting
```

- Usar `MemoryStorageStrategy()` en TODOS los tests
- Usar `FastDB.forTesting(...)` (no el singleton)
- Siempre `await db.close()` en `tearDown`

---

## Checklist para Nuevo Código

- [ ] ¿Funciona en Web, Android, iOS, Windows, Linux?
- [ ] ¿Usa `StorageStrategy` en vez de `dart:io`?
- [ ] ¿Tiene test en `test/`?
- [ ] ¿Está exportado en `lib/ffastdb.dart` si es API pública?
- [ ] ¿El rendimiento es aceptable?

---

## Documentos de Análisis (en la raíz del proyecto)

- `ANALYSIS.md` — Resumen ejecutivo y roadmap
- `BUGS.md` — Bugs confirmados con fixes
- `PERFORMANCE.md` — Cuellos de botella y optimizaciones
- `ARCHITECTURE.md` — Deuda técnica y propuestas
- `API_IMPROVEMENTS.md` — Mejoras de API non-breaking
- `SUPPORTED_DATA_TYPES.md` — Tipos serializables soportados
