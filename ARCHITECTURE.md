# ffastdb — Análisis de Arquitectura

> Análisis sobre la arquitectura interna: concurrencia, modularidad, estado compartido y deuda técnica.  
> Versión: v0.2.7+

---

## ARCH-1: `_exclusive()` serializa reads detrás de writes

**Archivo:** [`fastdb.dart` L85-L107](lib/src/fastdb.dart#L85)  
**Severidad:** 🟡 Alta (UX en Flutter)

Actualmente **todas** las operaciones pasan por `_exclusive()`, incluyendo reads:

```dart
Future<dynamic> findById(int id) => _exclusive(() => _findById(id));
Future<int> count()              => _exclusive(() => _queryOps.countImpl());
Future<bool> exists(int id)     => _exclusive(() => _queryOps.existsImpl(id));
Future<List<dynamic>> getAll()  => _exclusive(() => _queryOps.getAllImpl());
```

Si hay un `insertAll(10000)` en progreso, todos los `findById` se encolan detrás. En Flutter con BLoCs leyendo datos para la UI, esto genera **freezes visibles** durante operaciones batch largas.

**Propuesta — R/W Lock (múltiples lectores, un escritor):**

```dart
class _RWLock {
  int _readers = 0;
  bool _writing = false;
  final Queue<Completer<void>> _writeQueue = Queue();
  final Queue<Completer<void>> _readQueue = Queue();

  Future<T> read<T>(Future<T> Function() fn) async {
    while (_writing) await _readQueue.addAndWait();
    _readers++;
    try { return await fn(); }
    finally {
      _readers--;
      if (_readers == 0) _writeQueue.firstOrNull?.complete();
    }
  }

  Future<T> write<T>(Future<T> Function() fn) async {
    while (_writing || _readers > 0) await _writeQueue.addAndWait();
    _writing = true;
    try { return await fn(); }
    finally {
      _writing = false;
      for (final q in _readQueue) q.complete();
      _readQueue.clear();
    }
  }
}
```

**Nota:** La implementación requiere cuidado para no permitir reads de datos parcialmente escritos (dirty reads). El B-Tree ya es append-only, lo que facilita la implementación.

---

## ARCH-2: `QueryCache` es global a todas las instancias de `FastDB`

**Archivo:** [`fast_query.dart` L52](lib/src/query/fast_query.dart#L52)  
**Severidad:** 🔴 Alta (causa bugs en tests paralelos)

```dart
// PROBLEMA — campo estático compartido entre TODAS las instancias:
static final QueryCache _queryCache = QueryCache(maxSize: 256);
```

**Consecuencias:**
1. Si se usan múltiples instancias de `FastDB` (multi-tenant, microservicios, tests en paralelo), la cache de una instancia puede contaminar a otra.
2. En tests: `clearCache()` en un test afecta otras instancias corriendo en paralelo.
3. El `open()` llama `QueryBuilder.clearCache()` para limpiar al abrir una nueva DB, pero esto es un síntoma del problema, no la solución.

**Fix — mover cache a instancia:**
```dart
// En FastDB:
final QueryCache _queryCache = QueryCache(maxSize: 256);

QueryBuilder query() => QueryBuilder(
  _secondaryIndexes, 
  _findById, 
  _rangeSearch,
  cache: _queryCache, // ← pasar cache de instancia
);

void clearQueryCache() => _queryCache.clear();
```

**Impacto en tests:** Elimina la necesidad de `QueryBuilder.clearCache()` entre tests que usan instancias diferentes.

---

## ARCH-3: `FtsIndex` no escala en memoria para textos largos

**Archivo:** [`fts_index.dart` L29-L33](lib/src/index/fts_index.dart)  
**Severidad:** 🟡 Media

```dart
final Map<String, List<int>> _tokenIndex = {};    // todos los tokens
final Map<int, Set<String>> _docTokens = {};      // todos los tokens por doc
```

**Problemas:**
1. Para 100,000 documentos con textos de 500 palabras, `_docTokens` puede consumir **cientos de MB** en RAM.
2. Sin stopwords: "de", "la", "el" se indexan como tokens (miles de entradas, casi inútiles).
3. Sin stemming: "correr" y "corriendo" son tokens distintos.
4. `tokenize` usa `r'[^\w]+'` que no separa bien idiomas con acentos — "café" queda como token único porque "é" es `\w` en Unicode.

**Propuestas:**
```dart
class FtsIndex {
  // Config de tokenización:
  final Set<String> stopwords;
  final int maxTokensPerDoc; // límite para evitar documentos muy largos
  final int minTokenLength;  // ignorar tokens cortos ("de", "el")

  FtsIndex({
    this.stopwords = const {'de', 'la', 'el', 'en', 'a', 'y', 'o'},
    this.maxTokensPerDoc = 500,
    this.minTokenLength = 3,
  });

  List<String> tokenize(String text) {
    return text
        .toLowerCase()
        // Normalizar acentos: á→a, é→e, etc.
        .replaceAll(RegExp(r'[áàäâ]'), 'a')
        .replaceAll(RegExp(r'[éèëê]'), 'e')
        // ...
        .split(RegExp(r'[^\w]+'))
        .where((t) => t.length >= minTokenLength && !stopwords.contains(t))
        .take(maxTokensPerDoc)
        .toList();
  }
}
```

---

## ARCH-4: CRC32 implementado dos veces independientemente

**Archivos:** [`fastdb.dart` L1062-L1071](lib/src/fastdb.dart#L1062) y [`wal_storage_strategy.dart` L336-L345](lib/src/storage/wal_storage_strategy.dart)  
**Severidad:** 🟢 Baja (deuda técnica)

Las dos implementaciones CRC32 son **idénticas pero duplicadas**. Cualquier cambio (bug fix, optimización) en una no se refleja en la otra automáticamente.

**Fix — extraer a archivo compartido:**

```dart
// lib/src/_checksum.dart — NUEVO
library ffastdb._checksum;

/// CRC-32 checksum computation.
/// Shared between FastDB document verification and WAL integrity checks.
int computeCrc32(List<int> data) {
  int crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (int j = 0; j < 8; j++) {
      if (crc & 1 != 0) {
        crc = (crc >> 1) ^ 0xEDB88320;
      } else {
        crc >>= 1;
      }
    }
  }
  return (~crc) & 0xFFFFFFFF;
}
```

---

## ARCH-5: Serialización JSON anidada es O(n) por nivel con type detection costosa

**Archivo:** [`fast_serializer.dart`](lib/src/serialization/fast_serializer.dart)  
**Severidad:** 🟡 Media

El serializer usa `jsonEncode` + `utf8.encode` para documentos `Map`. Para documentos con arrays o mapas anidados, cada escritura/lectura recorre el grafo completo con duck-typing.

Los tres bloques `try/catch` para Firebase `Timestamp`, `GeoPoint`, `DocumentReference` se ejecutan para **cada valor** del documento, incluyendo `String`, `int`, `bool` que nunca son Firebase objects.

**Ver [PERFORMANCE.md — PERF-6](PERFORMANCE.md#perf-6) para el fix propuesto.**

---

## ARCH-6: `_dataOffset` puede quedar stale bajo concurrencia

**Archivo:** [`fastdb.dart` L100-L101](lib/src/fastdb.dart#L100)  
**Severidad:** 🟡 Media

```dart
if (dataStorage == null) {
  _dataOffset = storage.sizeSync ?? await storage.size;
}
```

`_dataOffset` se actualiza al inicio de cada `_exclusive()` call. Si el storage no soporta `sizeSync`, hace un async read **antes** de ejecutar la operación. Esto introduce una ventana donde el offset puede ser stale si múltiples operaciones se encolan antes de que el anterior termine de escribir.

El path de `put()` con `dataStorage != null` incrementa el offset manualmente sin verificar el tamaño real del archivo — esto puede causar escrituras superpuestas en edge cases.

**Propuesta:** Reemplazar `_dataOffset` por una función `_currentDataOffset()` que siempre lea el tamaño real del archivo de datos en uso, y usar una variable `_pendingDataBytes` para las escrituras en progreso dentro de una operación exclusiva.

---

## ARCH-7: No hay compactación incremental

**Archivo:** [`_storage_manager.dart`](lib/src/_storage_manager.dart)  
**Severidad:** 🟢 Baja (pero importante para producción)

`compact()` debe leer **todos** los documentos y reescribir el archivo completo. Para una DB de 1GB con solo 1% de documentos eliminados, esto implica:
- Leer y reescribir ~1GB de datos
- Bloquear todas las operaciones durante la compactación
- Sin posibilidad de progreso incremental

**Propuesta — compactación por rango (online compaction):**

Similar a SQLite's `VACUUM INTO`, procesar solo las páginas con alta fragmentación:

```dart
/// Compacta solo las páginas con más de [threshold] porcentaje de fragmentación.
/// Progresa en background sin bloquear reads.
Future<CompactionReport> compactIncremental({
  double pageFragmentThreshold = 0.5, // 50% de la página es basura
  int maxPagesPerRound = 100,          // limitar el trabajo por llamada
}) async {
  // 1. Identificar páginas con alta fragmentación
  // 2. Mover solo esas páginas, reescribir los offsets en el B-Tree
  // 3. Truncar el espacio liberado al final del archivo
}
```

---

## Resumen de Deuda Técnica

| # | Área | Descripción | Severidad | Esfuerzo |
|---|------|-------------|-----------|----------|
| ARCH-1 | Concurrencia | Reads serializados detrás de writes | 🟡 Alta | Alto |
| ARCH-2 | Estado global | `QueryCache` estático entre instancias | 🔴 Alta | Bajo |
| ARCH-3 | FTS Memory | Sin stopwords ni límite de tokens | 🟡 Media | Medio |
| ARCH-4 | Duplicación | CRC32 duplicado en 2 archivos | 🟢 Baja | Muy bajo |
| ARCH-5 | Serialización | try/catch por cada valor del doc | 🟡 Media | Bajo |
| ARCH-6 | Concurrencia | `_dataOffset` puede quedar stale | 🟡 Media | Medio |
| ARCH-7 | Storage | Sin compactación incremental | 🟢 Baja | Alto |

---

## Plan de Acción Priorizado

### Inmediato (< 1h, sin riesgos)
1. **ARCH-4**: Extraer CRC32 a `_checksum.dart` — refactoring puro, tests existentes verifican corrección.
2. **ARCH-2**: Mover `QueryCache` de `static` a campo de instancia — 5 líneas de cambio.

### Corto plazo (1-4h)
3. **ARCH-5**: Agregar fast path en `_toEncodable` para tipos primitivos.
4. **ARCH-3**: Agregar stopwords y `minTokenLength` a `FtsIndex`.

### Medio plazo (1-2 días)
5. **ARCH-1**: Implementar R/W Lock para reads concurrentes.
6. **ARCH-6**: Refactorizar `_dataOffset` para eliminar la ventana de inconsistencia.

### Largo plazo (1+ semanas)
7. **ARCH-7**: Compactación incremental con progreso.
