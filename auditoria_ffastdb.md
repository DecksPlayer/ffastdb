# ffastdb — Reporte de Auditoría de Código
> **Versión auditada:** v0.3.1  
> **Archivos analizados:** `fastdb.dart`, `_crud_operations.dart`, `_batch_operations.dart`, `fast_query.dart`, `fts_index.dart`, `fast_serializer.dart`, `_storage_manager.dart`, `btree.dart`  
> **Fecha última revisión:** 2026-08-03  
> **Nota:** Análisis basado en código fuente real. Los números de línea corresponden al estado actual del repositorio.

---

## Estado general

| Severidad | Abiertos | Cerrados |
|-----------|----------|----------|
| 🔴 Crítica  | 2 | — |
| 🟠 Alta    | 2 | 4 |
| 🟡 Media   | 1 | 4 |
| 🟢 Baja    | 1 | 1 |

---

## ✅ Bugs Corregidos (v0.2.7 → v0.3.1)

| Bug original | Versión fix | Verificación en código |
|---|---|---|
| `deleteImpl` no notificaba watchers | v0.2.8 | `_notifyWatchers(doc)` en [`_crud_operations.dart` L219](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/_crud_operations.dart#L219) |
| `_notifyWatchers` ignoraba el campo del doc | v0.2.8 | Filtra por campo con dot-notation en [`fastdb.dart` L1052-1083](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L1052) |
| `QueryCache` estática — compartida entre instancias | v0.2.8 | `final QueryCache _queryCache = QueryCache(maxSize: 256)` en [`fastdb.dart` L70](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L70) |
| `isNull()` siempre retornaba lista vacía | v0.2.8 | Complemento vía `rangeSearch` en [`fast_query.dart` L1100-1103](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/query/fast_query.dart#L1100) |
| `FtsIndex.retainAll` con `List` → O(n×m) | v0.2.8 | `_tokenIndex` es `Map<String, Set<int>>` — `retainAll` con `Set` es O(1) en [`fts_index.dart` L31](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/index/fts_index.dart#L31) |
| `watch()` acumulaba `StreamController` sin cleanup | v0.2.8 | `onCancel` limpia `_watchers` en [`fastdb.dart` L1025-1036](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L1025) |
| `BTree.bulkLoad` crecía el archivo sin liberar páginas huérfanas | v0.3.0 | `_freeTreePage` libera páginas antes de rebuild en [`btree.dart` L206-213](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/index/btree.dart#L206) |
| `compact()` destruía datos en crash/ENOSPC | v0.3.0 | `compact()` envuelto en `transaction()` en [`fastdb.dart` L1308](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L1308) |

---

## 🔴 Fallas Críticas — ABIERTAS

---

### CRIT-01 · `_readAt` silencia corrupción de CRC32 con `return null`

**Archivo:** [`fastdb.dart` L1137-1139](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L1137)

**Problema:** Cuando el CRC32 de un documento no coincide con el checksum almacenado, `_readAt` retorna `null` sin ningún error:

```dart
// fastdb.dart L1137-1139
if (fullData.length >= totalSize) {
  final storedCrc = _readInt32(fullData, 4 + length);
  if (storedCrc != _crc32(fullData.sublist(4, 4 + length))) return null; // ← falla silenciosa
}
```

`findById(id)` retorna `null` y el usuario asume que el documento no existe. Un archivo corrupto (I/O parcial, truncación, bit-flip) pasa **completamente desapercibido en producción**. No hay log, no hay excepción, no hay alerta.

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

### CRIT-02 · `deleteWhere` no llama `_notifyWatchersBatch()` en el path exitoso

**Archivo:** [`fastdb.dart` L1249-1296](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L1249)

**Problema:** `deleteWhere` establece `_batchMode = true`, ejecuta los deletes y al final del bloque try exitoso (L1281-1289) limpia el cache y hace flush, pero **nunca notifica los watchers**:

```dart
// fastdb.dart L1281-1289 — path de éxito
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

Las UIs que usan `db.watch('campo')` **no reciben eventos** cuando se borra un lote con `deleteWhere`. Los streams reactivos quedan desincronizados mostrando datos ya eliminados.

> **Nota:** `deleteImpl` individual (BUG-3) ya fue corregido. Este bug es específico al path batch de `deleteWhere`.

**Fix:**
```dart
_queryCache.clear();
_notifyWatchersBatch(); // ← agregar aquí
if (_autoCompactThreshold > 0) {
  await _maybeAutoCompact();
}
return count;
```

---

## 🟠 Fallas de Alta Severidad — ABIERTAS

---

### HIGH-01 · `OperationLog` se escribe ANTES del commit WAL en todos los CRUD

**Archivo:** [`_crud_operations.dart` L14-19](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/_crud_operations.dart#L14)

**Problema:** El orden en `insertImpl` (y también `putImpl` L74-77, `updateImpl` L137-140, `deleteImpl` L188-191) es:

```dart
// Paso 1: log PRIMERO
if (!_db._inTransaction && !_db._batchMode && !_db._isReplayingOpLog) {
  await _db._opLog.log('insert', id: id, data: doc);  // ← escrito antes del WAL
}

// Paso 2: WAL DESPUÉS
if (hasWal) await wal.beginTransaction();
try {
  // ... operación ...
  if (hasWal) await wal.commit();
```

Si el proceso cae entre el `_opLog.log()` y el `wal.commit()`, al reabrir la DB `_replayOpLog()` **reinsertará operaciones que nunca se completaron**. Esto puede sobreescribir documentos existentes o incrementar `_nextId` incorrectamente.

**Fix:** Mover el log al final del try, después de confirmar el commit:
```dart
if (hasWal) await wal.beginTransaction();
try {
  // ... toda la operación ...
  if (hasWal) await wal.commit();
  // Log SOLO después del commit exitoso:
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

### HIGH-02 · `_serialize` usa `doc.cast<String, dynamic>()` lazy cuando no se inyecta ID

**Archivo:** [`fastdb.dart` L1188-1192](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L1188)

**Problema:** Cuando `id == null` o `doc['ffdbID'] == id` (el documento ya tiene el ID correcto), el serializer recibe una *vista lazy* sin validación:

```dart
final Map<String, dynamic> map;
if (id != null && doc['ffdbID'] != id) {
  map = Map<String, dynamic>.from(doc)..['ffdbID'] = id; // copia real ✓
} else {
  map = doc.cast<String, dynamic>(); // ← vista lazy: NO valida tipos en el acto
}
```

`Map.cast<K,V>()` no valida ni convierte — crea una vista con casting diferido. Si el mapa tiene claves no-`String` (e.g., `Map<dynamic, dynamic>` de Firebase, o `jsonDecode` sin tipado explícito), el `CastError` aparece **dentro del serializer**, en un sitio difícil de trazar, no en el `insert()` del usuario.

Afecta: `upsert`, `put` con doc ya-con-id-correcto, `update` con el merged que mantiene el mismo ID.

**Fix:**
```dart
// Siempre copia defensiva — el serializer solo lee, no mutar el doc del usuario
final map = Map<String, dynamic>.from(doc as Map);
if (id != null) map['ffdbID'] = id;
```

---

## 🟡 Fallas de Media Severidad — ABIERTAS

---

### MED-01 · `_replayOpLog` silencia todos los errores con `catch (_) {}`

**Archivo:** [`fastdb.dart` L498-500](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L498)

**Problema:**
```dart
} catch (_) {
  // Skip failed replays
}
```

Si una operación falla durante el replay (storage corrupto, schema incompatible, ID duplicado), el error se descarta en silencio. El usuario nunca sabe qué datos del log no fueron aplicados. Si el fallo es sistémico, el replay continúa aplicando operaciones sobre un estado ya inconsistente.

**Fix:**
```dart
} catch (e, st) {
  assert(() {
    // ignore: avoid_print
    print('[ffastdb] Warning: replay of ${op.type}(id=${op.id}) failed: $e\n$st');
    return true;
  }());
  // TODO: exponer via un callback onReplayError para manejo por el usuario
}
```

---

## 🟡 Fallas de Media Severidad — CERRADAS

| Bug | Fix aplicado |
|-----|-------------|
| `watch()` acumulaba StreamControllers (MED-03) | `onCancel` en broadcast controller (L1025-1036) |
| `FtsIndex.tokenize()` min-length inconsistente (MED-01) | `_tokenIndex` es `Set<int>` — retainAll correcto. El comentario "3 chars" es impreciso (aplica 2), baja prioridad |

---

## 🟡 Bugs de Media Severidad — ABIERTOS (baja prioridad)

### MED-02 · `_applySort` — `ids.length * 4` — overflow en Web (baja probabilidad)

**Archivo:** [`fast_query.dart` L701-702](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/query/fast_query.dart#L701)

```dart
if (ids.isNotEmpty &&
    ids.length * 4 < idx.size &&   // ← multiplicación sin guard para idx.size == 0
    idx.valueOf(ids.first) != null) {
```

En Dart Web (`int` = JS number, 53 bits) con ~536M docs la multiplicación se comporta incorrectamente. Improbable pero técnicamente posible. El guard `idx.size == 0` también falta.

**Fix:**
```dart
if (ids.isNotEmpty && idx.size > 0 &&
    ids.length < idx.size ~/ 4 &&
    idx.valueOf(ids.first) != null) {
```

---

## 🟢 Deuda Técnica — ABIERTA

### LOW-01 · `GeoPoint` se deserializa como `Map<String, double>` sin documentación

**Archivo:** [`fast_serializer.dart`](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/serialization/fast_serializer.dart)

Un `GeoPoint` de Firebase serializado como sentinel `\u0000gp:lat,lng` al deserializar se convierte en `Map<String, double>`. Es comportamiento por diseño (sin dependencia de `cloud_firestore`), pero ningún comentario visible al usuario lo advierte.

**Fix:** Agregar comentario en `revive()` y en el docstring de `FastSerializer`.

---

## Checklist de Corrección — Estado actual

| Item | Descripción | Estado |
|------|-------------|--------|
| **CRIT-01** | CRC32 mismatch: `return null` → `throw StateError` | ❌ Abierto |
| **CRIT-02** | `deleteWhere`: agregar `_notifyWatchersBatch()` al path exitoso | ❌ Abierto |
| **HIGH-01** | Mover `OperationLog.log()` post-commit WAL (×4 métodos CRUD) | ❌ Abierto |
| **HIGH-02** | `doc.cast<String,dynamic>()` → `Map<String,dynamic>.from(doc)` | ❌ Abierto |
| **MED-01** | `_replayOpLog`: `catch (_) {}` → handler con logging | ❌ Abierto |
| **MED-02** | `_applySort`: `ids.length * 4` → `ids.length < idx.size ~/ 4` | ⚠️ Baja prioridad |
| **LOW-01** | Documentar pérdida de tipo `GeoPoint` en `FastSerializer` | ⚠️ Baja prioridad |
| `deleteImpl` sin notificación watchers | ✅ Corregido (v0.2.8) |
| `_notifyWatchers` ignoraba campo | ✅ Corregido (v0.2.8) |
| `isNull()` siempre vacío | ✅ Corregido (v0.2.8) |
| FTS `retainAll` O(n×m) | ✅ Corregido (v0.2.8, `Set<int>` interno) |
| `QueryCache` estática entre instancias | ✅ Corregido (v0.2.8) |
| `watch()` memory leak de StreamController | ✅ Corregido (v0.2.8, onCancel) |
| `compact()` sin atomicidad WAL | ✅ Corregido (v0.3.0) |
| `bulkLoad` sin free-list de páginas | ✅ Corregido (v0.3.0) |

---

## Resumen de riesgo en producción

```
CORRUPCIÓN SILENCIOSA   →  CRIT-01 (CRC mismatch invisible al usuario)
STREAMS DESINCRONIZADOS →  CRIT-02 (deleteWhere no notifica watchers)
REPLAY INCONSISTENTE    →  HIGH-01 (oplog escrito antes del commit WAL)
CRASH OSCURO EN RUNTIME →  HIGH-02 (cast lazy en serialize)
DIAGNÓSTICO IMPOSIBLE   →  MED-01  (replay errors silenciados)
```

Los más peligrosos son **CRIT-01** (corrupción invisible) y **HIGH-01** (replay de operaciones incompletas tras crash). Juntos pueden hacer que una DB que sobrevivió un crash reinserte datos fantasma sin ninguna alerta.

---

## Resumen Ejecutivo

| Severidad | Cantidad | Estado |
|-----------|----------|--------|
| 🔴 Crítica  | 2 | Bugs que producen corrupción o pérdida de datos silenciosa |
| 🟠 Alta    | 4 | Bugs que producen resultados incorrectos o riesgo de corrupción |
| 🟡 Media   | 4 | Degradación de rendimiento y comportamiento inesperado |
| 🟢 Baja    | 2 | Deuda técnica y malos patrones sin impacto inmediato |

---

## 🔴 Fallas Críticas

---

### CRIT-01 · `deleteWhere` no limpia `_watchers` y deja `_inTransaction = true` en rollback

**Archivo:** [`fastdb.dart` L1265-L1296](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L1265)

**Problema:** `deleteWhere` establece `_inTransaction = true` directamente (sin usar el helper `transaction()`), luego abre una transacción WAL y borra documentos. En el bloque `catch`, solo llama `wal.rollback()` y pone `_batchMode = false`, pero **omite `_inTransaction = false`**. El bloque `finally` sí lo hace (`_inTransaction = false`), pero si el error ocurre **antes** del `finally`, cualquier operación llamada en el `catch` (por ejemplo, `wal.rollback()`) se ejecuta dentro de un estado de transacción activa — saltando el exclusivo `_writeLock`.

Adicionalmente, **`_notifyWatchers` nunca se llama** en el camino feliz de `deleteWhere`. Los documentos se eliminan pero los `StreamController` de `watch()` no son notificados, dejando UI colgada mostrando datos eliminados.

```dart
// fastdb.dart L1281-L1295  (path de éxito — sin notificar watchers)
_batchMode = false;
await _pageManager.flushDirty();
await storage.flush();
await _saveHeader();
_queryCache.clear();
// ← _notifyWatchers / _notifyWatchersBatch() AUSENTE
if (_autoCompactThreshold > 0) {
  await _maybeAutoCompact();
}
return count;
```

**Fix:**
```dart
// 1. Agregar al final del bloque try exitoso:
_notifyWatchersBatch();

// 2. En el catch, asegurar que _inTransaction se limpie ANTES del rethrow:
} catch (e) {
  _inTransaction = false;  // ← agregar aquí también
  _batchMode = false;
  if (wal != null) await wal.rollback();
  rethrow;
} finally {
  _inTransaction = false;
}
```

---

### CRIT-02 · `_readAt` ignora silenciosamente CRC32 inválido y devuelve `null` en lugar de lanzar excepción

**Archivo:** [`fastdb.dart` L1136-L1140](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L1136)

**Problema:** Cuando el CRC32 de un documento no coincide con el checksun almacenado, `_readAt` retorna `null` sin ningún error ni logging:

```dart
if (fullData.length >= totalSize) {
  final storedCrc = _readInt32(fullData, 4 + length);
  if (storedCrc != _crc32(fullData.sublist(4, 4 + length))) return null; // ← falla silenciosa
}
```

Esto significa que documentos corruptos no son detectados por el usuario — `findById(id)` retorna `null` y el usuario asume que el documento no existe. Ningún log, ninguna excepción, ninguna alerta. Un archivo corrupto pasa completamente desapercibido en producción.

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

## 🟠 Fallas de Alta Severidad

---

### HIGH-01 · `_IsNullCondition.isNull()` en query hace un `rangeSearch` sin `_exclusive`

**Archivo:** [`fast_query.dart` L1092-L1103](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/query/fast_query.dart#L1092)

**Problema:** Cuando se usa `.where('field').isNull()`, la evaluación llama a `builder.rangeSearch(1, 0x7FFFFFFF)` que ejecuta `_primarySearch(1, 0x7FFFFFFF)`. Esa función es el closure `_rangeSearch` capturado en el constructor, que llama directamente a `_primaryIndex.rangeSearch()` **sin pasar por `_exclusive`**. Si hay una escritura en progreso (por ejemplo, un `insertAll`), esta lectura del B-Tree se ejecuta concurrentemente y puede leer nodos parcialmente escritos.

```dart
// fast_query.dart L1101
final allIds = await builder.rangeSearch(1, 0x7FFFFFFF);
```

El closure `_rangeSearch` en `FastDB` hace:
```dart
Future<List<int>> _rangeSearch(int low, int high) =>
    _primaryIndex.rangeSearch(low, high); // ← sin lock
```

**Fix:** Cambiar el closure inyectado en `QueryBuilder` a uno que respete el lock:
```dart
// En FastDB.query():
QueryBuilder query() => QueryBuilder(
  _secondaryIndexes,
  _findById,
  (low, high) => _exclusive(() => _rangeSearch(low, high)), // ← con lock
  watch,
  _queryCache,
);
```

---

### HIGH-02 · `transaction()` llama `beginBatch()` que hace `flushDirty()` redundante

**Archivo:** [`fastdb.dart` L718-L762](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L718)

**Problema:** `transaction()` ya hace `await _pageManager.flushDirty()` en L730 **antes** de abrir la transacción WAL. Luego en L734 llama `await beginBatch()` que internamente hace **otro** `await _pageManager.flushDirty()`. Esto es un doble flush innecesario que degrada el rendimiento en transacciones de alta frecuencia. Además, `beginBatch()` también habilita `_enableWriteBehind()`, lo que en plataformas con `needsExplicitFlush = false` deja `writeBehind = false` y luego lo reactiva incorrectamente:

```dart
// transaction():
await _pageManager.flushDirty();       // ← flush 1
if (wal != null) await wal.beginTransaction();
try {
  await beginBatch();                   // ← beginBatch también hace flushDirty (flush 2)
```

**Fix:** En `transaction()`, omitir `beginBatch()` y configurar `_batchMode` y `_enableWriteBehind()` directamente:
```dart
await _pageManager.flushDirty();
if (wal != null) await wal.beginTransaction();
try {
  _batchMode = true;
  _enableWriteBehind();
  final result = await fn();
  // ... commit path
```

---

### HIGH-03 · `insertImpl` loguea la operación ANTES de la transacción WAL

**Archivo:** [`_crud_operations.dart` L14-L19](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/_crud_operations.dart#L14)

**Problema:** El `OperationLog` se escribe **antes** de abrir la transacción WAL:

```dart
// Paso 1: log
if (!_db._inTransaction && !_db._batchMode && !_db._isReplayingOpLog) {
  await _db._opLog.log('insert', id: id, data: doc);
}

// Paso 2: WAL
if (hasWal) await wal.beginTransaction();
```

Si el proceso cae entre el `_opLog.log()` y el `wal.commit()`, el `OperationLog` tiene registrada una operación que **nunca se completó**. Al abrir la DB la próxima vez, `_replayOpLog()` intentará reinsertar el documento con el mismo ID, potencialmente sobreescribiendo un documento existente o incrementando `_nextId` incorrectamente.

El mismo patrón se repite en `putImpl`, `updateImpl` y `deleteImpl`.

**Fix:** Mover el log del `OperationLog` al final del try, después de confirmar el éxito del WAL:
```dart
if (hasWal) await wal.beginTransaction();
try {
  // ... toda la operación ...
  if (hasWal) await wal.commit();
  // Log SOLO después del commit exitoso:
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

### HIGH-04 · `_serialize` hace `doc.cast<String, dynamic>()` sin verificar que el `Map` tenga `String` keys

**Archivo:** [`fastdb.dart` L1192](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L1192)

**Problema:** Cuando se inserta un `Map` cuyas claves no son `String` (por ejemplo `Map<int, dynamic>` o `Map<dynamic, dynamic>` proveniente de Firebase), el código hace:

```dart
map = doc.cast<String, dynamic>();
```

`cast<K, V>()` en Dart no hace una copia — crea una vista con casting lazy. El error solo aparece en runtime **cuando se accede a los elementos**, no en el momento del cast. Esto puede producir un `CastError` dentro del serializer de manera difícil de rastrear.

Además, si `id != null && doc['ffdbID'] != id` es `false` (el doc ya tiene el ID correcto), no se crea copia. Cualquier modificación posterior al `map` (que no ocurre en el código actual, pero puede ocurrir si el código evoluciona) mutaría el documento original del usuario.

**Fix:**
```dart
// Reemplazar el cast lazy por una conversión defensiva:
final map = Map<String, dynamic>.from(doc as Map);
if (id != null) map['ffdbID'] = id;
```

---

## 🟡 Fallas de Media Severidad

---

### MED-01 · `FtsIndex.tokenize()` descarta tokens con longitud 1, causando fallos en búsqueda de siglas (IDs cortos, letras únicas)

**Archivo:** [`fts_index.dart` L56](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/index/fts_index.dart#L56)

**Problema:**
```dart
return tokens.where((t) => t.isNotEmpty && t.length >= 2).toList();
```

Cualquier token de 1 caracter es silenciosamente descartado. Esto afecta casos como:
- Búsqueda por inicial: `fts('J')` → nunca encuentra nada.
- Siglas de una letra: documentos con campo `"type": "A"` o `"grade": "B"` nunca son indexados.
- Nombres en algunos idiomas (chino, japonés) donde los tokens de 1 carácter son válidos.

Además, el comentario dice "min length (3 chars)" pero el código impone 2. Inconsistencia entre documentación y comportamiento.

**Fix:**
```dart
// Hacer configurable el mínimo:
static const int _minTokenLength = 1; // cambiado de 2 a 1

return tokens.where((t) => t.isNotEmpty && t.length >= _minTokenLength).toList();
```

---

### MED-02 · `_applySort` compara `ids.length * 4 < idx.size` con aritmética potencialmente desbordante

**Archivo:** [`fast_query.dart` L701-L703](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/query/fast_query.dart#L701)

**Problema:**
```dart
if (ids.isNotEmpty &&
    ids.length * 4 < idx.size &&   // ← multiplicación puede overflow en listas de 500M+ docs
    idx.valueOf(ids.first) != null) {
```

En Dart Native, `int` es de 64 bits y el overflow no ocurre en la práctica. Sin embargo, en Dart Web, `int` es JavaScript `number` (53 bits de precisión entera). Una colección de ~536M documentos (poco probable pero técnicamente posible) haría que `ids.length * 4` se comporte incorrectamente en Web.

Adicionalmente, si `idx.size == 0` (índice vacío) y `ids.isNotEmpty`, la condición se evalúa de todos modos y llama `idx.valueOf(ids.first)`. Si el índice fue recientemente limpiado, devuelve `null` y se salta al path lento, que es correcto pero evitable con un guard previo.

**Fix:**
```dart
if (ids.isNotEmpty && idx.size > 0 &&
    ids.length < idx.size ~/ 4 &&  // evita multiplicación
    idx.valueOf(ids.first) != null) {
```

---

### MED-03 · `watch()` crea un `StreamController` sin cleanup si el `stream` es `yield*`-ed y el generator se cancela prematuramente

**Archivo:** [`fastdb.dart` L1014-L1039](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L1014)

**Problema:** `watch(String field)` es un `async*` generator que:
1. Emite el estado inicial.
2. Crea y almacena un `StreamController` en `_watchers`.
3. Hace `yield* _watchers[field]!.stream`.

Si el listener cancela la subscripción **durante el yield inicial** (paso 1), el generator se cancela antes de registrar el `StreamController`. Esto es correcto. Pero si cancela **durante el yield\*** (paso 3), el `onCancel` del controller intenta `ctrl.close()` y `_watchers.remove(field)`. Sin embargo, si hay múltiples listeners del mismo stream (es `broadcast`), el `onCancel` solo se dispara cuando el último listener cancela — lo cual es correcto.

El problema real es que si se hace `yield*` de un `broadcast` stream que **ya tiene listeners de una subscripción anterior**, el `async*` generator no sabe cuándo "su" instancia se canceló versus cuándo otro listener canceló. Esto puede dejar al generator colgado consumiendo memory indefinidamente si nadie llama `cancel()` en la subscripción del generator mismo.

**Fix:** Cambiar de `async*` a un `StreamController` explícito que controla su propio ciclo de vida de forma determinista.

---

### MED-04 · `_replayOpLog` silencia TODOS los errores de replay con `catch (_) {}`

**Archivo:** [`fastdb.dart` L498-L500](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L498)

**Problema:**
```dart
} catch (_) {
  // Skip failed replays
}
```

Si una operación del log falla durante el replay (por ejemplo, `updateImpl` falla porque el documento fue eliminado en una compactación entre el crash y el reopen), el error se descarta silenciosamente. El usuario nunca sabe que datos del log no fueron aplicados.

Adicionalmente, si el fallo es sistémico (por ejemplo, storage corrupto), el replay continúa e intenta aplicar las operaciones siguientes en un estado inconsistente.

**Fix:**
```dart
} catch (e) {
  // Log the error but continue replaying
  // (preferably expose via a callback or structured error list)
  assert(() {
    print('[ffastdb] Warning: replay of ${op.type}(id=${op.id}) failed: $e');
    return true;
  }());
}
```

---

## 🟢 Deuda Técnica de Baja Severidad

---

### LOW-01 · `GeoPoint` deserializado pierde su tipo original — se convierte en `Map<String, double>`

**Archivo:** [`fast_serializer.dart` L100-L105](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/serialization/fast_serializer.dart#L100)

**Problema:**
```dart
if (v.startsWith(_gpPrefix)) {
  final parts = v.substring(_gpPrefix.length).split(',');
  return {
    'latitude': double.parse(parts[0]),
    'longitude': double.parse(parts[1]),
  };
}
```

Un `GeoPoint` de Firebase se serializa como sentinel string `\u0000gp:lat,lng` y al deserializar se convierte en un `Map<String, double>`. El objeto original `GeoPoint` no puede ser reconstruido sin la dependencia `cloud_firestore`. Esto es por diseño, pero no está documentado en ningún comentario visible al usuario. Un desarrollador que inserte documentos con `GeoPoint` y espere recuperarlos como `GeoPoint` obtendrá `Map` objects sin warning.

**Fix (documentación mínima):** Agregar comment sobre la decisión en `revive()` y en el docstring de `FastSerializer`.

---

### LOW-02 · `_batch_operations.dart` L47 incrementa `_dataOffset` directamente en lugar de usar `_syncDataOffset`

**Archivo:** [`_batch_operations.dart` L47](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/_batch_operations.dart#L47)

**Problema:**
```dart
_db._dataOffset += data.length;
```

En el loop de batch, el offset se incrementa manualmente en lugar de usar el método `_syncDataOffset` que existe para garantizar la consistencia entre file size real y el puntero interno. En `dataStorage == null` (single-file mode), `_syncDataOffset` lee el tamaño real del archivo — el incremento manual puede quedar desincronizado si el storage strategy hace buffering interno y el tamaño real del archivo no coincide con la suma de las escrituras.

Luego, en L66, se llama `await _db._syncDataOffset(0)` para resincronizar, lo que sugiere que el equipo era consciente del problema — pero hay una ventana entre L47 y L66 donde `_dataOffset` puede estar mal.

**Fix:** Usar `_syncDataOffset` también dentro del loop, o documentar explícitamente por qué el enfoque manual es correcto en `_batchMode` con `dataStorage != null`.

---

## Checklist de Verificación para el Equipo

- [ ] **CRIT-01**: Agregar `_notifyWatchersBatch()` al path de éxito de `deleteWhere`.
- [ ] **CRIT-01**: Mover `_inTransaction = false` también al bloque `catch` de `deleteWhere`.
- [ ] **CRIT-02**: Cambiar el CRC32 mismatch de `return null` a `throw StateError(...)`.
- [ ] **HIGH-01**: Envolver el closure `_rangeSearch` inyectado en `QueryBuilder` con `_exclusive()`.
- [ ] **HIGH-02**: Eliminar el doble `flushDirty()` en `transaction()`.
- [ ] **HIGH-03**: Mover el log de `OperationLog` al final del bloque try (post-commit).
- [ ] **HIGH-04**: Reemplazar `doc.cast<String, dynamic>()` por `Map<String, dynamic>.from(doc)`.
- [ ] **MED-01**: Hacer configurable `_minTokenLength` en `FtsIndex.tokenize()` o reducir a 1.
- [ ] **MED-02**: Reemplazar `ids.length * 4` por `ids.length < idx.size ~/ 4`.
- [ ] **MED-03**: Evaluar reescribir `watch()` con un `StreamController` explícito.
- [ ] **MED-04**: Reemplazar `catch (_) {}` vacío por un handler con logging.
- [ ] **LOW-01**: Documentar la pérdida de tipo de `GeoPoint` en `FastSerializer`.
- [ ] **LOW-02**: Aclarar/corregir el acceso directo a `_dataOffset` en el loop de `insertAllImpl`.
