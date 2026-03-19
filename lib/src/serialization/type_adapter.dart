import 'dart:typed_data';

/// Base class for Hive-like type adapters.
abstract class TypeAdapter<T> {
  /// The unique ID for this type.
  int get typeId;

  /// Writes an object of type [T] to the binary stream.
  void write(BinaryWriter writer, T obj);

  /// Reads an object of type [T] from the binary stream.
  T read(BinaryReader reader);
}

/// Helper to write binary data.
abstract class BinaryWriter {
  void writeUint8(int value);
  void writeUint16(int value);
  void writeUint32(int value);
  void writeString(String value);
  void writeByteList(Uint8List value);
  void writeDynamic(dynamic value);
}

/// Helper to read binary data.
abstract class BinaryReader {
  int readUint8();
  int readUint16();
  int readUint32();
  String readString();
  Uint8List readByteList();
  dynamic readDynamic();
}
