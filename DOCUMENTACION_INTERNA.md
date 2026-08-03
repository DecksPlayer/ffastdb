# ffastdb — Documentación del Funcionamiento Interno (Guía de Auditoría de Código)

> **Versión del documento:** 1.0.0  
> **Versión de ffastdb analizada:** v0.3.0  
> **Propósito:** Servir como manual técnico profundo y guía de auditoría para desarrolladores y auditores de código sobre la arquitectura interna, componentes, estructuras de almacenamiento, formatos binarios y vectores de riesgo de `ffastdb`.

---

## Índice

1. [Visión General de la Arquitectura](#1-visión-general-de-la-arquitectura)
2. [Capa de Inicialización y Concurrencia](#2-capa-de-inicialización-y-concurrencia)
3. [Motor de Almacenamiento (Storage Engine) & Formato de Disco](#3-motor-de-almacenamiento-storage-engine--formato-de-disco)
4. [Índice Primario B-Tree](#4-índice-primario-b-tree)
5. [Sistema de Índices Secundarios](#5-sistema-de-índices-secundarios)
6. [Motor de Consultas y Optimizador (Query Engine & CBO)](#6-motor-de-consultas-y-optimizador-query-engine--cbo)
7. [Capa de Serialización y Type System](#7-capa-de-serialización-y-type-system)
8. [Operaciones CRUD, Batch, Transacciones y Mantenimiento](#8-operaciones-crud-batch-transacciones-y-mantenimiento)
9. [Guía de Auditoría de Código: Vectores de Riesgo y Checklist](#9-guía-de-auditoría-de-código-vectores-de-riesgo-y-checklist)

---

## 1. Visión General de la Arquitectura

### 1.1 Filosofía de Diseño
`ffastdb` es una base de datos NoSQL embebida en Dart puro (sin dependencias nativas C/C++) diseñada para Flutter y aplicaciones Dart en Web, Android, iOS, Windows, Linux y macOS. Su principio fundamental es **"SPEED FIRST. NO OVER-ENGINEERING"**:
- **Cero dependencias externas pesadas:** No usa FFI ni librerías C nativas.
- **Acceso directo a I/O y memoria:** Evita capas intermedias de abstracción tipo ORM o controladores de base de datos.
- **Estructura modular via `part` / `part of`:** La clase central [`FastDB`](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart) está modularizada en subsistemas lógicos mediante archivos parciales (`_crud_operations.dart`, `_query_operations.dart`, `_batch_operations.dart`, `_index_manager.dart`, `_storage_manager.dart`).

### 1.2 Estructura del Código Fuente
```
lib/
├── ffastdb.dart                           ← Exportador público principal
└── src/
    ├── fastdb.dart                        ← Clase central FastDB (~1300 líneas)
    ├── ffastdb_singleton.dart             ← Wrapper Singleton global (Hive-like API)
    ├── _crud_operations.dart              ← Implementación de insert, update, delete, put
    ├── _query_operations.dart             ← Implementación de find, getAll, count, exists
    ├── _batch_operations.dart             ← Implementación de insertAll, batch & transacciones
    ├── _index_manager.dart                ← Gestión y reconstrucción de índices secundarios
    ├── _storage_manager.dart              ← Formateo de cabecera, persistencia de índices y compactación
    ├── annotations.dart                   ← Anotaciones @FFastDB, @FFastId, @FFastField
    ├── crc32.dart                         ← Algoritmo CRC-32 para integridad de datos y WAL
    ├── index/
    │   ├── btree.dart                     ← B-Tree primario (O(log n) keys → data offset)
    │   ├── btree_node.dart                ← Nodo de B-Tree (leaf/internal) con tamaño de página de 4KB
    │   ├── secondary_index.dart           ← Interfaz abstracta SecondaryIndex
    │   ├── hash_index.dart                ← Índice Hash O(1) para igualdades
    │   ├── sorted_index.dart              ← Índice O(log n) basado en SplayTree para rangos y ordenamiento
    │   ├── bitmask_index.dart             ← Índice de mapa de bits para booleans y enums
    │   ├── composite_index.dart           ← Índice combinado para múltiples campos (AND queries)
    │   ├── fts_index.dart                 ← Índice de búsqueda de texto completo (Inverted Index)
    │   └── index_stats.dart               ← Métricas y estadísticas de uso de índices
    ├── query/
    │   ├── fast_query.dart                ← QueryBuilder y Optimizador Basado en Costos (CBO)
    │   └── query_cache.dart               ← Cache LRU de resultados de consultas
    ├── serialization/
    │   ├── type_adapter.dart              ← Clase base TypeAdapter<T>
    │   ├── type_registry.dart             ← Registro de adaptadores por typeId
    │   ├── fast_serializer.dart           ← Serializador JSON + Binario con soporte Firebase
    │   └── binary_io.dart                 ← BinaryReader y BinaryWriter optimizados
    ├── storage/
    │   ├── storage_strategy.dart          ← Interfaz abstracta de almacenamiento (I/O, RAM, Web)
    │   ├── memory_storage_strategy.dart   ← Estrategia en memoria RAM (para tests y cache)
    │   ├── wal_storage_strategy.dart      ← Write-Ahead Logging (WAL) para seguridad ante fallos (Crash Safety)
    │   ├── encrypted_storage_strategy.dart← Cifrado transparente AES-256-CTR
    │   ├── buffered_storage_strategy.dart ← Buffer intermedio para reducir escrituras en disco
    │   ├── page_manager.dart              ← Gestor de páginas B-Tree y cache LRU de páginas de disco
    │   ├── operation_log.dart             ← Log de operaciones para sincronización y replay
    │   ├── io/
    │   │   └── io_storage_strategy.dart   ← Implementación nativa con RandomAccessFile (`dart:io`)
    │   └── web/
    │       ├── indexed_db_strategy.dart   ← Almacenamiento en IndexedDB para navegadores
    │       ├── local_storage_strategy.dart← Almacenamiento en Web LocalStorage
    │       └── web_storage_strategy.dart  ← Selector de almacenamiento Web
    └── platform/
        ├── open_database.dart             ← Hub de importación condicional
        ├── open_database_native.dart      ← Inicialización nativa con I/O
        └── open_database_web.dart         ← Inicialización Web con IndexedDB
```

---

## 2. Capa de Inicialización y Concurrencia

### 2.1 Modelo de Concurrencia y Mutex (`_exclusive`)
`ffastdb` utiliza un esquema de concurrencia basado en un cola FIFO asíncrona mediante el atributo `_writeLock`:

```dart
Future<T> _exclusive<T>(Future<T> Function() fn) {
  if (_isClosed) throw StateError('Cannot perform operations on a closed database');
  if (_inTransaction) return fn(); // Re-entrada durante transacciones activas
  final next = _writeLock.then((_) async {
    if (_isClosed) throw StateError('Cannot perform operations on a closed database');
    if (dataStorage == null) {
      _dataOffset = storage.sizeSync ?? await storage.size;
    }
    return await fn();
  });
  _writeLock = next.then((_) {}, onError: (_) {});
  return next;
}
```

#### Puntos clave para Auditoría:
- **Re-entrada:** Si `_inTransaction` es `true`, la función se ejecuta inmediatamente sin esperar a `_writeLock`.
- **Sincronización de `_dataOffset`:** Antes de ejecutar cualquier llamada dentro de `_exclusive`, la variable `_dataOffset` se actualiza con el tamaño actual del archivo si no existe un archivo de datos separado (`dataStorage == null`).

### 2.2 Proceso de Apertura (`open()`)
El ciclo de inicialización dentro de [`FastDB.open()`](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart) realiza los siguientes pasos secuenciales:

1. **Lectura de Cabecera:** Lee los primeros 16 bytes mediante [`_StorageManager`](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/_storage_manager.dart).
2. **Validación Magic Bytes:** Comprueba que los bytes `0..3` coincidan con `"FDB2"` (`[70, 68, 66, 50]`).
3. **Carga del Nodo Raíz B-Tree:** Recupera el número de página raíz (bytes `4..7`), `_nextId` (bytes `8..11`) y `_schemaVersion` (bytes `12..15`).
4. **Carga de Lista de Páginas Libres (Free-List):** Carga los punteros a páginas liberadas desde los bytes `24+` del archivo principal.
5. **Replay del OperationLog / WAL:** Si existían escrituras no consolidadas en el WAL o en el `OperationLog`, se reproducen para garantizar la atomicidad tras un cierre inesperado.
6. **Deserialización de Índices Secundarios:** Lee la sección de metadatos de índices (offset 16-23) y reconstruye los objetos [`SecondaryIndex`](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/index/secondary_index.dart) persistidos.
7. **Reconstrucción Automática (Reindex):** Si el usuario registró un nuevo índice que no estaba persistido en disco, se ejecuta un re-escaneo para construir e indexar los registros existentes.

---

## 3. Motor de Almacenamiento (Storage Engine) & Formato de Disco

### 3.1 Abstracción `StorageStrategy`
Toda la interacción I/O se realiza a través de la interfaz [`StorageStrategy`](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/storage/storage_strategy.dart):
- `read(int position, int length)`: Lee un arreglo de bytes en una posición específica.
- `write(int position, Uint8List bytes)`: Escribe bytes en una posición en disco.
- `flush()`: Asegura el vaciado de buffers de S.O. a disco.
- `truncate(int length)`: Recorta el tamaño del archivo de almacenamiento.
- `close()`: Cierra los descriptores de archivo.

### 3.2 Layout del Archivo Principal (`.fdb` / `.idx`)
El archivo de la base de datos se divide en cabeceras fija, bloque de metadatos de índices y páginas del B-Tree:

```
+-------------------------------------------------------------------------+
| Offsets (Bytes) | Tamaño  | Contenido                                   |
+-------------------------------------------------------------------------+
| 0x00 - 0x03     | 4 bytes | Magic Bytes "FDB2" ([70, 68, 66, 50])       |
| 0x04 - 0x07     | 4 bytes | Root Page Index del B-Tree (Int32, Big-End) |
| 0x08 - 0x0B     | 4 bytes | Next Document ID counter (Int32, Big-End)   |
| 0x0C - 0x0F     | 4 bytes | Schema Version (Int32, Big-End)             |
| 0x10 - 0x13     | 4 bytes | Index Metadata File Offset (Int32)          |
| 0x14 - 0x17     | 4 bytes | Index Metadata Length (Int32)               |
| 0x18 - 0x1F     | 8 bytes | Reservado para encabezados futuros          |
| 0x20 - ...      | Variable| Free-page List persistence                  |
| 4096 (Página 1) | 4096 B  | Página 1 del B-Tree                         |
| 8192 (Página 2) | 4096 B  | Página 2 del B-Tree                         |
| ...             | ...     | ...                                         |
+-------------------------------------------------------------------------+
```

### 3.3 Formato de Registros de Documentos (Layout en `.dat` o al final del archivo)
Cuando se inserta un documento en la base de datos, el payload se almacena con la siguiente estructura binaria:

```
+-------------------------------------------------------------------------+
| Offset Relativo | Tamaño  | Campo / Descripción                         |
+-------------------------------------------------------------------------+
| 0x00 - 0x03     | 4 bytes | Document ID (Int32)                         |
| 0x04 - 0x07     | 4 bytes | Data Length N (Int32)                       |
| 0x08 - 0x0B     | 4 bytes | CRC32 Checksum del Payload (Uint32)         |
| 0x0C - (0x0C+N) | N bytes | Serialización (JSON o Binary TypeAdapter)   |
+-------------------------------------------------------------------------+
```

### 3.4 Write-Ahead Logging (`WalStorageStrategy`)
Para garantizar la resistencia ante fallos (Crash Safety), [`WalStorageStrategy`](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/storage/wal_storage_strategy.dart) intercepta todas las llamadas de escritura:

#### Formato de Entrada WAL:
1. **Magic Bytes:** `0xFADB5741` (`"FDBWA"`, 4 bytes).
2. **Entry Type:** `1 byte` (`1` = Write, `2` = Commit, `3` = Truncate).
3. **Transaction ID:** `8 bytes` (Uint64 Little-Endian).
4. **Target Offset:** `8 bytes` (Uint64 Little-Endian) - Offset en el archivo principal `.fdb`.
5. **Length:** `4 bytes` (Uint32 Little-Endian).
6. **Data:** `N bytes` (payload).
7. **CRC32 Checksum:** `4 bytes` (Uint32 de toda la entrada anterior).

#### Algoritmo de Recuperación en Crash:
1. Al abrir la DB, el WAL lee secuencialmente las entradas.
2. Si la última entrada registrada contiene un marcador **COMMIT**:
   - Replay completo: Aplica cada uno de los bloques registrados en el WAL hacia el archivo `.fdb` principal.
3. Si la última entrada **NO contiene COMMIT**:
   - Transacción incompleta (crash a mitad de escritura). Se descartan todas las entradas del bloque no committeado.
4. Tras un replay exitoso, el WAL se trunca (Checkpoint).

---

## 4. Índice Primario B-Tree

El índice primario mapea la clave primaria entera (`int ID`) hacia el offset en bytes donde reside el documento en el archivo de almacenamiento.

### 4.1 Estructura del Nodo B-Tree (`BTreeNode`)
Cada nodo se serializa exactamente en una **Página de 4096 Bytes** (`PageManager.pageSize = 4096`):

```
+-------------------------------------------------------------------------+
| Byte Offset | Tamaño  | Descripción                                     |
+-------------------------------------------------------------------------+
| 0           | 1 byte  | IsLeaf Flag (1 = Nodo Hoja, 0 = Nodo Interno)   |
| 1 - 2       | 2 bytes | Keys Count (Uint16)                             |
| 3 - N       | Variable| Array de Keys (Int32 cada una)                  |
| N+1 - M     | Variable| Array de Values u Offset de Páginas Hijas       |
+-------------------------------------------------------------------------+
```

### 4.2 Cache LRU de Nodos y Búsqueda Síncrona vs Asíncrona
El B-Tree (`lib/src/index/btree.dart`) mantiene un cache en RAM de objetos [`BTreeNode`](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/index/btree_node.dart) des-serializados (`_nodeCache`) con capacidad máxima de 512 nodos.

- **`searchSync(int key)`**: Recorre el árbol usando exclusivamente la memoria RAM (`_nodeCache`). Si hay un "Cache Hit" en todos los niveles del árbol hasta la hoja, retorna el offset inmediatamente sin crear `Future` ni saltar microtasks.
- **`search(int key)`**: Si `searchSync` falla (Cache Miss), pasa al path asíncrono que lee las páginas desde el disco a través de [`PageManager`](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/storage/page_manager.dart).

---

## 5. Sistema de Índices Secundarios

Todos los índices secundarios implementan la clase abstracta [`SecondaryIndex`](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/index/secondary_index.dart) y mantienen referencias en memoria RAM mapeadas a los IDs primarios (`Set<int>`).

```
                              +----------------+
                              | SecondaryIndex |
                              +----------------+
                                      |
     +-----------------+--------------+--------------+-------------------+
     |                 |              |              |                   |
+------------+  +-------------+  +------------+  +----------------+  +----------+
| HashIndex  |  | SortedIndex |  |BitmaskIndex|  | CompositeIndex |  | FtsIndex |
+------------+  +-------------+  +------------+  +----------------+  +----------+
```

### 5.1 `HashIndex` (Búsqueda por Igualdad $O(1)$)
- **Estructura Interna:** `Map<dynamic, Set<int>> _index`.
- **Casos de Uso:** `.where('status').equals('active')`, `.where('category').isIn(['A', 'B'])`.
- **Complejidad:** Búsqueda en $O(1)$, Inserción/Eliminación en $O(1)$.

### 5.2 `SortedIndex` (Búsqueda por Rango y Ordenamiento $O(\log n)$)
- **Estructura Interna:** Basado en `SplayTreeMap<dynamic, Set<int>>`.
- **Casos de Uso:** Operaciones `.between(min, max)`, `.greaterThan()`, `.lessThan()`, y consultas con `.sortBy()`.
- **Complejidad:** Búsqueda, inserción y rangos en $O(\log n)$.

### 5.3 `BitmaskIndex` (Máscaras de Bits para Campos Booleanos / Enums)
- **Estructura Interna:** `Map<dynamic, BitSet>` o enteros Uint64 donde cada bit representa si un ID de documento posee el valor.
- **Ventaja:** Consumo de memoria mínimo e intersecciones súper rápidas mediante operaciones bitwise (`AND`, `OR`).

### 5.4 `CompositeIndex` (Índices Compuestos Multi-Campo)
- **Estructura Interna:** Mapea claves combinadas `String` (ej. `"Buenos Aires|active"`) a un `Set<int>` de IDs.
- **Ventaja:** Evita el costo de computar la intersección de dos conjuntos de IDs cuando se consultan con frecuencia múltiples campos simultáneamente (`city == X AND status == Y`).

### 5.5 `FtsIndex` (Índice de Búsqueda de Texto Completo / Inverted Index)
- **Estructura Interna:**
  - `_tokenIndex`: `Map<String, Set<int>>` (token -> IDs de documentos).
  - `_docTokens`: `Map<int, Set<String>>` (ID de documento -> tokens).
- **Algoritmo de Tokenización:** Converte el texto a minúsculas y lo divide mediante la expresión regular `RegExp(r'[^\w]+')`.
- **Búsqueda Multi-palabra:** Realiza la intersección de los conjuntos de IDs correspondientes a cada palabra clave del texto buscado.

---

## 6. Motor de Consultas y Optimizador (Query Engine & CBO)

El motor de consultas se encuentra en [`QueryBuilder`](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/query/fast_query.dart).

```
[QueryBuilder AST] ──► [Cost-Based Optimizer (CBO)] ──► [Index Selector] ──► [ID Intersection] ──► [Fetch Docs via B-Tree]
```

### 6.1 Optimizador Basado en Costos (CBO)
Cuando una consulta combina múltiples cláusulas `.where()`, el optimizador analiza el costo estimado de evaluación de cada índice antes de ejecutar la búsqueda:

1. **Estimación de Selectividad:**
   - Evaluador HashIndex: Costo estimado = `Set.length`.
   - Evaluador Range/SortedIndex: Costo estimado = número de entradas dentro del rango.
2. **Re-ordenamiento de Ejecución:** Executa primero las cláusulas con **menor cardinalidad/costo estimado** para reducir el tamaño del conjunto de IDs antes de aplicar filtros adicionales o escaneos secundarios.
3. **Escaneo Primario de Respaldo (Full Scan Fallback):** Si ningún campo de la consulta posee índice primario ni secundario, el CBO recurre a un escaneo completo de documentos iterando sobre las claves del B-Tree primario.

### 6.2 Plan de Ejecución (`explain()`)
El método `explain()` devuelve una cadena formateada que detalla el plan seleccionado por el CBO:
- Índice utilizado por cada cláusula.
- Número de documentos candidatos filtrados por paso.
- Si se utilizó `QueryCache` o si se ejecutó un Full Table Scan.

### 6.3 QueryCache (Cache LRU de Resultados)
`fastdb` cuenta con un [`QueryCache`](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/query/query_cache.dart) de hasta 256 entradas que almacena el resultado de listas de IDs para una firma de consulta dada.
- **Invalidación:** Toda operación de escritura (`insert`, `update`, `delete`, `compact`) limpia la cache de consultas de la instancia actual de `FastDB` para prevenir lecturas obsoletas.

---

## 7. Capa de Serialización y Type System

### 7.1 Serialización Híbrida (`FastSerializer`)
`ffastdb` admite dos vías de serialización de documentos:

1. **Documentos JSON Genericos (`Map<String, dynamic>`):**
   - Utiliza `jsonEncode` y `utf8.encode`.
   - Soporte extendido para tipos nativos y Firebase: `DateTime`, `Uint8List`, `Timestamp`, `GeoPoint`, `DocumentReference`.
2. **Objetos fuertemente tipados mediante `TypeAdapter<T>`:**
   - Escritura y lectura binaria directa en stream utilizando [`BinaryWriter`](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/serialization/binary_io.dart) y [`BinaryReader`](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/serialization/binary_io.dart).

### 7.2 BinaryReader y BinaryWriter
La codificación binaria utiliza identificadores de tipo (type tags) de 1 byte para una rápida deserialización:

| Type Tag | Tipo de Dato Dart / Formato Binario |
|:--------:|:------------------------------------|
| `0`      | `null`                              |
| `1`      | `bool` (`1` byte: `0` o `1`)        |
| `2`      | `int` (Int64 Little-Endian)         |
| `3`      | `double` (Float64 Little-Endian)    |
| `4`      | `String` (Uint32 length + UTF-8)    |
| `5`      | `Uint8List` (Uint32 length + bytes) |
| `6`      | `List` (Uint32 length + elementos)  |
| `7`      | `Map` (Uint32 length + key-value)   |
| `8`      | `DateTime` (Int64 msSinceEpoch)     |

---

## 8. Operaciones CRUD, Batch, Transacciones y Mantenimiento

### 8.1 Operaciones CRUD Básicas
- **`insert(doc)`**: Asigna el ID `_nextId++`, serializa el documento, escribe los bytes al final del archivo de datos, actualiza la página B-Tree con `insert(id, offset)` e inserta la clave en todos los índices secundarios.
- **`findById(id)`**: Ejecuta `searchSync(id)` en el B-Tree. Si obtiene el offset, lee los bytes desde el archivo de datos, verifica el checksum CRC32 y deserializa el objeto.
- **`update(id, partialDoc)`**: Lee el documento existente, aplica la fusión de campos (merge), escribe el nuevo documento serializado en un nuevo offset y actualiza la puntería en el B-Tree y los índices secundarios.
- **`delete(id)`**: Elimina la clave del B-Tree, actualiza los índices secundarios, incrementa `_deletedCount` y notifica a los reactivos `watchers`.

### 8.2 Inserción en Lote (`insertAll`) y Transacciones
- **`insertAll(docs)`**: Activa `_batchMode = true` para suspender el vaciado intermedio a disco y las actualizaciones individuales de índices. Al finalizar el lote, reconstruye los índices en masa e incrementa el rendimiento entre 5x y 10x.
- **`transaction(fn)`**: Habilita `_inTransaction = true`. En caso de que ocurra una excepción dentro de la función ejecutada, realiza un rollback completo respaldado por la estrategia WAL.

### 8.3 Fragmentación y Compactación (`compact()`)
Dado que las actualizaciones y eliminaciones dejan espacios obsoletos (tombstones / espacio no reutilizado) en el archivo de datos, la compactación se encarga de reestructurar la base de datos:

1. Crea una lista con todos los IDs de documentos activos mediante `rangeSearch(1, _nextId)`.
2. Escribe secuencialmente únicamente los documentos activos en un archivo temporal o en el tramo inicial de datos.
3. Re-escribe la cabecera y el árbol B-Tree eliminando las páginas obsoletas.
4. Restablece el contador `_deletedCount = 0`.

---

## 9. Guía de Auditoría de Código: Vectores de Riesgo y Checklist

Esta sección ofrece a los auditores una hoja de ruta con los puntos más críticos que deben revisarse durante las auditorías de seguridad, estabilidad y rendimiento de `ffastdb`.

### 9.1 Vectores de Riesgo Identificados

#### 1. Concurrencia Bloqueante de Lecturas por Escrituras (`_exclusive`)
- **Ubicación:** [`lib/src/fastdb.dart`](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L98)
- **Riesgo:** Operaciones de lectura tipo `findById` o `count` se encolan detrás del cola global `_writeLock`. Si hay un `insertAll` voluminoso en ejecución, las lecturas de la interfaz de usuario se congelarán hasta finalizar la escritura.
- **Verificación:** Evaluar si el sistema requiere implementar un esquema Read/Write Lock (R/W Lock) que admita múltiples lectores concurrentes.

#### 2. Desincronización de `_dataOffset`
- **Ubicación:** [`lib/src/fastdb.dart`](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/fastdb.dart#L115) y [`lib/src/_storage_manager.dart`](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/_storage_manager.dart#L78)
- **Riesgo:** En plataformas o estrategias que no implementen `sizeSync` de forma síncrona, la llamada asíncrona `await storage.size` antes de ejecutar una operación exclusiva puede provocar una condición de carrera si hay escrituras encadenadas, escribiendo registros en offsets superpuestos.
- **Verificación:** Auditar que las actualizaciones a `_dataOffset` sean atómicas y síncronas.

#### 3. Consumo Desmedido de Memoria RAM en `FtsIndex`
- **Ubicación:** [`lib/src/index/fts_index.dart`](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/index/fts_index.dart)
- **Riesgo:** El índice de texto completo guarda en memoria un mapa inverso (`_docTokens`) con todos los tokens de todos los documentos sin filtrar palabras vacías (stopwords) ni limitar la longitud máxima de token o cantidad de tokens por documento.
- **Verificación:** Comprobar la presencia de límites de seguridad en la tokenización para evitar problemas de Out-Of-Memory (OOM) en colecciones extensas.

#### 4. Invalidación Incompleta de Reactivos (`_notifyWatchers`)
- **Ubicación:** [`lib/src/_crud_operations.dart`](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/_crud_operations.dart)
- **Riesgo:** En ciertas llamadas de eliminación o actualización por query (`deleteWhere`), verificar si el sistema notifica de forma consistente a todos los `StreamController` registrados en `_watchers`.

#### 5. Integridad en Caso de Apagado Inesperado sin WAL
- **Ubicación:** [`lib/src/storage/io/io_storage_strategy.dart`](file:///c:/Users/gonoj/OneDrive/Documentos/GitHub/fastdb/lib/src/storage/io/io_storage_strategy.dart)
- **Riesgo:** Si la base de datos se inicializa con `IoStorageStrategy` pura en lugar de `WalStorageStrategy`, una caída de tensión a mitad de escritura corruptorá la cabecera o dejará referencias inválidas en las páginas del B-Tree.
- **Verificación:** Validar que en entornos de producción se fuerce el uso de WAL.

---

### 9.2 Lista de Verificación (Checklist) para Auditores

- [ ] **Persistencia y CRC32:** ¿Todos los bloques de datos leídos del archivo verifican su checksum CRC32 antes de ser entregados al usuario?
- [ ] **Cierre Seguro:** ¿Se arroja un `StateError` descriptivo al intentar operar sobre una instancia donde `_isClosed == true`?
- [ ] **Manejo de Errores en Transacciones:** Si una transacción falla durante la fase de Commit en WAL, ¿la instancia se marca como *poisoned* para evitar escrituras subsecuentes sobre datos inconsistentes?
- [ ] **Compatibilidad Web:** ¿Se evitan las llamadas a librerías de I/O nativas (`dart:io`) en el código compartido mediante importaciones condicionales?
- [ ] **Estabilidad de TypeAdapters:** ¿Los índices `typeId` de los adaptadores registrados son únicos e inmutables entre versiones de la aplicación?
- [ ] **Mapeo de Índices Secundarios:** ¿La reconstrucción de índices (`reindex()`) limpia adecuadamente los valores antiguos cuando un documento es actualizado?
- [ ] **Compactación Incremental:** ¿El proceso de `compact()` asegura la copia atómica mediante archivos temporales o transacciones WAL truncadas?

---

*Fin del documento de arquitectura interna de ffastdb.*
