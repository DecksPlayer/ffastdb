# Evolución de Llaves: Migración a ffdbID

## Problema Original
Cuando se guardaban datos provenientes de Firebase (u otras fuentes) en FastDB, el campo `id` original se perdía porque FastDB sobrescribía ese campo con su propio ID interno numérico. Inicialmente esto se solucionó creando un parche temporal (_originalId) en memoria durante la serialización/deserialización, lo cual introducía complejidad innecesaria.

## Solución Definitiva (Migración)
Se decidió migrar el nombre de la clave interna de FastDB de `id` a `ffdbID`. Esta mejora a nivel arquitectónico evita cualquier colisión desde la base:

### Durante la Serialización (_serialize)
1. FastDB inyecta su propio ID numérico exclusivamente bajo la llave `ffdbID`.
2. Si el usuario provee un documento con la llave `id`, esta permanece completamente intacta. No hay necesidad de variables temporales.

### Durante la Deserialización (_readAt)
1. Se cuenta con un helper de migración migrateLegacyDoc que garantiza la retrocompatibilidad: si se detecta un documento antiguo que no posea `ffdbID` pero sí un `id` interno numérico, se lee y se restaura al nuevo formato al vuelo. Esto incluye el correcto mapeo de vuelta del antiguo parche _originalId de ser necesario.

## Archivos Modificados
- lib/src/fastdb.dart: Métodos _serialize y _readAt (se consolidó y limpió).
- 	est/fastdb_test.dart: Se actualizó el grupo de pruebas "Firebase ID preservation" validando las inserciones convencionales y preservación natural del ID.
- xample/data_retrieval_example.dart: Se actualizó el ejemplo para demostrar la consistencia de traer tanto fdbID como el id configurado por el usuario.

## Compatibilidad
- ✅ **Retrocompatible**: Base de datos antiguas migran el registro automáticamente durante la lectura individual.
- ✅ **Sin breaking changes en documentos**: Los documentos de usuario retienen totalmente sus propiedades. Solo las menciones directas al ID generado por la base de datos se alteran.

## Ejemplo de Uso
`dart
// Documento de Firebase con su propio ID
final firebaseDoc = {
  'id': 'firebase_user_abc123',
  'name': 'Alice',
};

// Insertar en FastDB
final fastdbId = await db.insert(firebaseDoc);  // FastDB asigna ID interno: 1, bajo ffdbID

// Recuperar documento
final retrieved = await db.findById(fastdbId);

// Ambos existen en paz:
print(retrieved['ffdbID']); // 1
print(retrieved['id']);     // 'firebase_user_abc123'
`

## Fecha
2 de mayo de 2026
