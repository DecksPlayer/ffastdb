# Análisis de Problemas de Garbage Collection y Memory Leaks en FastDB

**Fecha de Análisis**: 24 de marzo de 2026

---

## 🔴 PROBLEMAS CRÍTICOS ENCONTRADOS

### 1. **Memory Leak en `_deletedCount` - Nunca se reinicia**

**Ubicación**: `lib/src/fastdb.dart`

**Problema**:
```dart
int _deletedCount = 0;

// Se incrementa en delete(), update(), put()
_deletedCount++;

// PERO: _deletedCount NUNCA se resetea después de compact()
```

**Impacto**: 
- El contador `_deletedCount` crece indefinidamente
- Aunque se ejecute `compact()`, el contador NO se reinicia
- Causa llamadas innecesarias a `_maybeAutoCompact()` después de cada compactación
- En aplicaciones de larga duración, puede causar compactaciones excesivas

**Código Afectado**:
```dart
// fastdb.dart línea ~1036
if (_autoCompactThreshold > 0 && !_inTransaction && !_batchMode) {
  await _maybeAutoCompact();  // Se llama incluso después de compact()
}

Future<void> _maybeAutoCompact() async {
  final liveCount = await count();
  if (liveCount == 0) return;
  
  final ratio = _deletedCount / (liveCount + _deletedCount);
  if (ratio >= _autoCompactThreshold) {
    await compact();
    // ❌ FALTA: _deletedCount = 0;
  }
}
```

**Solución**: Resetear `_deletedCount = 0` después de `compact()`

---

### 2. **StreamControllers en Singleton no se limpian automáticamente**

**Ubicación**: `lib/src/fastdb.dart`

**Problema**:
```dart
static FastDB? _instance;

final Map<String, StreamController<List<int>>> _watchers = {};

// Si se usa el singleton y se llama disposeInstance(),
// los watchers SE cierran, pero si el usuario guarda una referencia
// al singleton y sigue usándolo, los watchers cerrados causan errores
```

**Escenario Problemático**:
```dart
// Usuario guarda referencia
final db = await FfastDb.init(storage);

// Más tarde, otro código llama:
await FfastDb.disposeInstance();  // Cierra watchers

// Pero el usuario todavía tiene 'db' y hace:
db.watch('field').listen(...);  // ❌ StreamController ya cerrado
```

**Impacto**:
- Estado inconsistente si se usa singleton después de dispose
- No hay protección contra uso después de dispose
- Puede causar excepciones `Bad state: Cannot add event after closing`

**Solución**: Agregar flag `_isClosed` y verificar en todas las operaciones

---

### 3. **Cache LRU sin límite efectivo en `_dirtyPages`**

**Ubicación**: `lib/src/storage/page_manager.dart`

**Problema**:
```dart
final LruCache _cache;  // ✅ Tiene límite (128 páginas)
final Map<int, Uint8List> _dirtyPages = {};  // ❌ SIN LÍMITE

// En modo write-behind:
Future<void> writePage(int pageIndex, Uint8List data) {
  _cache.put(pageIndex, data);
  if (writeBehind) {
    _dirtyPages[pageIndex] = data;  // ❌ Puede crecer infinitamente
    return _doneFuture;
  }
}
```

**Impacto**:
- En modo `write-behind`, `_dirtyPages` puede crecer sin límite
- Si se hacen muchas escrituras sin `flushDirty()`, consumo de RAM ilimitado
- Cada página es 4KB, 10,000 páginas = 40MB, 100,000 páginas = 400MB
- No hay mecanismo de flush automático por tamaño de _dirtyPages

**Escenario**:
```dart
db._enableWriteBehind();  // Activa write-behind
for (int i = 0; i < 100000; i++) {
  await db.insert(largeDoc);  // Acumula páginas dirty
  // Sin flush automático, _dirtyPages crece sin control
}
```

**Solución**: Flush automático cuando `_dirtyPages.length > threshold`

---

### 4. **Índices Secundarios sin límite de memoria**

**Ubicación**: `lib/src/index/hash_index.dart`, `sorted_index.dart`, etc.

**Problema**:
```dart
class HashIndex {
  final Map<dynamic, List<int>> _map = {};  // ❌ Sin límite
  final Map<int, dynamic> _reverse = {};    // ❌ Sin límite
  
  void add(int docId, dynamic fieldValue) {
    _map.putIfAbsent(fieldValue, () => <int>[]).add(docId);
    _reverse[docId] = fieldValue;
    _size++;  // Crece indefinidamente
  }
}
```

**Impacto**:
- Los índices secundarios mantienen TODOS los valores en RAM
- Con millones de documentos, puede consumir gigabytes de RAM
- No hay opción para índices parciales o paginados
- No hay límite de memoria configurable

**Cálculo de Memoria**:
- 1 millón de docs con índice en 'email' (String ~30 chars)
- _map: ~30 bytes × 1M = 30MB
- _reverse: ~8 bytes × 1M = 8MB
- Lists overhead: variable
- **Total por índice: ~50-100MB**
- Con 5 índices: **250-500MB en RAM**

**Solución**: Considerar índices en disco o límites configurables

---

### 5. **Referencias Circulares Potenciales**

**Ubicación**: `lib/src/index/btree.dart`

**Problema Potencial**:
```dart
class BTree {
  final PageManager _pageManager;
  
  // BTree mantiene referencia a PageManager
  // PageManager mantiene referencia a StorageStrategy
  // Si hay watchers o callbacks, pueden crear ciclos
}
```

**Impacto**: 
- Dart tiene GC generacional, pero referencias circulares pueden retrasar la limpieza
- No es crítico en Dart moderno, pero puede causar retención temporal de memoria

---

## ⚠️ PROBLEMAS MENORES

### 6. **`_batchEntries` no tiene límite de memoria**

**Ubicación**: `lib/src/fastdb.dart`

```dart
final List<MapEntry<int, int>> _batchEntries = [];

// Durante insertAll():
for (final doc in docs) {
  _batchEntries.add(MapEntry(id, offset));  // Sin límite
}
```

**Impacto**:
- En `insertAll()` con millones de docs, `_batchEntries` crece sin control
- Cada MapEntry ~16 bytes, 1M entries = 16MB
- No crítico pero puede optimizarse con batch size límite

---

### 7. **Sin mecanismo de memory pressure**

**Problema**:
- No hay monitoreo de memoria disponible
- No hay mecanismo para reducir cache bajo presión de memoria
- No hay eventos de low-memory para limpiar recursos

**Solución**: Implementar callback de memory warning (especialmente en Flutter)

---

## ✅ ASPECTOS BIEN IMPLEMENTADOS

### 1. **StreamControllers con auto-cleanup**
```dart
ctrl = StreamController<List<int>>.broadcast(
  onCancel: () {
    ctrl.close();
    _watchers.remove(field);  // ✅ Se limpia automáticamente
  },
);
```

### 2. **LRU Cache con límite estricto**
```dart
if (_map.length >= capacity) {
  final lru = _tail.prev!;
  _removeNode(lru);
  _map.remove(lru.key);  // ✅ Eviction correcta
}
```

### 3. **Método close() completo**
```dart
Future<void> close() async {
  await _pageManager.flushDirty();
  await storage.close();
  await dataStorage?.close();
  for (final c in _watchers.values) {
    await c.close();  // ✅ Limpia todos los streams
  }
}
```

---

## 📊 RESUMEN DE SEVERIDAD

| Problema | Severidad | Probabilidad | Impacto |
|----------|-----------|--------------|---------|
| `_deletedCount` no se resetea | 🔴 Alta | 100% | Compactaciones innecesarias |
| `_dirtyPages` sin límite | 🔴 Alta | Media | OOM en apps de larga duración |
| Índices sin límite RAM | 🟡 Media | Alta | Consumo RAM alto con millones de docs |
| Singleton post-dispose | 🟡 Media | Baja | Crashes si se usa mal |
| `_batchEntries` sin límite | 🟢 Baja | Baja | RAM temporal en batch grandes |

---

## 🔧 RECOMENDACIONES PRIORITARIAS

### Prioridad 1 (Críticas)
1. ✅ **FIX: Resetear `_deletedCount` después de `compact()`**
2. ✅ **FIX: Añadir flush automático cuando `_dirtyPages` exceda threshold**
3. ✅ **FIX: Agregar flag `_isClosed` y validación en singleton**

### Prioridad 2 (Mejoras)
4. Documentar límites de memoria de índices secundarios
5. Agregar opción de `maxIndexMemory` configurable
6. Implementar batch size límite en `insertAll()`

### Prioridad 3 (Optimizaciones)
7. Considerar índices en disco para datasets grandes
8. Implementar memory pressure callbacks
9. Agregar métricas de uso de memoria (`getMemoryStats()`)

---

## 📝 EJEMPLOS DE ESCENARIOS PROBLEMÁTICOS

### Escenario 1: Aplicación de Larga Duración
```dart
// App móvil que corre días/semanas
final db = await FfastDb.init(storage, autoCompactThreshold: 0.3);

// Después de 1 semana de uso:
// - 100,000 inserts
// - 50,000 deletes
// _deletedCount = 50,000 (NUNCA se resetea)

// Cada operación verifica:
if (_deletedCount / (liveCount + _deletedCount) >= 0.3) {
  await compact();  // ❌ Se ejecuta cada vez
  // _deletedCount SIGUE en 50,000
}
```

### Escenario 2: Batch Insert Masivo
```dart
db._enableWriteBehind();

// Insertar 1 millón de documentos
for (int i = 0; i < 1_000_000; i++) {
  await db.insert({'data': 'x' * 1000});
  // _dirtyPages crece: 250,000 páginas × 4KB = 1GB RAM
  // ❌ Sin flush automático
}

await db.flushDirty();  // Finalmente libera
```

---

## 🧪 TESTS RECOMENDADOS

```dart
test('deletedCount resets after compact', () async {
  final db = FastDB(MemoryStorageStrategy());
  await db.open();
  
  final id = await db.insert({'x': 1});
  await db.delete(id);
  
  expect(db._deletedCount, 1);  // ❌ Campo privado
  
  await db.compact();
  
  // ✅ DEBERÍA ser 0 después de compact
  expect(db._deletedCount, 0);
});

test('dirtyPages has memory limit', () async {
  final db = FastDB(MemoryStorageStrategy());
  db._enableWriteBehind();
  
  for (int i = 0; i < 10000; i++) {
    await db.insert({'data': 'x' * 1000});
  }
  
  // ✅ DEBERÍA hacer flush automático
  expect(db._pageManager._dirtyPages.length, lessThan(1000));
});
```

---

## 💡 CONCLUSIÓN

FastDB tiene una arquitectura sólida, pero tiene **3 problemas críticos de GC**:

1. ❌ `_deletedCount` causa compactaciones infinitas
2. ❌ `_dirtyPages` puede causar OOM
3. ❌ Índices sin límite pueden consumir GB de RAM

Los otros problemas son menores y solo afectan casos específicos.

**Recomendación**: Implementar las correcciones de Prioridad 1 ASAP.
