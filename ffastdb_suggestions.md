# ffastdb — Sugerencias de Mejora (v0.0.13)

> Análisis técnico basado en integración real con una aplicación Flutter que maneja miles de documentos.
> Código analizado: `lib/src/fastdb.dart`, `lib/src/query/fast_query.dart`, `lib/src/storage/web/`, `lib/src/ffastdb_singleton.dart`.

---

## 1. Mejoras en el `QueryBuilder`

### 1.1 Métodos de Finalización (`find()` / `findAll()`)

**Problema actual:**  
`QueryBuilder.findIds()` devuelve `List<int>` con IDs internos. El usuario debe entonces llamar manualmente a `db.findById()` en un bucle, lo cual es verboso y no es descubrible como parte del API fluido.

```dart
// Actual — verboso:
final ids = db.query().where('status').equals('active').findIds();
final docs = await Future.wait(ids.map(db.findById));

// Deseado:
final docs = await db.query().where('status').equals('active').find();
```

**Propuesta de implementación:**  
Agregar `find()` al `QueryBuilder`. El constructor ya recibe `_indexes`; solo falta una referencia al `FastDB` padre para poder llamar a `findById`.

```dart
// En QueryBuilder — agregar referencia al DB padre:
class QueryBuilder {
  final Map<String, SecondaryIndex> _indexes;
  final FastDB? _db; // ← NUEVO (nullable para compatibilidad)

  QueryBuilder(this._indexes, [this._db]);

  /// Ejecuta la query y retorna los documentos completos.
  Future<List<dynamic>> find() async {
    if (_db == null) throw StateError('QueryBuilder created without a DB reference.');
    final ids = findIds();
    final results = <dynamic>[];
    for (final id in ids) {
      final doc = await _db!.findById(id);
      if (doc != null) results.add(doc);
    }
    return results;
  }

  /// Retorna el primer resultado o null.
  Future<dynamic> findFirst() async {
    final ids = findIds();
    if (ids.isEmpty) return null;
    return _db?.findById(ids.first);
  }
}

// En FastDB — actualizar query():
QueryBuilder query() => QueryBuilder(_secondaryIndexes, this);
```

**Impacto:** Cambio no-breaking (el parámetro `_db` es opcional). Mejora masiva de ergonomía.

---

### 1.2 Consultas Multi-Condición (`where().where()`)

**Estado actual:**  
✅ **Ya funciona.** El `QueryBuilder` soporta encadenamiento de múltiples `.where()`. Cada llamada a `.where()` → `.equals()` (o similar) llama a `_addCondition()` que agrega al mismo grupo AND.

```dart
// Esto ya funciona en v0.0.13:
db.query()
  .where('status').equals('active')
  .where('type').equals('client')
  .findIds();
```

**Lo que NO funciona todavía:**  
La API no tiene un método `.and()` que sea semánticamente claro. Existe como alias de `where()`, pero no es obvio en la documentación pública.

**Sugerencia:**  
Documentar explícitamente el patrón multi-condición en el README con un ejemplo, y asegurarse de que el `explain()` muestre el grupo AND correctamente.

---

### 1.3 `.count()` en `QueryBuilder`

**Problema actual:**  
`db.countWhere((q) => q.where('x').equals('y').findIds())` requiere evaluar todos los IDs aunque solo se necesite el conteo. Para índices hash simples esto es O(1), pero la API actual no lo expone.

```dart
// Actual:
final count = (await db.countWhere((q) => q.where('status').equals('active').findIds()));

// Deseado:
final count = db.query().where('status').equals('active').count();
```

**Propuesta:**  
Agregar `count()` como método síncrono al `QueryBuilder`, ya que `findIds()` ya es síncrono:

```dart
/// Retorna el número de documentos que coinciden. O(1) para consultas equals simples.
int count() => findIds().length;
```

Para la optimización real (evitar materializar la lista):

```dart
int count() {
  // Hot path: equals en HashIndex → O(1) sin materializar
  if (_orGroups.length == 1 && _orGroups[0].length == 1) {
    final cond = _orGroups[0][0];
    if (cond is _EqualsCondition && !cond.negated) {
      final index = _indexes[cond.field];
      if (index != null) return index.lookup(cond.value).length;
    }
  }
  return findIds().length;
}
```

**Nota:** El método `countWhere()` en `FastDB` ya hace algo similar pero no aprovecha el hot-path del índice.

---

## 2. Arquitectura Concurrente — Múltiples Instancias en Web

### 2.1 Diagnóstico del Problema

**Causa raíz:**  
`FFastDbSingleton` mantiene `FastDB? _db` como campo de instancia. En web, la estrategia de almacenamiento actual (`IndexedDbStorageStrategy` / `LocalStorageStrategy`) usa una clave fija `'db_buffer'` en el store `'ffastdb_store'`. Si se abren dos bases de datos distintas (ej: `'users'` y `'products'`), la segunda llamada a `ffastdb.init()` devuelve la primera instancia (`if (_db != null) return _db!`) sin importar el nombre.

```dart
// En ffastdb_singleton.dart L64:
if (_db != null) return _db!; // ← devuelve la PRIMERA instancia siempre
```

Y en `IndexedDbStorageStrategy`:
```dart
// En indexed_db_strategy.dart L54:
final String _storeName = 'ffastdb_store'; // ← compartido entre todas las instancias
final String _dataKey = 'db_buffer';       // ← clave fija, colisiona entre dbs
```

### 2.2 Fix para el Singleton

**Opción A — Singleton nombrado (mínimo esfuerzo):**

```dart
class FFastDbSingleton {
  final Map<String, FastDB> _instances = {}; // ← mapa por nombre

  Future<FastDB> init(String name, {...}) async {
    if (_instances.containsKey(name)) return _instances[name]!;
    final db = await openDatabase(name, ...);
    _instances[name] = db;
    return db;
  }

  FastDB getDb(String name) {
    final db = _instances[name];
    if (db == null) throw StateError('DB "$name" not initialized.');
    return db;
  }

  Future<void> close([String? name]) async {
    if (name != null) {
      await _instances.remove(name)?.close();
    } else {
      for (final db in _instances.values) await db.close();
      _instances.clear();
    }
  }
}
```

**Opción B — Colecciones dentro de una DB (recomendada para Web):**  
En lugar de múltiples archivos físicos, usar un prefijo de colección en las claves del `IndexedDB`:

```dart
// Cada "colección" guarda en su propia clave:
// 'users_db_buffer', 'products_db_buffer', etc.
class IndexedDbStorageStrategy implements StorageStrategy {
  final String _collectionKey; // ej: 'users_db_buffer'
  
  IndexedDbStorageStrategy(String dbName, {String collection = 'default'})
      : _collectionKey = '${dbName}_${collection}_buffer';
}
```

### 2.3 Fix para `IndexedDbStorageStrategy`

El `_dbName` ya se pasa al constructor pero no se usa para diferenciar los datos en `IndexedDB`. La corrección mínima:

```dart
// indexed_db_strategy.dart:
IndexedDbStorageStrategy(this._dbName)
    : _dataKey = '${_dbName}_buffer'; // ← usar nombre del DB como clave
```

---

## 3. Persistencia de Índices — Comportamiento Actual vs. Deseado

### 3.1 Estado Real

**Buena noticia:** El mecanismo ya existe. En `fastdb.dart`:

```dart
// Durante open() — línea ~268:
final isClean = header.length >= 25 && header[24] == 0x43;
if (isClean) {
  await _loadIndexes(); // ← carga índices del disco
} else {
  await _rebuildSecondaryIndexes(); // ← rebuild completo
}
```

La bandera `0x43` ('C' de Clean) en `offset 24` del header indica si la DB se cerró limpiamente. Si lo fue, `_loadIndexes()` deserializa los índices desde el almacenamiento sin rebuild.

### 3.2 El Problema Real

**Los índices deben ser registrados ANTES de `init()`:**

```dart
// ❌ INCORRECTO — los índices no se cargan del disco:
final db = await ffastdb.init('myapp', directory: path);
db.addIndex('status');         // ← índice vacío, sin datos persistidos
db.addSortedIndex('createdAt'); // ← ídem
await db.reindex(); // ← hay que llamar esto en cada arranque

// ✅ CORRECTO — pero la API actual no lo soporta directamente...
// No existe forma de registrar índices ANTES de open().
```

**Propuesta — Pre-registro de índices:**

```dart
Future<FastDB> init(
  String name, {
  String directory = '',
  int version = 1,
  // NUEVO:
  List<String> hashIndexes = const [],
  List<String> sortedIndexes = const [],
  List<String> bitmaskIndexes = const [],
  ...
}) async {
  if (_db != null) return _db!;
  _db = await openDatabase(name, directory: directory, ...);
  
  // Registrar índices ANTES de que open() cargue datos
  for (final f in hashIndexes)   _db!.addIndex(f);
  for (final f in sortedIndexes) _db!.addSortedIndex(f);
  // _loadIndexes() ya habrá corrido dentro de openDatabase()...
  // ← Esto requiere refactorizar el ciclo open para soportar pre-registro
}
```

**Alternativa más limpia — Builder pattern:**

```dart
final db = await ffastdb.init('myapp', directory: path)
  ..addIndex('status')
  ..addSortedIndex('createdAt');
// Luego, detectar automáticamente si necesita reindex:
await db.ensureIndexes(); // ← nuevo: rebuild solo si la DB no cerró limpiamente
```

### 3.3 `reindex()` Automático Inteligente

Agregar un flag al estado del DB que indique si los índices se cargaron del disco o se crearon en frío:

```dart
bool _indexesLoadedFromDisk = false;

Future<void> open(...) async {
  // ...
  if (isClean) {
    await _loadIndexes();
    _indexesLoadedFromDisk = true; // ← NUEVO
  } else {
    await _rebuildSecondaryIndexes();
  }
}

/// Reconstruye índices solo si no fueron restaurados del almacenamiento.
Future<void> ensureIndexes() async {
  if (!_indexesLoadedFromDisk) {
    await _rebuildSecondaryIndexes();
  }
}
```

---

## 4. Estrategia de Almacenamiento en Web — IndexedDB por Defecto

### 4.1 Estado Actual

En `platform/open_database_web.dart` (inferido desde la lógica de la plataforma), la estrategia web usa `LocalStorageStrategy` que tiene un límite de ~5 MB en la mayoría de los navegadores.

`IndexedDbStorageStrategy` **ya existe** en `lib/src/storage/web/indexed_db_strategy.dart` y está implementada correctamente, pero no es la estrategia por defecto.

### 4.2 Propuesta

Cambiar `open_database_web.dart` para usar `IndexedDbStorageStrategy` por defecto:

```dart
// platform/open_database_web.dart — ACTUAL (inferido):
Future<FastDB> openDatabase(String name, {...}) async {
  final storage = LocalStorageStrategy(name); // ← límite 5MB
  // ...
}

// PROPUESTO:
Future<FastDB> openDatabase(String name, {...}) async {
  final storage = IndexedDbStorageStrategy(name); // ← sin límite práctico
  // ...
}
```

### 4.3 Consideración de Compatibilidad

`IndexedDB` está disponible en todos los browsers modernos y como estrategia de almacenamiento para PWAs. La única razón para mantener `LocalStorageStrategy` sería compatibilidad con browsers muy antiguos (IE11, que ya está obsoleto).

**Recomendación:** Hacer `IndexedDB` el default y deprecar `LocalStorageStrategy`.

---

## 5. Consultas Reactivas (Streams / Watchers)

### 5.1 Estado Actual

El sistema reactivo existe en `FastDB`:

```dart
// fastdb.dart L815:
Stream<List<int>> watch(String field) { ... }
```

Emite `List<int>` (IDs) cada vez que un documento con ese campo indexado es modificado. El uso actual en la app es:

```dart
db.watch('status').listen((ids) async {
  final docs = await Future.wait(ids.map(db.findById));
  emit(DocsLoaded(docs.whereType<MyModel>().toList()));
});
```

### 5.2 Limitaciones

1. **Solo por field**, no por query completa.
2. **Emite todos los IDs** del campo, no solo los que matchean la condición.
3. **No integra con `QueryBuilder`** — requiere código extra.

### 5.3 Propuesta — `QueryBuilder.watch()`

```dart
// En QueryBuilder:
Stream<List<int>> watchIds(FastDB db) {
  // Observar todos los campos involucrados en la query:
  final fields = _orGroups.expand((g) => g.map((c) => c.field)).toSet();
  
  // Combinar streams y re-filtrar con findIds() en cada evento:
  final streams = fields.map((f) => db.watch(f)).toList();
  
  return Rx.merge(streams).asyncMap((_) async => findIds());
  // (requiere RxDart o implementación manual con StreamController)
}

/// Emite los documentos completos cada vez que la query cambia.
Stream<List<dynamic>> watch(FastDB db) {
  return watchIds(db).asyncMap((ids) async {
    final docs = <dynamic>[];
    for (final id in ids) {
      final doc = await db.findById(id);
      if (doc != null) docs.add(doc);
    }
    return docs;
  });
}
```

**Sin dependencias externas** (implementación sin RxDart):

```dart
Stream<List<int>> watchIds(FastDB db) {
  final controller = StreamController<List<int>>.broadcast();
  final fields = _orGroups.expand((g) => g.map((c) => c.field)).toSet();
  final subs = <StreamSubscription>[];
  
  for (final field in fields) {
    subs.add(db.watch(field).listen((_) {
      if (!controller.isClosed) controller.add(findIds());
    }));
  }
  
  controller.onCancel = () {
    for (final sub in subs) sub.cancel();
    controller.close();
  };
  
  return controller.stream;
}
```

---

## 6. Depuración y Logs — Mejoras en Error Reporting

### 6.1 Error Actual

```
Bad state: Cannot perform operations on a closed database.
```

No incluye:
- Qué operación la disparó (insert, findById, update, etc.)
- Si la causa fue una reapertura, un cierre prematuro, o una operación concurrente.
- El nombre de la base de datos.

### 6.2 Propuesta — Contexto Enriquecido

En `fastdb.dart`:

```dart
// ACTUAL (L52):
throw StateError('Cannot perform operations on a closed database.');

// PROPUESTO:
class FastDbClosedError extends StateError {
  final String operation;
  final String? databaseName;
  
  FastDbClosedError(this.operation, {this.databaseName})
      : super(
          'FFastDB: Cannot perform "$operation" on a closed database'
          '${databaseName != null ? ' ("$databaseName")' : ''}. '
          'This may happen if:\n'
          '  1. close() was called before this operation.\n'
          '  2. A second call to init() with a different name closed the first instance.\n'
          '  3. An async operation completed after the DB was disposed.\n'
          'Call ffastdb.init() again to reopen the database.',
        );
}

// Uso en _exclusive():
Future<T> _exclusive<T>(Future<T> Function() fn) {
  if (_isClosed) {
    throw FastDbClosedError(_currentOperation, databaseName: _name);
  }
  // ...
}
```

### 6.3 Nombre de la DB en la Instancia

Agregar `final String name` al `FastDB` para poder identificarlo en logs:

```dart
class FastDB {
  final String name; // ← NUEVO: 'users', 'myapp', etc.
  final StorageStrategy storage;
  // ...
  
  FastDB._internal(this.storage, {
    required this.name, // ← NUEVO
    // ...
  });
}
```

---

---

## 7. Bug Crítico: `openDatabase` Destruye la Instancia Activa

### 7.1 El Problema

Tanto `open_database_native.dart` como `open_database_web.dart` hacen esto **al inicio**:

```dart
// open_database_native.dart L48 / open_database_web.dart L32:
await FfastDb.disposeInstance();
```

Esto significa que **cada llamada a `openDatabase()` destruye cualquier DB previamente abierta**, incluyendo la propia si se llama dos veces.

**Escenario real que falla:**
```dart
final db = await ffastdb.init('users', directory: path);
// ... 2 segundos después, desde otro lugar del código:
final db2 = await ffastdb.init('users', directory: path); // ← DESTRUYE db
// db ahora lanza: "Cannot perform operations on a closed database"
```

Esto es exactamente el error `Bad state: closed database` de la conversación de integración.

### 7.2 Fix

```dart
// ANTES de disposeInstance(), verificar si ya está abierta con el mismo nombre:
Future<FastDB> openDatabase(String name, {...}) async {
  // Si la instancia actual es del mismo nombre, reutilizarla:
  if (FfastDb._instance != null && !FfastDb._instance!._isClosed) {
    // Idealmente comparar el nombre — requiere guardar _name en FastDB
    return FfastDb._instance!;
  }
  await FfastDb.disposeInstance(); // Solo cerrar si vamos a abrir otra diferente
  // ...
}
```

**Fix mínimo alternativo** — en `FFastDbSingleton.init()`:
```dart
Future<FastDB> init(String name, {...}) async {
  if (_db != null && !_db!._isClosed) return _db!; // ← ya existe y está abierta
  // ...
}
```

---

## 8. Seguridad: Cifrado XOR No Es Criptografía

### 8.1 Problema en `EncryptedStorageStrategy`

```dart
// encrypted_storage_strategy.dart L16-22:
void _cipher(Uint8List data, int offset) {
  for (int i = 0; i < data.length; i++) {
    data[i] ^= _key[(offset + i) % _key.length]; // ← XOR de Vigenère
  }
}
```

Esto es un **cifrado de Vigenère / XOR stream**, no AES. Tiene vulnerabilidades conocidas:
- Si el atacante conoce el plaintext de un bloque (ej: el header `FDB2` siempre empieza igual), puede derivar la clave.
- Es trivialmente reversible con análisis de frecuencia.
- No tiene autenticación de integridad (no detecta manipulación del ciphertext).

### 8.2 Propuesta

**Opción A — Advertencia en docs (costo cero):**  
Documentar claramente que `EncryptedStorageStrategy` es **ofuscación**, no cifrado real. Renombrar a `ObfuscatedStorageStrategy`.

**Opción B — AES-256-GCM con `pointycastle` (recomendado para producción):**
```dart
// Nueva dependencia: pointycastle: ^3.7.0
class AesStorageStrategy implements StorageStrategy {
  // Implementar con AES-256-GCM para autenticación + confidencialidad
  // Clave derivada con PBKDF2 desde el encryptionKey del usuario
}
```

**Opción C — Mínimo esfuerzo con seguridad real:**  
Usar `dart:crypto` (disponible en Dart nativo) con AES-CBC + HMAC-SHA256 para integridad.

> **Nota de compatibilidad Web:** AES en Web requiere la API `SubtleCrypto` de JavaScript vía `dart:js_interop`, o una librería pura Dart como `encrypt`.

---

## 9. Generación de Código — Annotations Sin Generador

### 9.1 Estado Actual

`lib/src/annotations.dart` define:
```dart
@FFastDB(typeId: 0)     // marca la clase
@FFastId()              // marca el campo ID
@FFastField(0)          // asocia campo a slot estable  
@FFastIndex(sorted: true) // crea índice secundario
```

Pero el propio archivo dice:
```dart
/// These annotations serve as documentation today and will drive code
/// generation in a future release (similar to how @HiveType/@HiveField
/// drive hive_generator).
```

**Sin generador, el usuario debe:**
1. Escribir el `TypeAdapter` manualmente (propenso a errores, ~30 líneas de boilerplate).
2. Registrar índices manualmente con `db.addIndex('field')`.
3. Actualizar el adaptador a mano en cada cambio de modelo.

### 9.2 Generador Mínimo Viable

Un generador `build_runner` que lea las anotaciones y produzca:

```dart
// ENTRADA (escrito por el usuario):
@FFastDB(typeId: 1)
class Person {
  @FFastId() int? id;
  @FFastField(0) String name;
  @FFastField(1) @FFastIndex() String city;
  @FFastField(2) @FFastIndex(sorted: true) int age;
}

// SALIDA (generada por `ffastdb_generator`):
class PersonAdapter extends TypeAdapter<Person> {
  @override int get typeId => 1;

  @override
  Person read(BinaryReader reader) {
    final numFields = reader.readUint8();
    final fields = {for (int i = 0; i < numFields; i++) reader.readUint8(): reader.readDynamic()};
    return Person()
      ..name = fields[0] as String
      ..city = fields[1] as String
      ..age = fields[2] as int;
  }

  @override
  void write(BinaryWriter writer, Person obj) {
    writer.writeUint8(3); // field count
    writer.writeUint8(0); writer.writeDynamic(obj.name);
    writer.writeUint8(1); writer.writeDynamic(obj.city);
    writer.writeUint8(2); writer.writeDynamic(obj.age);
  }

  // Índices registrados automáticamente
  List<String> get hashIndexes => ['city'];
  List<String> get sortedIndexes => ['age'];
}
```

**Paquetes necesarios:** `build`, `source_gen`, `analyzer` (todos de pub.dev, sin dependencias externas).

---

## 10. API Pública — Omisiones en el Barrel Export

### 10.1 Clases No Exportadas

```dart
// lib/ffastdb.dart — ACTUAL:
export 'src/storage/web/web_storage_strategy.dart'; // ← WebStorageStrategy (solo RAM)
// FALTA:
// export 'src/storage/web/indexed_db_strategy.dart';     ← IndexedDbStorageStrategy
// export 'src/storage/web/local_storage_strategy.dart';   ← LocalStorageStrategy  
// export 'src/storage/io/io_storage_strategy.dart';       ← IoStorageStrategy
// export 'src/storage/encrypted_storage_strategy.dart';   ← EncryptedStorageStrategy
```

Esto obliga a los usuarios a importar rutas internas (`package:ffastdb/src/storage/io/...`) que no son parte de la API pública estable. Si la estructura interna cambia, se rompen.

### 10.2 Fix

```dart
// lib/ffastdb.dart — PROPUESTO:
export 'src/fastdb.dart';
export 'src/annotations.dart';
export 'src/ffastdb_singleton.dart';
export 'src/storage/storage_strategy.dart';
export 'src/storage/memory_storage_strategy.dart';
export 'src/storage/wal_storage_strategy.dart';
export 'src/storage/buffered_storage_strategy.dart';
export 'src/storage/encrypted_storage_strategy.dart'; // NUEVO
export 'src/storage/web/web_storage_strategy.dart';
export 'src/query/fast_query.dart';
export 'src/platform/open_database.dart';
// Condicionales por plataforma:
export 'src/storage/io/io_storage_strategy.dart'    // NUEVO
    if (dart.library.js_interop) 'src/storage/web/indexed_db_strategy.dart';
```

### 10.3 `QueryBuilder` Exportado Pero `_Condition` No

`fast_query.dart` exporta `QueryBuilder` pero las clases `_Condition` son privadas. Esto está bien para el uso normal, pero impide que usuarios avanzados creen condiciones personalizadas o extiendan el query engine. Considerar una **interfaz pública** `Condition<T>` en el futuro.

---

## 11. Tests — Brechas de Cobertura

### 11.1 Lo que NO tiene test

Revisando `test/fastdb_test.dart` (1152 líneas, cobertura buena) quedan sin cubrir:

| Escenario | Archivo | ¿Test existe? |
|-----------|---------|---------------|
| Dos `openDatabase()` seguidos sin cerrar | `open_database_*.dart` | ❌ |
| `encryptionKey` round-trip (datos cifrados persisten) | `encrypted_storage_strategy.dart` | ❌ |
| `IndexedDbStorageStrategy` aislada de `LocalStorageStrategy` | `indexed_db_strategy.dart` | ❌ (solo nativo) |
| `QueryBuilder.explain()` output format | `fast_query.dart` | ❌ |
| `watch()` en campo sin índice (path `rangeSearch`) | `fastdb.dart` L843 | ❌ |
| `findStream()` pausa/reanuda con muchos docs | `fastdb.dart` L805 | ❌ |
| Registro de 2 adaptadores con mismo `typeId` | `type_registry.dart` | Parcial |
| `compact()` con `encryptionKey` activo | - | ❌ |
| `migration` que falla a mitad de camino | `_runMigrations` | ❌ |

### 11.2 Test Crítico Faltante — Reapertura sin Cierre

```dart
test('segunda llamada a openDatabase no destruye la primera instancia', () async {
  final db1 = await ffastdb.init('test', directory: dir);
  await db1.insert({'key': 'value'});
  
  // Segunda llamada — NO debe cerrar db1
  final db2 = await ffastdb.init('test', directory: dir);
  
  // db1 debe seguir siendo usable:
  expect(db1.isOpen, isTrue); // ← actualmente falla
  final doc = await db1.findById(1);
  expect(doc, isNotNull);
});
```

---

## Resumen de Prioridades

| # | Mejora | Esfuerzo | Impacto | Estado actual |
|---|--------|----------|---------|---------------|
| **7** | **Fix `openDatabase` destruye instancia activa** | **Bajo** | **Crítico** | **🐛 Bug confirmado** |
| 2.3 | Fix `IndexedDB` key collision (multi-db en web) | Bajo | Crítico | 🐛 Bug |
| 8 | Documentar/reemplazar cifrado XOR | Bajo–Medio | Alto | ⚠️ Falsa seguridad |
| 1.1 | `find()` / `findFirst()` en QueryBuilder | Bajo | Alto | ❌ No existe |
| 3.3 | `ensureIndexes()` + flag `_indexesLoadedFromDisk` | Bajo | Alto | ❌ No existe |
| 5.3 | `QueryBuilder.watch()` reactivo | Medio | Alto | ❌ No existe |
| 10.2 | Exportar `IoStorageStrategy` / `EncryptedStorageStrategy` | Muy bajo | Medio | ⚠️ API interna expuesta |
| 9 | Generador de código (`ffastdb_generator`) | Alto | Alto | ❌ Anotaciones sin generador |
| 1.3 | `.count()` en QueryBuilder | Muy bajo | Medio | ❌ No existe |
| 6.2 | `FastDbClosedError` con contexto | Bajo | Medio | ❌ No existe |
| 11 | Tests de cobertura faltantes | Medio | Medio | ❌ Brechas identificadas |

---

## Notas de Implementación

### Compatibilidad Hacia Atrás
Todas las propuestas son **aditivas** (no rompen la API existente):
- `find()` se agrega al `QueryBuilder` sin modificar `findIds()`.
- `count()` es un nuevo método.
- `ensureIndexes()` es una alternativa explícita a `reindex()`.
- `FastDbClosedError extends StateError` — catch existente de `StateError` sigue funcionando.

### Tests Sugeridos
```dart
// Test para multi-db en web:
test('Multiple databases do not share storage', () async {
  final db1 = await FastDB.init(IndexedDbStorageStrategy('db1'));
  final db2 = await FastDB.init(IndexedDbStorageStrategy('db2'));
  await db1.insert({'type': 'A'});
  final count = await db2.count();
  expect(count, equals(0)); // ← actualmente puede fallar
});

// Test para QueryBuilder.find():
test('QueryBuilder.find() returns documents', () async {
  await db.insert({'status': 'active', 'name': 'Alice'});
  final docs = await db.query().where('status').equals('active').find();
  expect(docs, hasLength(1));
  expect(docs[0]['name'], equals('Alice'));
});
```
