import 'dart:typed_data';

/// Shared table-driven CRC32 (IEEE 802.3, polynomial 0xEDB88320).
///
/// The previous bit-wise implementation cost ~8 operations per byte on the
/// hot path (every document write + read verification + every WAL entry).
/// The 256-entry table makes it ~1 lookup + 2 ops per byte (4-8x faster).
final Uint32List _crc32Table = _buildTable();

Uint32List _buildTable() {
  final table = Uint32List(256);
  for (int n = 0; n < 256; n++) {
    int c = n;
    for (int k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB88320 : c >> 1;
    }
    table[n] = c;
  }
  return table;
}

/// Computes the CRC32 of [data] (same result as the bit-wise reference
/// implementation: init 0xFFFFFFFF, reflected, final XOR 0xFFFFFFFF).
int crc32(Uint8List data) {
  int crc = 0xFFFFFFFF;
  final table = _crc32Table;
  for (int i = 0; i < data.length; i++) {
    crc = table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}
