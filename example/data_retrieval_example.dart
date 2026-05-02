import 'dart:convert';
import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';

/// Ejemplo completo de cómo se ven los datos al recuperarlos de FastDB
void main() async {
  final db = await FfastDb.init(MemoryStorageStrategy());

  // ──────────────────────────────────────────────────────────────────────────
  // 1. INSERTAR DATOS
  // ──────────────────────────────────────────────────────────────────────────
  
  print('═══════════════════════════════════════════════════');
  print('📥 INSERTANDO DATOS');
  print('═══════════════════════════════════════════════════\n');
  
  final id = await db.insert({
    'id': 'firebase_user_abc123',  // ID de Firebase (se preserva)
    'name': 'Juan Pérez',
    'age': 35,
    'salary': 75000.50,
    'isActive': true,
    'email': 'juan@example.com',
    'createdAt': DateTime(2024, 1, 15, 10, 30, 0),
    'location': {
      'latitude': 19.4326,
      'longitude': -99.1332,
      'city': 'Ciudad de México',
    },
    'roles': ['admin', 'user', 'moderator'],
    'metadata': {
      'department': 'Engineering',
      'level': 5,
      'remote': true,
    },
    'tags': ['premium', 'verified'],
    'lastLogin': null,
  });

  print('✅ Documento insertado con ID interno: $id\n');

  // ──────────────────────────────────────────────────────────────────────────
  // 2. RECUPERAR POR ID - findById()
  // ──────────────────────────────────────────────────────────────────────────
  
  print('═══════════════════════════════════════════════════');
  print('🔍 RECUPERANDO POR ID (findById)');
  print('═══════════════════════════════════════════════════\n');
  
  final doc = await db.findById(id);
  
  print('Tipo de dato: ${doc.runtimeType}');  // Map<String, dynamic>
  print('\n📄 DOCUMENTO COMPLETO:');
  print(doc);
  
  print('\n📊 ACCEDIENDO A CAMPOS INDIVIDUALES:\n');
  
  // String
  print('ID Interno de FastDB (ffdbID): ${doc['ffdbID']}');
  print('ID de Firebase ("id" original): "${doc['id']}"');
  print('  → Tipo de ID original: ${doc['id'].runtimeType}');
  
  // String
  print('\nNombre: "${doc['name']}"');
  print('  → Tipo: ${doc['name'].runtimeType}');
  
  // int
  print('\nEdad: ${doc['age']}');
  print('  → Tipo: ${doc['age'].runtimeType}');
  
  // double
  print('\nSalario: ${doc['salary']}');
  print('  → Tipo: ${doc['salary'].runtimeType}');
  
  // bool
  print('\nActivo: ${doc['isActive']}');
  print('  → Tipo: ${doc['isActive'].runtimeType}');
  
  // DateTime
  final createdAt = doc['createdAt'] as DateTime;
  print('\nCreado en: $createdAt');
  print('  → Tipo: ${createdAt.runtimeType}');
  print('  → Año: ${createdAt.year}');
  print('  → Mes: ${createdAt.month}');
  print('  → Día: ${createdAt.day}');
  print('  → Hora: ${createdAt.hour}:${createdAt.minute}');
  
  // Map (location)
  final location = doc['location'] as Map;
  print('\nUbicación:');
  print('  → Latitud: ${location['latitude']}');
  print('  → Longitud: ${location['longitude']}');
  print('  → Ciudad: ${location['city']}');
  
  // List
  final roles = doc['roles'] as List;
  print('\nRoles: $roles');
  print('  → Tipo: ${roles.runtimeType}');
  print('  → Cantidad: ${roles.length}');
  print('  → Primer rol: ${roles[0]}');
  print('  → Último rol: ${roles.last}');
  
  // Map anidado
  final metadata = doc['metadata'] as Map;
  print('\nMetadata:');
  print('  → Departamento: ${metadata['department']}');
  print('  → Nivel: ${metadata['level']}');
  print('  → Remoto: ${metadata['remote']}');
  
  // null
  print('\nÚltimo login: ${doc['lastLogin']}');
  print('  → Es null: ${doc['lastLogin'] == null}');

  // ──────────────────────────────────────────────────────────────────────────
  // 3. INSERTAR MÚLTIPLES DOCUMENTOS
  // ──────────────────────────────────────────────────────────────────────────
  
  print('\n═══════════════════════════════════════════════════');
  print('📥 INSERTANDO MÚLTIPLES USUARIOS');
  print('═══════════════════════════════════════════════════\n');
  
  db.addIndex('city');  // Agregar índice para consultas
  
  await db.insertAll([
    {
      'name': 'Ana García',
      'city': 'Madrid',
      'age': 28,
      'score': 95.5,
      'active': true,
    },
    {
      'name': 'Carlos López',
      'city': 'Barcelona',
      'age': 32,
      'score': 87.3,
      'active': true,
    },
    {
      'name': 'María Rodríguez',
      'city': 'Madrid',
      'age': 25,
      'score': 92.1,
      'active': false,
    },
  ]);

  // ──────────────────────────────────────────────────────────────────────────
  // 4. CONSULTAS - find() / findWhere()
  // ──────────────────────────────────────────────────────────────────────────
  
  print('═══════════════════════════════════════════════════');
  print('🔎 CONSULTAS CON ÍNDICES');
  print('═══════════════════════════════════════════════════\n');
  
  // Buscar por ciudad
  final madridUsers = await db.find((q) => 
    q.where('city').equals('Madrid').findIds()
  );
  
  print('Usuarios en Madrid (${madridUsers.length}):');
  for (final user in madridUsers) {
    print('  • ${user['name']} - ${user['age']} años - Score: ${user['score']}');
  }

  // ──────────────────────────────────────────────────────────────────────────
  // 5. ITERAR SOBRE RESULTADOS
  // ──────────────────────────────────────────────────────────────────────────
  
  print('\n═══════════════════════════════════════════════════');
  print('🔁 ITERANDO SOBRE RESULTADOS');
  print('═══════════════════════════════════════════════════\n');
  
  // rangeSearch devuelve List<int> de IDs
  final allIds = await db.rangeSearch(1, 100);
  
  print('Total de documentos: ${allIds.length}\n');
  
  for (var i = 0; i < allIds.length && i < 5; i++) {
    final user = await db.findById(allIds[i]);
    if (user == null) continue;
    
    print('Usuario ${i + 1}:');
    
    // Acceso seguro a campos
    final name = user['name'] ?? 'Sin nombre';
    final age = user['age'] ?? 0;
    final city = user['city'] ?? 'Sin ciudad';
    final isActive = user['active'] ?? user['isActive'] ?? false;
    
    print('  Nombre: $name');
    print('  Edad: $age años');
    print('  Ciudad: $city');
    print('  Estado: ${isActive ? "✅ Activo" : "❌ Inactivo"}');
    print('');
  }

  // ──────────────────────────────────────────────────────────────────────────
  // 6. MANIPULACIÓN DE DATOS RECUPERADOS
  // ──────────────────────────────────────────────────────────────────────────
  
  print('═══════════════════════════════════════════════════');
  print('🔧 MANIPULANDO DATOS RECUPERADOS');
  print('═══════════════════════════════════════════════════\n');
  
  // Los datos se pueden manipular como cualquier Map/List de Dart
  final firstDoc = doc;  // Usar el documento recuperado anteriormente
  
  // Verificar existencia de campos
  if (firstDoc.containsKey('salary')) {
    print('✅ El documento tiene campo "salary"');
  }
  
  // Obtener claves
  print('\nCampos del documento: ${firstDoc.keys.toList()}');
  
  // Filtrar campos
  final publicData = Map.fromEntries(
    firstDoc.entries.where((e) => !['salary', 'metadata'].contains(e.key))
  );
  print('\nDatos públicos (sin salary/metadata): ${publicData.keys.toList()}');
  
  // Transformar datos
  final summary = {
    'fullName': firstDoc['name'],
    'years': firstDoc['age'],
    'coordinates': '${firstDoc['location']['latitude']}, ${firstDoc['location']['longitude']}',
    'roleCount': (firstDoc['roles'] as List).length,
  };
  print('\nResumen transformado: $summary');

  // ──────────────────────────────────────────────────────────────────────────
  // 7. TIPOS DE FIREBASE RECUPERADOS
  // ──────────────────────────────────────────────────────────────────────────
  
  print('\n═══════════════════════════════════════════════════');
  print('🔥 DATOS DE FIREBASE RECUPERADOS');
  print('═══════════════════════════════════════════════════\n');
  
  // GeoPoint se recupera como Map
  final geoDoc = await db.insert({
    'name': 'Oficina Central',
    'location': {
      'latitude': 40.7128,
      'longitude': -74.0060,
    },
  });
  
  final office = await db.findById(geoDoc);
  final loc = office['location'] as Map;
  
  print('📍 Ubicación recuperada:');
  print('  → Estructura: Map<String, dynamic>');
  print('  → Latitud: ${loc['latitude']} (${loc['latitude'].runtimeType})');
  print('  → Longitud: ${loc['longitude']} (${loc['longitude'].runtimeType})');
  
  // Timestamp/DateTime se recupera como DateTime
  print('\n📅 Fecha recuperada:');
  final timestamp = firstDoc['createdAt'] as DateTime;
  print('  → Tipo: ${timestamp.runtimeType}');
  print('  → Formato: ${timestamp.toIso8601String()}');
  print('  → Timestamp: ${timestamp.millisecondsSinceEpoch}ms');

  // ──────────────────────────────────────────────────────────────────────────
  // 8. CONVERSIÓN A JSON
  // ──────────────────────────────────────────────────────────────────────────
  
  print('\n═══════════════════════════════════════════════════');
  print('📤 EXPORTAR A JSON');
  print('═══════════════════════════════════════════════════\n');
  
  // Los documentos se pueden serializar directamente a JSON
  final jsonString = jsonEncode({
    ...firstDoc,
    'createdAt': (firstDoc['createdAt'] as DateTime).toIso8601String(),
  });
  
  print('JSON exportado:');
  print(jsonString);
  
  // Y deserializar de vuelta
  final parsed = jsonDecode(jsonString) as Map<String, dynamic>;
  print('\nJSON parseado:');
  print('  → Nombre: ${parsed['name']}');
  print('  → Fecha: ${parsed['createdAt']}');

  await FfastDb.disposeInstance();
  
  print('\n═══════════════════════════════════════════════════');
  print('✅ EJEMPLO COMPLETADO');
  print('═══════════════════════════════════════════════════');
}
