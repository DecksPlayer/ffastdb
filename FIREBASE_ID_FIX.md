# Corrección de Preservación de ID de Firebase

## Problema
Cuando se guardaban datos provenientes de Firebase en FastDB, el campo `id` original de Firebase se perdía porque FastDB sobrescribía ese campo con su propio ID interno numérico.

## Solución Implementada
Se modificó el sistema de serialización/deserialización de FastDB para preservar automáticamente los IDs originales:

### Durante la Serialización (`_serialize`)
1. Antes de sobrescribir el campo `id` con el ID interno de FastDB, se verifica si ya existe un campo `id` en el documento
2. Si existe y es diferente al ID de FastDB, se guarda en un campo temporal `_originalId`
3. Se procede con la serialización normal

### Durante la Deserialización (`_readAt` y `_readAtSync`)
1. Después de deserializar el documento, se verifica si existe el campo `_originalId`
2. Si existe, se restaura al campo `id` y se elimina `_originalId`
3. El usuario recupera su ID original de Firebase

## Archivos Modificados
- `lib/src/fastdb.dart`: Métodos `_serialize`, `_readAt`, y `_readAtSync`

## Pruebas Agregadas
Se agregaron 4 pruebas en `test/fastdb_test.dart` bajo el grupo "Firebase ID preservation":
1. Preservación del ID de Firebase en documentos con campo `id`
2. Persistencia del ID a través de operaciones de actualización
3. Manejo normal de documentos sin campo `id`
4. Soporte para diferentes tipos de IDs de Firebase (string, numérico, paths)

## Compatibilidad
- ✅ **Retrocompatible**: Los documentos existentes sin campo `id` funcionan igual
- ✅ **Sin breaking changes**: No se requieren cambios en código existente
- ✅ **Transparente**: La conversión es automática y no requiere configuración

## Ejemplo de Uso
```dart
// Documento de Firebase con su propio ID
final firebaseDoc = {
  'id': 'firebase_user_abc123',
  'name': 'Alice',
  'email': 'alice@example.com',
};

// Insertar en FastDB
final fastdbId = await db.insert(firebaseDoc);  // FastDB asigna ID interno: 1

// Recuperar documento
final retrieved = await db.findById(fastdbId);

// El ID original de Firebase se preserva
print(retrieved['id']);  // 'firebase_user_abc123'
print(retrieved['name']); // 'Alice'
```

## Fecha
20 de marzo de 2026
