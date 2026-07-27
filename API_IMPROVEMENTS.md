# ffastdb — Mejoras de API y Ergonomía

> Propuestas basadas en el análisis del uso real en aplicaciones Flutter con miles de documentos.  
> Versión analizada: v0.2.7+  
> Todas las propuestas son **no-breaking** (aditivas).

---

## API-1: `upsert()` — insert-or-update atómico

**Problema:** El patrón más común en apps no está soportado atómicamente:

```dart
// Actual — verboso y con race condition:
final exists = await db.exists(id);
if (exists) {
  await db.update(id, fields);
} else {
  await db.insert({...fields, 'ffdbID': id});
}
```

**Propuesta:**
```dart
/// Inserta si no existe, actualiza si ya existe. Atómico.
/// Retorna el ID del documento (existente o nuevo).
Future<int> upsert(int id, Map<String, dynamic> fields);

/// Upsert basado en campo único (sin conocer el ID interno).
Future<int> upsertWhere(
  String uniqueField,
  dynamic value,
  Map<String, dynamic> fields,
);
```

**Implementación sugerida en `_crud_operations.dart`:**
```dart
Future<int> upsertImpl(int id, Map<String, dynamic> fields) async {
  final existing = await _db._findById(id);
  if (existing != null) {
    await updateImpl(id, fields);
    return id;
  } else {
    final data = {...fields, 'ffdbID': id};
    return insertImpl(data);
  }
}
```

---

## API-2: `findByIds(List<int>)` — lectura por lote pública

**Problema:** `findByIdBatch` existe internamente en `_query_operations.dart` pero no está en la API pública. Para cargar listas de documentos por ID (relaciones one-to-many), el usuario debe hacer un loop manual:

```dart
// Actual — verboso:
final docs = await Future.wait(ids.map(db.findById));
```

**Propuesta:**
```dart
/// Carga múltiples documentos en paralelo. Preserva el orden de [ids].
/// Los IDs no encontrados son omitidos del resultado.
Future<List<dynamic>> findByIds(List<int> ids);

/// Versión tipada:
Future<List<T>> findByIdsCast<T>(List<int> ids);
```

**Implementación (ya existe internamente):**
```dart
// En FastDB — solo exponer el método existente:
Future<List<dynamic>> findByIds(List<int> ids) =>
    _exclusive(() => _queryOps.findByIdBatchImpl(ids));
```

---

## API-3: `watchDocs()` — stream de documentos completos

**Problema:** `watch(field)` retorna `List<int>` (IDs), obligando al usuario a resolver manualmente:

```dart
// Actual — boilerplate en cada BLoC:
db.watch('status').listen((ids) async {
  final docs = await Future.wait(ids.map(db.findById));
  emit(DocsLoaded(docs.whereType<MyModel>().toList()));
});
```

**Propuesta:**
```dart
/// Stream de documentos completos cuando el campo indexado cambia.
Stream<List<dynamic>> watchDocs(String field);

/// Con tipado:
Stream<List<T>> watchDocsCast<T>(String field);
```

**Implementación:**
```dart
Stream<List<dynamic>> watchDocs(String field) async* {
  await for (final ids in watch(field)) {
    final docs = <dynamic>[];
    for (final id in ids) {
      final doc = await findById(id);
      if (doc != null) docs.add(doc);
    }
    yield docs;
  }
}
```

---

## API-4: `QueryBuilder.watch()` — streams reactivos integrados en el fluent API

**Problema:** La API fluida (`query().where().find()`) no tiene equivalente reactivo:

```dart
// Actual — no existe forma fluida de observar una query:
db.watch('status').listen((_) async {
  final docs = await db.query().where('status').equals('active').find();
  // ... actualizar UI
});
```

**Propuesta:**
```dart
// Deseado:
db.query()
  .where('status').equals('active')
  .watch()   // ← Stream<List<dynamic>>
  .listen((docs) => updateUI(docs));
```

**Implementación en `QueryBuilder`:**
```dart
/// Stream que emite los documentos coincidentes cada vez que cambia el resultado.
Stream<List<dynamic>> watch() {
  final controller = StreamController<List<dynamic>>.broadcast();
  final fields = _orGroups
      .expand((g) => g.map((c) => c.field))
      .toSet();
  final subs = <StreamSubscription>[];

  // Emitir estado inicial inmediatamente
  Future.microtask(() async {
    if (!controller.isClosed) {
      controller.add(await find());
    }
  });

  for (final field in fields) {
    subs.add(_db!.watch(field).listen((_) async {
      if (!controller.isClosed) controller.add(await find());
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

## API-5: `explain()` integrado en modo debug

**Problema:** `QueryBuilder.explain()` existe pero no se puede activar globalmente para loguear todos los query plans:

```dart
// Actual — solo por consulta individual:
final q = db.query().where('status').equals('active');
print(q.explain()); // manual
await q.find();
```

**Propuesta:**
```dart
// Activar en modo debug para toda la app:
FastDB.debugQueryPlan = true; // static global

// Cada query loguea automáticamente:
// [ffastdb] QueryPlan: WHERE status = 'active'
//   → HashIndex lookup: O(1), est. 42 results
//   → Sort: none
//   → Cache: HIT
```

**Implementación:**
```dart
class FastDB {
  static bool debugQueryPlan = false;

  QueryBuilder query() {
    final q = QueryBuilder(_secondaryIndexes, _findById, _rangeSearch);
    if (debugQueryPlan) q._debugMode = true;
    return q;
  }
}
```

---

## API-6: Soporte de dot-notation para campos anidados en índices

**Problema:** No existe forma de indexar sub-documentos:

```dart
// Actual — falla silenciosamente (el campo no existe en primer nivel):
db.addIndex('user.city'); // ← no funciona
await db.insert({'user': {'city': 'Buenos Aires', 'age': 30}});
db.query().where('user.city').equals('Buenos Aires').find(); // ← vacío
```

**Propuesta:**
```dart
// Deseado:
db.addIndex('user.city');
db.addSortedIndex('user.age');
// Las queries fluidas ya funcionarían con la misma sintaxis
```

**Implementación — extracción de campo anidado:**
```dart
dynamic _extractField(dynamic doc, String fieldPath) {
  if (!fieldPath.contains('.')) return doc is Map ? doc[fieldPath] : null;
  
  final parts = fieldPath.split('.');
  dynamic current = doc;
  for (final part in parts) {
    if (current is! Map) return null;
    current = current[part];
  }
  return current;
}
```

---

## API-7: `transaction()` con join automático (transacciones anidadas)

**Problema:** Las transacciones anidadas lanzan una excepción:

```dart
await db.transaction(() async {
  await db.insert(doc1);
  await db.transaction(() async { // ← StateError: Nested transactions not supported
    await db.insert(doc2);
  });
});
```

**Propuesta mínima — join the outer transaction:**
```dart
Future<T> transaction<T>(Future<T> Function() fn) {
  if (_inTransaction) {
    // Ya estamos en una transacción → simplemente ejecutar sin crear nueva
    return fn();
  }
  // ... lógica actual de transacción ...
}
```

Esto es suficiente para la mayoría de los casos y es no-breaking.

---

## API-8: `db.name` — identificador de la instancia

**Problema:** No hay forma de identificar qué instancia de DB está causando un error:

```dart
// Error actual:
// Bad state: Cannot perform operations on a closed database.
// ← Sin saber qué DB, qué operación, ni por qué se cerró
```

**Propuesta:**
```dart
class FastDB {
  final String? name; // ← NUEVO (opcional para no romper API)
  
  // En init():
  static Future<FastDB> init(
    StorageStrategy storage, {
    String? name, // ← NUEVO
    // ...
  }) async {
    final db = FastDB._internal(storage, name: name);
    // ...
  }
}

// Uso:
final db = await FastDB.init(storage, name: 'users_db');
// Error ahora dice: Bad state: Cannot perform "findById" on closed DB "users_db"
```

---

## Resumen de Propuestas

| # | Feature | Esfuerzo | Impacto | Prioridad |
|---|---------|----------|---------|-----------|
| API-1 | `upsert()` / `upsertWhere()` | Bajo | 🔴 Alto | **Alta** |
| API-2 | `findByIds(List<int>)` público | Muy bajo | 🔴 Alto | **Alta** |
| API-3 | `watchDocs()` stream de documentos | Bajo | 🔴 Alto | **Alta** |
| API-4 | `QueryBuilder.watch()` fluido | Medio | 🟡 Medio | Media |
| API-5 | `debugQueryPlan` global | Muy bajo | 🟢 Bajo | Baja |
| API-6 | Dot-notation en índices | Alto | 🔴 Alto | Media |
| API-7 | Transacciones anidadas (join) | Muy bajo | 🟡 Medio | Media |
| API-8 | `db.name` en instancia | Muy bajo | 🟡 Medio | Media |

---

## Compatibilidad Hacia Atrás

Todas las propuestas son **aditivas** — no rompen código existente:

- `upsert()` es un método nuevo, no modifica `insert()`/`update()`
- `findByIds()` es una exposición de funcionalidad interna existente
- `watchDocs()` es un wrapper sobre `watch()` existente
- `QueryBuilder.watch()` es un nuevo método, `find()` sigue igual
- `transaction()` con join solo cambia el comportamiento del caso que antes lanzaba error
- `db.name` es un campo opcional con valor por defecto `null`
