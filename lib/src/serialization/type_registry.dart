import 'type_adapter.dart';

class TypeRegistry {
  TypeRegistry();

  final Map<int, TypeAdapter> _adapters = {};
  final Map<Type, int> _typeToId = {};

  void registerAdapter<T>(TypeAdapter<T> adapter) {
    if (_adapters.containsKey(adapter.typeId)) {
      final existing = _adapters[adapter.typeId]!;
      if (existing.runtimeType != adapter.runtimeType) {
        throw ArgumentError(
            'TypeAdapter conflict: typeId ${adapter.typeId} is already registered '
            'for ${existing.runtimeType}. Each adapter must have a unique typeId. '
            '${adapter.runtimeType} must use a different typeId.');
      }
    }
    _adapters[adapter.typeId] = adapter;
    _typeToId[T] = adapter.typeId;
  }

  TypeAdapter? getAdapter(int typeId) => _adapters[typeId];

  int? getTypeId(Type type) => _typeToId[type];

  /// Entry point for serializing any registered type.
  void write<T>(BinaryWriter writer, T obj) {
    final typeId = getTypeId(T) ?? getTypeId(obj.runtimeType);
    if (typeId == null) {
      // Fallback to dynamic if not registered
      writer.writeDynamic(obj);
      return;
    }

    writer.writeUint16(typeId);
    _adapters[typeId]!.write(writer, obj);
  }

  /// Entry point for deserializing any registered type.
  dynamic read(BinaryReader reader) {
    final typeId = reader.readUint16();
    final adapter = _adapters[typeId];
    if (adapter == null) {
      throw UnsupportedError('No adapter registered for type ID: $typeId');
    }
    return adapter.read(reader);
  }
}
