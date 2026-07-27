# FIX_PLAN — Análisis de bugs y plan de corrección de ffastdb

> Auditoría completa del código fuente de `ffastdb` v0.2.7+ y plan de corrección aprobado.
> Fecha: 2026-07-27 · Metodología: revisión estática de todo `lib/` + verificación empírica con probes ejecutables.

---

## 1. Resumen ejecutivo

- **~60 hallazgos**: 6 críticos (corrupción/pérdida de datos), 15 altos, ~20 medios, resto bajos/rendimiento.
- **6 bugs confirmados empíricamente** con probes ejecutables antes de tocar código.
- **Baseline de tests**: 118 tests, **2 fallos preexistentes** que son bugs reales y entran en el plan:
  - `upsert y upsertWhere (API-1)`: `upsert(10, ...)` devuelve id `1` en vez de `10` (ignora el id manual).
  - `watchDocs y QueryBuilder.watch() (API-3 & API-4)`: emite 4 eventos en vez de 3 (doble emisión inicial).
- Los bugs listados en `BUGS.md`/`CLAUDE.md` como "conocidos" están en gran parte **ya corregidos** en el código actual (ver §7).

---

## 2. Verificación empírica (probes ejecutados)

| Probe | Resultado | Veredicto |
|-------|-----------|-----------|
| A. `insertAll` de 229 docs → `getAll()` / `rangeSearch(1, 229)` | Devuelve **228**, falta el id 229. Igual con N=458. Con N=228/230 no falla | 🔴 **CONFIRMADO** — off-by-one en `BTree._rangeNode` |
| B. Query `where('age').equals(30)` sin índice en `age` | Devuelve **0 docs** (la condición se descarta en silencio) | 🔴 **CONFIRMADO** |
| C. Dos instancias `FastDB` distintas, misma query textual | db2 (vacía) recibe **los resultados de db1** | 🔴 **CONFIRMADO** — `QueryCache` estática compartida |
| D. `put(0, doc)` → `getAll()` | El documento es **invisible** (las queries empiezan en id 1) | 🔴 **CONFIRMADO** |
| E. `BufferedStorageStrategy.commit()` con escrituras solapadas contenidas | Los bytes más recientes **se descartan** (`write(0,[1×8]) + write(2,[9,9])` → `[1×8]`) | 🔴 **CONFIRMADO** (probe de la auditoría de storage) |
| F. `PageManager`: página dirty obsoleta + write-through + `flushDirty()` | La página **antigua sobrescribe** a la nueva | 🔴 **CONFIRMADO** (probe de la auditoría de storage) |
| G. `EncryptedStorageStrategy(WalStorageStrategy(...))` | `FastDB._wal` no desenvuelve capas → **sin transacciones WAL**, 3 mini-txs por insert, ~2.5× fsyncs | 🔴 **CONFIRMADO** (probe de la auditoría de storage) |
| H. WAL single-file: `findById` dentro de `transaction()` de un doc creado en la misma tx | Devuelve **null** (no hay read-your-writes) | 🟠 **CONFIRMADO** (probe de la auditoría de storage) |

---

## 3. Hallazgos detallados

Convención: `F<fase>.<n>` — la fase indica el orden de corrección aprobado.

### FASE 1 — CRÍTICOS (corrupción / pérdida de datos)

| ID | Sev | Archivo:Línea | Problema | Fix |
|----|-----|---------------|----------|-----|
| F1.1 | 🔴 | `btree.dart:~604` | `rangeSearch` pierde claves cuando `keys.last == high` (rango inclusivo). El hijo derecho contiene claves `>= keys.last` pero solo se desciende si `< high`. Afecta a `getAll`, `count`, `reindex`, `compact`, watchers y migraciones | `node.keys.last < high` → `<= high` |
| F1.2 | 🔴 | `buffered_storage_strategy.dart:86-94` | Coalescing descarta escrituras más recientes totalmente contenidas en una anterior → corrupción silenciosa | Fusionar siempre que haya solape: copiar `next` sobre `cur` incluso contenida |
| F1.3 | 🔴 | `page_manager.dart:73-99` + `fastdb.dart:624` + `_batch_operations.dart:86` | Write-through no limpia `_dirtyPages`; una página dirty obsoleta sobrescribe el dato nuevo en el próximo `flushDirty()`. Los catch de `updateWhere`/`insertAll` dejan dirty pages de un batch fallido que eluden el rollback del WAL | `_dirtyPages.remove(pageIndex)` en la rama write-through; `clearDirtyPages()` + `clearLruCache()` en los catch |
| F1.4 | 🔴 | `fastdb.dart:126-127` | `_wal` = `storage is WalStorageStrategy` falla con `Encrypted(WAL)` → sin transacciones, atomicidad rota, ~2.5× fsyncs | Desenvolver capas recursivamente (Encrypted→WAL→IO), igual que el bucle de `logPath` |
| F1.5 | 🔴 | `fast_query.dart:57` | `_queryCache` es `static`: compartida entre TODAS las instancias de FastDB. La clave no incluye identidad de la DB → contaminación cruzada de resultados entre bases de datos (confirmado: db2 vacía recibe resultados de db1) | Mover a campo de instancia de `FastDB`, inyectado al `QueryBuilder` |
| F1.6 | 🔴 | `fast_query.dart:439-440` | Condición sobre campo sin índice: `continue` la descarta. Query con 1 condición sin índice → `[]`; con varias → superconjunto incorrecto. `explain()` promete full-scan que no existe. Además: si la 1ª condición ordenada por el CBO no tiene índice, `groupResult!` en la iteración siguiente **lanza null-check** | Full-scan con filtrado en memoria vía `_primarySearch` + `_fetchById` (decisión aprobada); reestructurar el bucle para trackear "primera condición evaluada" |

### FASE 2 — ALTOS (durabilidad / consistencia)

| ID | Sev | Archivo:Línea | Problema | Fix |
|----|-----|---------------|----------|-----|
| F2.1 | 🟠 | `wal_storage_strategy.dart:255` | `read()` ignora `_txEntries`: dentro de una transacción no se leen las escrituras propias pendientes (confirmado: `findById` de doc nuevo en tx → null) | Superponer `_txEntries` (última escritura gana) sobre `_main.read` |
| F2.2 | 🟠 | `_crud_operations.dart:186-190` | `delete()` nunca hace `flush()` en storages con `needsExplicitFlush` (web/IndexedDB) → borrado no durable | Añadir flush simétrico a insert/update |
| F2.3 | 🟠 | `_crud_operations.dart:37-41, 93-96, 145-148` | `_saveHeader()` se llama DESPUÉS de `flush()` sin flush posterior → header (`rootPage`, `nextId`) queda en RAM; un cierre sucio deja docs persistidos pero inalcanzables | Guardar header ANTES del flush |
| F2.4 | 🟠 | `indexed_db_strategy.dart:219-226, 63-65, 128` | `_dirtyChunks` se limpian antes de que la txn IDB termine (si falla, no se reintentan). Error de carga → "start fresh" → el siguiente flush **sobrescribe los datos buenos** | Limpiar dirty en `oncomplete`; propagar error de carga / inhibir flush si la carga falló |
| F2.5 | 🟠 | `fast_query.dart:253-294` | Clave de caché con colisiones: `equals(1)` y `equals('1')` generan la misma clave; `isIn([1,23])` colisiona con `isIn(["1, 23"])`; separadores sin escapar | Incluir `value.runtimeType` y codificar valores con length-prefix |
| F2.6 | 🟠 | `sorted_index.dart:152-156`, `query_cache.dart:24-32`, `bitmask_index.dart:131-136` | Aliasing: `SortedIndex.lookup` devuelve `Uint32List.sublistView` (vista viva del buffer interno) que el hot-path cachea y retorna; `QueryCache.get` devuelve la lista interna mutable; `BitmaskIndex.lookup` devuelve la lista cacheada | Copias defensivas / `List.unmodifiable` |
| F2.7 | 🟠 | `sorted_index.dart:336-339`, `bitmask_index.dart:321-322, 357-359` | Serialización de índices escribe int32 → timestamps en micros (~1.75e15) se **corrompen** al persistir/recargar. `HashIndex` ya migró a int64 (tag 5) | Escribir tag 5 + int64 LE; leer tag 1 legado |
| F2.8 | 🟠 | `hash_index.dart:428-446`, `sorted_index.dart:335-353`, `bitmask_index.dart:356-374` | `_writeValue` no escribe NADA (ni tag) para tipos no soportados (DateTime, Uint8List, List, Map) → stream desalineado → corrupción total del blob de índices | `else throw ArgumentError` (fallo rápido) |
| F2.9 | 🟠 | `composite_index.dart:43-47` | `_compositeKey` = `join('\|')` de `toString()`: inyección de delimitador (`['a\|b','c']` ≡ `['a','b\|c']`), colisión de tipos (`1` ≡ `'1'`), `null` ≡ `'null'` | Codificación con tag de tipo + length-prefix |
| F2.10 | 🟠 | `fast_query.dart:237-247` | `count()` inconsistente: fast-path ignora `limit/offset`, slow-path los aplica | `count()` siempre ignora paginación (semántica SQL) |
| F2.11 | 🟠 | `_crud_operations.dart:203-212` | `upsert(id, ...)` ignora el id manual: inserta con `_nextId++` (test API-1 en rojo: espera 10, recibe 1) | Usar `putImpl(id, doc)` cuando no existe |

### FASE 3 — MEDIOS (consistencia API e índices)

| ID | Archivo | Problema | Fix |
|----|---------|----------|-----|
| F3.1 | `fast_query.dart:62-113`, `fastdb.dart:909-935` | `query().watch()` sin condiciones usa campo `''` que nunca se notifica en escrituras individuales; emisión inicial duplicada (test API-3/4 en rojo: 4 eventos vs 3); `find()` concurrentes pueden emitir fuera de orden; no vigila `_sortField` | Comodín `''` en `_notifyWatchers`; dedup de emisión inicial; serializar ejecuciones; añadir sortField a campos vigilados |
| F3.2 | `fast_query.dart:217-227` | `findFirst()` ejecuta la query completa (su doc dice que se detiene tras el primero) | Aplicar `limit(1)` interno |
| F3.3 | `fast_query.dart:772, 876-891` | `not()` ignorado por `isNull()`, `isNotNull()`, `alwaysTrue()` | Propagar `_negated` |
| F3.4 | `fast_query.dart:619` | `explain()` usa `_indexes[cond.field]` directo → plan distinto del ejecutado (ignora fallbacks FTS) | Usar `_getIndexForField` |
| F3.5 | `_crud_operations.dart:58` | `put()` acepta ids `<= 0` que luego son invisibles para las queries | `ArgumentError` si `id < 1` |
| F3.6 | `hash_index.dart:51-59` | `_hash` solo mezcla 32 bits bajos de ints de 64 → colisiones masivas con timestamps | Mezclar los 8 bytes |
| F3.7 | `sorted_index.dart:46-49` vs `hash_index.dart:253-257` | Comparadores inconsistentes (`1 == 1.0` en Sorted, `1 != 1.0` en Hash); `_compare` con tipos mezclados lanza `TypeError` que aborta escrituras | Orden total único (num < string < bool; comparación numérica entre nums); sin excepciones |
| F3.8 | `fts_index.dart:58-76`, `hash_index.dart`, `bitmask_index.dart`, `composite_index.dart` | `add()` no idempotente: re-añadir el mismo docId deja entradas huérfanas (contrato remove→add implícito y frágil) | `add` hace remove-if-present |
| F3.9 | `btree.dart:173-225` | `bulkLoad` asume entrada ordenada y sin duplicados: `put()` duplicado en batch crea claves duplicadas en hojas | Validar/ordenar + dedupe (último gana) |
| F3.10 | `sorted_index.dart:202-208` | `startsWith` con prefijo terminado en U+FFFF devuelve `[]` incorrectamente | Recortar U+FFFF finales e incrementar el primer char no-FFFF |
| F3.11 | `btree_node.dart:63-83` | `deserialize` confía en `count` del disco: archivo corrupto → OOM o ceros silenciosos | Validar `count <= kMaxKeys` y longitud de buffer |
| F3.12 | `_storage_manager.dart:149-228` | `compact()` no es crash-safe: truncate+reescritura sin journal → pérdida total posible | Compactar a archivo nuevo + rename atómico (nativo) |
| F3.13 | `fastdb.dart:638-672` | Rollback de `transaction()` no revierte índices secundarios (solo B-Tree root y nextId) | Snapshot de entradas afectadas o rebuild de secundarios en rollback |
| F3.14 | `btree.dart` (merge/colapso/rebuild), `page_manager.dart` | Fuga de páginas: no existe `freePage`; páginas huérfanas en merge, colapso de raíz y rebuild de bulkLoad → el archivo crece monótonamente hasta `compact()` | Free-list en PageManager (o documentar que compact es obligatorio) |

### FASE 4 — RENDIMIENTO

| ID | Archivo | Problema | Fix |
|----|---------|----------|-----|
| F4.1 | `io_storage_strategy.dart:117-127` | `flush()` hace **doble fsync** (`flush()` ya hace fsync en el SDK; `flushSync()` además bloquea el isolate) | Eliminar `flushSync()` |
| F4.2 | `wal_storage_strategy.dart:213-219`, `_crud_operations.dart` | Tormenta de fsyncs: ~8 por insert (flush pre-commit inútil + checkpoint con truncate+fsync tras CADA commit) | Checkpoint por umbral/tiempo; quitar flush pre-commit cuando target ES el WAL |
| F4.3 | `wal_storage_strategy.dart:242-252` | Transacciones bufferadas íntegramente en RAM → `insertAll` de 100k docs ≈ +100 MB RAM (OOM en móvil) | Escribir entradas al WAL incrementalmente (streaming), flush solo en commit |
| F4.4 | `operation_log.dart`, `_crud_operations.dart` | ~5 syscalls extra por op (log + flush + close + truncate + reopen); valores con `toEncodable: toString()` degradan tipos (DateTime→String en replay); errores tragados | Clear lazy (no por op); no re-loguear durante replay; serializar con FastSerializer |
| F4.5 | `fast_query.dart:543-584` | `_applySort` recorre el índice completo aunque el resultado tenga 3 IDs (O(N) para filtrar k) | Si `ids.length << index.size`, ordenar `ids` con `idx.valueOf(id)` (O(k log k)) |
| F4.6 | `fast_query.dart:453-455` | Intersección construye el Set del lado equivocado (puede ser el de millones) | Set del lado menor |
| F4.7 | `fast_query.dart:199-204` | `find()` resuelve documentos secuencialmente | `Future.wait` como `findByIdsImpl` |
| F4.8 | `fast_query.dart:262-294, 367-410` | Claves de caché sensibles al orden de condiciones; composite hot-path sensible al orden de la query vs declaración del índice | Orden canónico; probar orden de `fieldNames` |
| F4.9 | `composite_index.dart:79-94, 138-145` | `size` y `removeById` son O(N) por llamada (el CBO invoca `size` repetidamente) | Contador incremental + reverse-map `docId→key` |
| F4.10 | `sorted_index.dart:397-404`, `hash_index.dart:417-421`, `bitmask_index.dart:348-351` | `deserialize` restaura con `add()` por elemento → O(n²) en arranque con índices grandes de baja cardinalidad | Construcción bulk |
| F4.11 | `fts_index.dart:74, 106-127, 161-176` | `List.contains` O(k) por token/doc; `searchPrefix`/`contains` iteran todo el vocabulario | `Set<int>` por token; vocabulario ordenado + búsqueda binaria |
| F4.12 | `hash_index.dart:32-38,92,164-167`, `bloom_filter.dart` | Bloom filter: **código muerto** (nadie llama `mightContainValue`) que cuesta `toString()` + k hashes por `add`; fórmulas de tamaño/FP incorrectas | Eliminarlo (o integrarlo de verdad — decisión: eliminar) |
| F4.13 | `fastdb.dart:1172-1181`, `wal_storage_strategy.dart:336` | CRC32 bit-a-bit (~8 ops/byte) en escritura y verificación de cada doc | Tabla de 256 entradas (4-8× más rápido) |
| F4.14 | `fastdb.dart:972-989` | Read-ahead fijo de 512 B: docs >504 B hacen 2 lecturas (2 syscalls) | Leer length primero o read-ahead adaptativo |
| F4.15 | `io_storage_strategy.dart:98` | `_file.length()` (fstat) en cada read pese a mantener `_cachedSize` | Usar caché de tamaño |
| F4.16 | `page_manager.dart:115-129` | `allocatePage` escribe 4 KB de ceros a disco incluso en write-behind (2 entradas WAL por página nueva) | Diferir la escritura de ceros |
| F4.17 | `fastdb.dart:1039-1048` | `_serialize` hace `Map.from()` incondicional + otro condicional (la "OPTIMIZATION" está rota) | Una sola copia condicional |

### FASE 5 — SERIALIZACIÓN Y SEGURIDAD

| ID | Archivo | Problema | Fix |
|----|---------|----------|-----|
| F5.1 | `binary_io.dart:89-98, 226-237` | `DateTime` pierde `isUtc` en la vía binaria (TypeAdapters): roundtrip de `DateTime.utc(...)` → hora local | Escribir siempre UTC y leer con `isUtc: true` |
| F5.2 | `fast_serializer.dart:65-90`, `binary_io.dart:209-211` | Strings de usuario que empiezan por `\u0000dt:` etc. se reinterpretan como sentinelas al leer | Escapar `\u0000` al escribir |
| F5.3 | `fast_serializer.dart` | Enteros >2⁵³ pierden precisión silenciosamente en web (JSON→double) | Documentar en `SUPPORTED_DATA_TYPES.md` + warning |
| F5.4 | `encrypted_storage_strategy.dart`, `_aes256_ctr.dart` | CTR con nonce estático (reuso de keystream por bloque), sin MAC (maleable), `aes256KeyFromPassword('')` → clave todo-ceros en silencio | Rechazar password vacío; documentar limitaciones; (HMAC/AEAD queda como mejora futura) |
| F5.5 | `fastdb.dart:1011` | TypeAdapter con `typeId == 256` produce payload que empieza `0x00 0x01` → enrutado a FastSerializer → excepción | Reservar typeId 0x0100 con validación en `registerAdapter` |

### FASE 6 — LIMPIEZA Y DOCS

| ID | Archivo | Problema | Fix |
|----|---------|----------|-----|
| F6.1 | `fast_query.dart:9-22` | `QueryResult` es código muerto | Eliminar |
| F6.2 | `query_cache.dart:62-66` | `stats()` no cumple su doc (no hay contadores hits/misses); LRU O(n) por acceso | Contadores reales + `LinkedHashMap` O(1) |
| F6.3 | `lru_cache.dart:44-51` | `capacity <= 0` crece sin límite; `get()` devuelve buffer interno mutable | Guard + copia/unmodifiable |
| F6.4 | `local_storage_strategy.dart:57-78` | Cada flush re-codifica TODA la DB en Base64 (O(n²) en lote); `_dirty=false` antes de `setItem` → tras QuotaExceeded no se reintenta | Flag dirty tras éxito; documentar límite de tamaño |
| F6.5 | `io_storage_strategy.dart:55` | `FileLock.blockingExclusive` bloquea el isolate si otro proceso retiene el lock | Lock no bloqueante con reintentos |
| F6.6 | `wal_storage_strategy.dart:271` | `close()` auto-commitea una tx abierta | Documentar o hacer rollback |
| F6.7 | `indexed_db_strategy.dart:250-252` | `close()` no cierra la conexión IDB | `_database.close()` |
| F6.8 | docs | `BUGS.md`/`CLAUDE.md` con bugs ya corregidos marcados como pendientes; docstrings incorrectos (`rangeSearch` devuelve claves no valores; FTS "min length 3" vs código `>= 2`) | Actualizar BUGS.md, CLAUDE.md, PERFORMANCE.md, CHANGELOG.md |

---

## 4. Plan de ejecución aprobado

- **Pre-paso**: probes de verificación (§2) + baseline de tests/benchmark. ✅
- **Fase 0**: este documento + tests de regresión en rojo + marcar BUGS.md obsoleto.
- **Fases 1→6**: correcciones por severidad según las tablas de §3.
- **Verificación por fase**: `dart analyze` + `dart test` en verde antes de avanzar.
- **Decisiones aprobadas**: alcance completo · full-scan con filtrado para campos sin índice · OperationLog mantenido pero optimizado · documentación en este archivo.

## 5. Tests de regresión

Archivo: `test/bug_fixes_test.dart` — un test por hallazgo corregido, todos con `MemoryStorageStrategy` salvo los de WAL/IO (archivos temporales). Tests preexistentes en rojo que deben pasar al final: `upsert y upsertWhere (API-1)`, `watchDocs y QueryBuilder.watch() (API-3 & API-4)`.

## 6. Benchmark (antes / después)

Baseline (`benchmark/full_benchmark.dart`, in-memory, Dart VM — 2026-07-27):

| Métrica | Antes | Después | Δ |
|---------|-------|---------|---|
| Sequential insert (10k) | 127.4k ops/s | | |
| Batch insert (10k) | 125.4k ops/s | | |
| findById (10k reads) | 297.6k ops/s | | |
| HashIndex equals (5k) | 1545.8k ops/s | | |
| SortedIndex range (5k) | 1136.1k ops/s | | |
| BitmaskIndex bool (5k) | 1509.1k ops/s | | |
| AND query age+city (3k) | 714.2k ops/s | | |
| Partial update (5k) | 72.7k ops/s | | |
| **Delete by id (5k)** | **22.2 ms/op** ⚠️ (anómalo, investigar en F4) | | |
| Batch insert 100k | 202.0k ops/s | | |
| sortBy age (1k) | 1147.2k ops/s | | |

## 7. Estado de "Known Bugs" heredados (BUGS.md / CLAUDE.md)

| Bug heredado | Estado real en el código actual |
|--------------|--------------------------------|
| BUG-1 `_notifyWatchers` ignora `doc` | ✅ Ya corregido (filtra por campo, `fastdb.dart:909-939`) |
| BUG-2 `isNull()` siempre vacío | ✅ Ya corregido (usa complemento vía `rangeSearch`) |
| BUG-3 `deleteImpl` no notifica watchers | ✅ Ya corregido (`_crud_operations.dart:189`) |
| BUG-4 FTS `retainAll` O(n×m) | ✅ Ya corregido (`matches.toSet()`) |
| BUG-5 `HashIndex.lookup` copia innecesaria | ✅ Ya corregido (`lookupCount` existe y se usa en `count()`) |
| BUG-6 `bulkLoad` sin WAL fallback | ⚠️ Parcial: el caller gestiona WAL, pero el fallback de inserts individuales convive con la fuga de páginas (F3.14) |
| `QueryCache` static (CLAUDE.md) | ❌ Pendiente → **F1.5** |

---

## Registro de ejecución

- [x] Pre-paso: probes A-H ejecutados (§2) · baseline: 118 tests, 2 fallos preexistentes (upsert, watch)
- [x] Fase 0 — FIX_PLAN.md + 21 tests de regresión en rojo + BUGS.md actualizado
- [x] Fase 1 — 6/6 críticos corregidos (F1.1–F1.6) · suite: sin regresiones
- [x] Fase 2 — 11/11 altos corregidos (F2.1–F2.11) · bonus: test preexistente `upsert (API-1)` ahora pasa · suite: sin regresiones
- [x] Fase 3 — 14/14 medios (F3.1–F3.14) · bonus: `watchDocs (API-3/4)` pasa · hallazgo extra: clearCache destructivo en rollback (pérdida de páginas dirty pre-tx) corregido · **141/141 tests en verde**
- [ ] Fase 4
- [ ] Fase 5
- [ ] Fase 6
