import 'dart:convert';
import 'dart:typed_data';
import 'type_adapter.dart';

const int _typeNull = 0;
const int _typeInt = 1;
const int _typeString = 2;
const int _typeBool = 3;
const int _typeList = 4;
const int _typeMap = 5;
const int _typeDouble = 6;

class FastBinaryWriter implements BinaryWriter {
  final BytesBuilder _builder = BytesBuilder();

  Uint8List get result => _builder.toBytes();

  @override
  void writeUint8(int value) => _builder.addByte(value);

  @override
  void writeUint16(int value) {
    _builder.addByte(value & 0xFF);
    _builder.addByte((value >> 8) & 0xFF);
  }

  @override
  void writeUint32(int value) {
    _builder.addByte(value & 0xFF);
    _builder.addByte((value >> 8) & 0xFF);
    _builder.addByte((value >> 16) & 0xFF);
    _builder.addByte((value >> 24) & 0xFF);
  }

  @override
  void writeString(String value) {
    final bytes = utf8.encode(value);
    writeUint32(bytes.length);
    _builder.add(bytes);
  }

  @override
  void writeByteList(Uint8List value) {
    writeUint32(value.length);
    _builder.add(value);
  }

  @override
  void writeDynamic(dynamic value) {
    if (value == null) {
      writeUint8(_typeNull);
    } else if (value is int) {
      writeUint8(_typeInt);
      // Write as 64-bit little-endian to avoid truncation of large integers
      final bd = ByteData(8);
      bd.setInt64(0, value, Endian.little);
      _builder.add(bd.buffer.asUint8List());
    } else if (value is double) {
      writeUint8(_typeDouble);
      final bd = ByteData(8);
      bd.setFloat64(0, value, Endian.little);
      _builder.add(bd.buffer.asUint8List());
    } else if (value is String) {
      writeUint8(_typeString);
      writeString(value);
    } else if (value is bool) {
      writeUint8(_typeBool);
      writeUint8(value ? 1 : 0);
    } else if (value is List) {
      writeUint8(_typeList);
      writeUint32(value.length);
      for (var item in value) {
        writeDynamic(item);
      }
    } else if (value is Map) {
      writeUint8(_typeMap);
      writeUint32(value.length);
      value.forEach((k, v) {
        writeDynamic(k);
        writeDynamic(v);
      });
    } else {
      // Potentially a custom object if we had a registry here
      throw UnsupportedError('Unsupported type: ${value.runtimeType}');
    }
  }
}

class FastBinaryReader implements BinaryReader {
  final Uint8List _data;
  int _offset = 0;

  FastBinaryReader(this._data);

  @override
  int readUint8() => _data[_offset++];

  @override
  int readUint16() {
    final val = _data[_offset] | (_data[_offset + 1] << 8);
    _offset += 2;
    return val;
  }

  @override
  int readUint32() {
    final val = _data[_offset] | 
                (_data[_offset + 1] << 8) | 
                (_data[_offset + 2] << 16) | 
                (_data[_offset + 3] << 24);
    _offset += 4;
    return val;
  }

  @override
  String readString() {
    final len = readUint32();
    final str = utf8.decode(_data.sublist(_offset, _offset + len));
    _offset += len;
    return str;
  }

  @override
  Uint8List readByteList() {
    final len = readUint32();
    final list = _data.sublist(_offset, _offset + len);
    _offset += len;
    return list;
  }

  @override
  dynamic readDynamic() {
    final type = readUint8();
    switch (type) {
      case _typeNull: return null;
      case _typeInt:
        final bd = ByteData(8);
        for (int i = 0; i < 8; i++) {
          bd.setUint8(i, _data[_offset + i]);
        }
        _offset += 8;
        return bd.getInt64(0, Endian.little);
      case _typeDouble:
        final bd = ByteData(8);
        for (int i = 0; i < 8; i++) {
          bd.setUint8(i, _data[_offset + i]);
        }
        _offset += 8;
        return bd.getFloat64(0, Endian.little);
      case _typeString: return readString();
      case _typeBool: return readUint8() == 1;
      case _typeList:
        final len = readUint32();
        return List.generate(len, (_) => readDynamic());
      case _typeMap:
        final len = readUint32();
        final map = <dynamic, dynamic>{};
        for (var i = 0; i < len; i++) {
          final k = readDynamic();
          final v = readDynamic();
          map[k] = v;
        }
        return map;
      default:
        throw UnsupportedError('Unsupported type ID: $type');
    }
  }
}
