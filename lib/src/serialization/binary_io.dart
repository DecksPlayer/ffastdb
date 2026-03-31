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
const int _typeDateTime = 7;

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
      // ByteData.setInt64 is not supported by dart2js (Flutter Web).
      // Split into two 32-bit writes; maintains the same little-endian byte layout.
      final bd = ByteData(8);
      final lo = value & 0xFFFFFFFF; // lower 32 bits (may be signed in JS)
      final loUnsigned = lo < 0 ? lo + 0x100000000 : lo;
      final hi = (value - loUnsigned) ~/ 0x100000000; // upper 32 bits
      bd.setInt32(0, lo, Endian.little);
      bd.setInt32(4, hi, Endian.little);
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
    } else if (value is DateTime) {
      writeUint8(_typeDateTime);
      final bd = ByteData(8);
      final ms = value.millisecondsSinceEpoch;
      final lo = ms & 0xFFFFFFFF;
      final loUnsigned = lo < 0 ? lo + 0x100000000 : lo;
      final hi = (ms - loUnsigned) ~/ 0x100000000;
      bd.setInt32(0, lo, Endian.little);
      bd.setInt32(4, hi, Endian.little);
      _builder.add(bd.buffer.asUint8List());
    } else if (value is Uint8List) {
      writeUint8(_typeString);
      // Encode as Base64 string so it round-trips cleanly
      writeString('\u0000bl:${base64Encode(value)}');
    } else {
      // Try Firebase duck-typing before giving up.
      // 1) Timestamp → DateTime
      try {
        final dt = (value as dynamic).toDate() as DateTime;
        writeDynamic(dt);
        return;
      } catch (_) {}
      // 2) GeoPoint → {latitude, longitude} map
      try {
        final lat = ((value as dynamic).latitude as num).toDouble();
        final lng = ((value as dynamic).longitude as num).toDouble();
        writeDynamic(<String, dynamic>{'latitude': lat, 'longitude': lng});
        return;
      } catch (_) {}
      // 3) DocumentReference → path string
      try {
        final path = (value as dynamic).path as String;
        writeDynamic(path);
        return;
      } catch (_) {}
      // 4) Blob → Uint8List
      try {
        final bytes = (value as dynamic).bytes as Uint8List;
        writeDynamic(bytes);
        return;
      } catch (_) {}
      // 5) Objects with toJson() (application model classes)
      try {
        final map = (value as dynamic).toJson() as Map<String, dynamic>;
        writeDynamic(map);
        return;
      } catch (_) {}
      // Last resort: store as string so the document is never lost
      writeDynamic(value.toString());
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
        // ByteData.getInt64 is not supported by dart2js; reconstruct from two Int32 reads.
        final lo = bd.getInt32(0, Endian.little);
        final loUnsigned = lo < 0 ? lo + 0x100000000 : lo;
        final hi = bd.getInt32(4, Endian.little);
        return hi * 0x100000000 + loUnsigned;
      case _typeDouble:
        final bd = ByteData(8);
        for (int i = 0; i < 8; i++) {
          bd.setUint8(i, _data[_offset + i]);
        }
        _offset += 8;
        return bd.getFloat64(0, Endian.little);
      case _typeString:
        final s = readString();
        // Check for binary sentinel prefix used by FastBinaryWriter.writeDynamic()
        if (s.startsWith('\u0000bl:')) {
          return base64Decode(s.substring(4)); // Skip '\u0000bl:'
        }
        return s;
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
      case _typeDateTime:
        final bdDt = ByteData(8);
        for (int i = 0; i < 8; i++) {
          bdDt.setUint8(i, _data[_offset + i]);
        }
        _offset += 8;
        // ByteData.getInt64 is not supported by dart2js; reconstruct from two Int32 reads.
        final dtLo = bdDt.getInt32(0, Endian.little);
        final dtLoUnsigned = dtLo < 0 ? dtLo + 0x100000000 : dtLo;
        final dtHi = bdDt.getInt32(4, Endian.little);
        return DateTime.fromMillisecondsSinceEpoch(
            dtHi * 0x100000000 + dtLoUnsigned);
      default:
        throw UnsupportedError('Unsupported type ID: $type');
    }
  }
}
