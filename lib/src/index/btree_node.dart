import 'dart:typed_data';

/// Maximum keys per B-Tree node. Order = T means max 2T-1 keys per node.
/// With 4096 page size: header(5) + maxKeys*4 + maxVals*8 <= 4096
/// Using order 100: 199 keys * 4 + 200 vals * 8 = 796 + 1600 = 2396 bytes  
const int kBTreeOrder = 100;
const int kMaxKeys = 2 * kBTreeOrder - 1; // 199
const int kMinKeys = kBTreeOrder - 1; // 99

/// Represents a node in the B-Tree.
/// Layout in 4096-byte page:
///   [0]         isLeaf (1 byte)
///   [1..4]      numKeys (4 bytes, LE)
///   [5..N]      keys: numKeys * 4 bytes (uint32 LE)
///   [N+1..M]    values: (numKeys + (isLeaf ? 0 : 1)) * 8 bytes (uint64 LE)
class BTreeNode {
  final int pageIndex;
  bool isLeaf;
  final List<int> keys;
  final List<int> values; // Leaf: physical offsets. Internal: child page indexes.

  BTreeNode({
    required this.pageIndex,
    required this.isLeaf,
    required this.keys,
    required this.values,
  });

  bool get isFull => keys.length >= kMaxKeys;
  bool get isDeficient => keys.length < kMinKeys;

  /// Serializes the node into a provided buffer or a new 4096-byte page.
  Uint8List serialize({Uint8List? buffer}) {
    final data = buffer ?? Uint8List(4096);
    final bd = ByteData.view(data.buffer, data.offsetInBytes, data.lengthInBytes);

    bd.setUint8(0, isLeaf ? 1 : 0);
    bd.setUint32(1, keys.length, Endian.little);

    int off = 5;
    for (final k in keys) {
      bd.setUint32(off, k, Endian.little);
      off += 4;
    }

    // Internal nodes have numKeys+1 children; leaves have numKeys values
    for (final v in values) {
      // Store as two 32-bit halves for compatibility (safe for offsets up to 2^53)
      bd.setUint32(off, v & 0xFFFFFFFF, Endian.little);
      bd.setUint32(off + 4, (v >> 32) & 0xFFFFFFFF, Endian.little);
      off += 8;
    }

    return data;
  }

  factory BTreeNode.deserialize(int pageIndex, Uint8List data) {
    // Basic sanity check: uninitialized pages (all zeros) are not valid nodes.
    // We check the first 5 bytes (leaf flag + count).
    if (data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 0 && data[4] == 0) {
      return BTreeNode(
        pageIndex: pageIndex,
        isLeaf: true,
        keys: [],
        values: [],
      );
    }
    // Use data.offsetInBytes so the view is correct even for non-zero-base slices.
    final bd = ByteData.view(data.buffer, data.offsetInBytes, data.lengthInBytes);
    final isLeaf = bd.getUint8(0) == 1;
    final count = bd.getUint32(1, Endian.little);

    // Pre-allocate with the known count to avoid repeated List growths.
    final keys = List<int>.filled(count, 0, growable: true);
    final valCount = isLeaf ? count : count + 1;
    final values = List<int>.filled(valCount, 0, growable: true);

    int off = 5;
    for (int i = 0; i < count; i++) {
      if (off + 4 > data.length) break;
      keys[i] = bd.getUint32(off, Endian.little);
      off += 4;
    }

    for (int i = 0; i < valCount; i++) {
      if (off + 8 > data.length) break;
      final lo = bd.getUint32(off, Endian.little);
      final hi = bd.getUint32(off + 4, Endian.little);
      values[i] = lo | (hi << 32);
      off += 8;
    }

    return BTreeNode(
      pageIndex: pageIndex,
      isLeaf: isLeaf,
      keys: keys,
      values: values,
    );
  }
}
