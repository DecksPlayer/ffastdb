# Tipos de Datos Soportados en FastDB

FastDB soporta de forma nativa todos los tipos de datos comunes de Dart y Firebase, con serialización/deserialización automática y eficiente.

## ✅ Tipos de Datos Nativos de Dart

### 1. **Int** - Enteros de 64 bits
```dart
final doc = {
  'age': 30,
  'count': 1000000,
  'negative': -42,
  'maxInt64': 9223372036854775807,
};
await db.insert(doc);
```

### 2. **Double** - Números de punto flotante
```dart
final doc = {
  'price': 99.99,
  'pi': 3.14159265359,
  'scientific': 1.23e-10,
  'percentage': 0.75,
};
await db.insert(doc);
```

### 3. **String** - Cadenas de texto
```dart
final doc = {
  'name': 'Alice',
  'email': 'alice@example.com',
  'unicode': '你好🌍',
  'multiline': 'Line 1\nLine 2\nLine 3',
};
await db.insert(doc);
```

### 4. **Char** - Caracteres individuales
En Dart no existe un tipo `char` separado, pero se maneja como `String` de longitud 1:
```dart
final doc = {
  'initial': 'A',
  'symbol': '@',
  'emoji': '😀',
};
await db.insert(doc);
```

### 5. **Boolean** - Valores lógicos
```dart
final doc = {
  'isActive': true,
  'isDeleted': false,
  'hasPermission': true,
};
await db.insert(doc);
```

### 6. **DateTime** - Fechas y horas (Timestamp)
```dart
final doc = {
  'createdAt': DateTime.now(),
  'birthDate': DateTime(1990, 5, 15),
  'utcTime': DateTime.utc(2025, 6, 15, 12, 0),
};
await db.insert(doc);
```

### 7. **Null** - Valores nulos
```dart
final doc = {
  'name': 'John',
  'middleName': null,
  'nickname': null,
};
await db.insert(doc);
```

### 8. **List** - Arreglos y listas
```dart
final doc = {
  'tags': ['developer', 'designer', 'manager'],
  'scores': [95, 87, 92, 88],
  'matrix': [[1, 2, 3], [4, 5, 6]],
};
await db.insert(doc);
```

### 9. **Map** - Objetos y mapas
```dart
final doc = {
  'user': {
    'name': 'Alice',
    'age': 30,
    'address': {
      'city': 'New York',
      'zipCode': '10001',
    },
  },
};
await db.insert(doc);
```

## 🔥 Tipos de Firebase (Duck-typing automático)

FastDB detecta y convierte automáticamente los tipos de Firebase sin necesidad de importar `cloud_firestore`:

### 10. **Firebase Timestamp** → DateTime
```dart
// Firebase Timestamp se convierte automáticamente a DateTime
final firebaseTimestamp = Timestamp.now(); // de Firebase
final doc = {
  'createdAt': firebaseTimestamp,
};
await db.insert(doc);

final retrieved = await db.findById(id);
// retrieved['createdAt'] es un DateTime nativo de Dart
```

### 11. **GeoPoint** → Location (latitude/longitude)
```dart
// GeoPoint se convierte a un Map con latitude y longitude
final geoPoint = GeoPoint(34.0522, -118.2437); // de Firebase
final doc = {
  'location': geoPoint,
};
await db.insert(doc);

final retrieved = await db.findById(id);
// retrieved['location'] = {'latitude': 34.0522, 'longitude': -118.2437}
```

O directamente como mapa:
```dart
final doc = {
  'location': {
    'latitude': 40.7128,
    'longitude': -74.0060,
  },
};
await db.insert(doc);
```

### 12. **DocumentReference** → String (path)
```dart
// DocumentReference se convierte al path como String
final docRef = firestore.collection('users').doc('abc123');
final doc = {
  'reference': docRef,
};
await db.insert(doc);

final retrieved = await db.findById(id);
// retrieved['reference'] = 'users/abc123'
```

### 13. **Blob** → Uint8List
```dart
// Blob de Firebase se convierte a Uint8List
final blob = Blob(bytes);
final doc = {
  'data': blob,
};
await db.insert(doc);
```

## 📊 Tipos Complejos y Anidados

FastDB soporta estructuras de datos complejas con cualquier nivel de anidamiento:

```dart
final complexDoc = {
  'id': 'user_123',
  'name': 'John Doe',
  'age': 35,
  'salary': 75000.50,
  'isActive': true,
  'createdAt': DateTime(2023, 1, 15),
  'lastLogin': null,
  'location': {
    'latitude': 37.7749,
    'longitude': -122.4194,
  },
  'roles': ['admin', 'user'],
  'metadata': {
    'department': 'Engineering',
    'level': 5,
    'remote': true,
    'projects': ['Project A', 'Project B'],
  },
  'history': [
    {'action': 'login', 'timestamp': DateTime.now()},
    {'action': 'update', 'timestamp': DateTime.now()},
  ],
};

await db.insert(complexDoc);
```

## 🔄 Conversión Automática

FastDB convierte automáticamente entre tipos cuando es necesario:

1. **Objetos con `toJson()`**: Clases que implementan `toJson()` se serializan automáticamente
2. **Firebase types**: Detección por duck-typing (sin imports necesarios)
3. **Uint8List**: Se codifica como Base64 internamente
4. **Valores desconocidos**: Se convierten a String con `toString()`

## ⚡ Rendimiento

- **Serialización binaria eficiente**: Tipos nativos (int, double, bool) se serializan directamente en formato binario
- **Sin overhead JSON**: Los tipos primitivos no pasan por JSON
- **Compatible con Web**: Funciona en Flutter Web sin problemas

## ✅ Resumen

| Tipo        | Soportado | Notas                                    |
|-------------|-----------|------------------------------------------|
| int         | ✅        | 64 bits, positivos y negativos           |
| double      | ✅        | Punto flotante de 64 bits                |
| string      | ✅        | UTF-8, Unicode completo                  |
| char        | ✅        | Como String de longitud 1                |
| boolean     | ✅        | true/false                               |
| DateTime    | ✅        | Timestamp con precisión de milisegundos  |
| timestamp   | ✅        | Como DateTime                            |
| location    | ✅        | Como Map {latitude, longitude}           |
| null        | ✅        | Valores nulos                            |
| List        | ✅        | Arrays de cualquier tipo                 |
| Map         | ✅        | Objetos y mapas anidados                 |
| Uint8List   | ✅        | Datos binarios                           |
| Firebase *  | ✅        | Timestamp, GeoPoint, DocumentRef, Blob   |

**Nota**: FastDB es compatible con Firebase sin necesidad de importar `cloud_firestore`. La detección de tipos se hace mediante duck-typing.

## 📝 Ejemplos de Uso

Ver el archivo [test/data_types_test.dart](test/data_types_test.dart) para ejemplos completos de todos los tipos de datos soportados.
