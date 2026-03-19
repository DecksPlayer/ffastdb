import 'dart:convert';
import 'dart:typed_data';

/// Handles fast binary serialization for documents.
class FastSerializer {
  /// A fused JSON→UTF-8 encoder that produces bytes directly without
  /// allocating an intermediate JSON [String].  Re-used across calls.
  static final _fused = const JsonEncoder().fuse(const Utf8Encoder());

  /// Serializes a Map to a JSON-UTF8 binary byte array.
  /// Includes a 4-byte header for the length.
  static Uint8List serialize(Map<String, dynamic> doc) {
    final utf8Data = _fused.convert(doc);
    final data = Uint8List(4 + utf8Data.length);
    
    // Manual Little Endian write for length at the VERY BEGINNING
    data[0] = utf8Data.length & 0xFF;
    data[1] = (utf8Data.length >> 8) & 0xFF;
    data[2] = (utf8Data.length >> 16) & 0xFF;
    data[3] = (utf8Data.length >> 24) & 0xFF;
    
    data.setRange(4, 4 + utf8Data.length, utf8Data);
    
    return data;
  }

  static Map<String, dynamic> deserialize(Uint8List data) {
    if (data.length < 4) throw ArgumentError('Data too short');
    
    // Manual Little Endian read
    final length = (data[0] & 0xFF) | 
                   ((data[1] & 0xFF) << 8) | 
                   ((data[2] & 0xFF) << 16) | 
                   ((data[3] & 0xFF) << 24);
    
    if (data.length < 4 + length) {
      throw ArgumentError('Data is truncated: expected offset ${4 + length}, but got ${data.length}');
    }
    
    final jsonData = data.sublist(4, 4 + length);
    final jsonStr = utf8.decode(jsonData);
    
    return jsonDecode(jsonStr) as Map<String, dynamic>;
  }
}
