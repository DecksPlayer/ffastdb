import 'dart:math';

/// Bloom Filter: A space-efficient probabilistic data structure for membership testing.
///
/// Provides O(1) lookup with configurable false positive rate (no false negatives).
/// Perfect for "definitely not contains" checks in queries.
///
/// Memory usage: ~10 bits per element for 1% false positive rate
/// vs HashSet which uses ~200+ bits per element on typical platforms.
///
/// Usage:
/// ```dart
/// final bf = BloomFilter<int>(expectedSize: 10000, falsePositiveRate: 0.01);
/// bf.add(42);
/// if (!bf.mightContain(42)) {
///   // Item is definitely not in the set
/// }
/// ```
class BloomFilter<T> {
  /// Bit array backing the filter
  late List<int> _bits;

  /// Size of the bit array in bits
  late int _bitSize;

  /// Number of hash functions to use
  late int _numHashFunctions;

  /// Number of elements added
  int _count = 0;

  /// Creates a Bloom Filter with given capacity and false positive rate.
  ///
  /// [expectedSize]: Expected number of elements to be added
  /// [falsePositiveRate]: Desired false positive rate (0.0 to 1.0)
  BloomFilter({required int expectedSize, double falsePositiveRate = 0.01}) {
    // Calculate optimal bit array size: -1/ln(2)^2 * n * ln(p)
    // where n = expectedSize, p = falsePositiveRate
    _bitSize =
        (-1 * expectedSize * (log(falsePositiveRate) / log(2.0)))
            .ceil();
    if (_bitSize < 64) _bitSize = 64; // Minimum size

    // Calculate optimal number of hash functions: (m/n) * ln(2)
    // where m = bitSize, n = expectedSize
    _numHashFunctions = ((_bitSize / expectedSize) * 0.693147).ceil();
    if (_numHashFunctions < 1) _numHashFunctions = 1;
    if (_numHashFunctions > 8) _numHashFunctions = 8;

    // Initialize bit array (use int List for efficiency)
    // Each int is 64 bits on most platforms
    _bits = List<int>.filled((_bitSize + 63) ~/ 64, 0);
  }

  /// Adds an element to the filter.
  void add(T item) {
    final hashes = _getHashes(item);
    for (final hash in hashes) {
      final bitIndex = hash % _bitSize;
      final wordIndex = bitIndex ~/ 64;
      final bitOffset = bitIndex % 64;
      _bits[wordIndex] |= (1 << bitOffset);
    }
    _count++;
  }

  /// Tests if an element might be in the filter.
  ///
  /// Returns true if element might be present (or false positive)
  /// Returns false if element is definitely not present
  bool mightContain(T item) {
    final hashes = _getHashes(item);
    for (final hash in hashes) {
      final bitIndex = hash % _bitSize;
      final wordIndex = bitIndex ~/ 64;
      final bitOffset = bitIndex % 64;
      if ((_bits[wordIndex] & (1 << bitOffset)) == 0) {
        return false; // Definitely not in set
      }
    }
    return true; // Might be in set
  }

  /// Gets hash values for an item using different seed offsets.
  List<int> _getHashes(T item) {
    final hashes = <int>[];
    final baseHash = item.hashCode;

    // Use different seeds to simulate multiple hash functions
    for (int i = 0; i < _numHashFunctions; i++) {
      // Combine base hash with seed offset
      final hash = (baseHash ^ (i * 2654435761)).abs();
      hashes.add(hash);
    }

    return hashes;
  }

  /// Returns the current number of elements added.
  int get count => _count;

  /// Returns the bit array size in bits.
  int get bitSize => _bitSize;

  /// Returns the number of hash functions.
  int get numHashFunctions => _numHashFunctions;

  /// Estimates the current false positive probability.
  double get estimatedFalsePositiveRate {
    if (_count == 0) return 0.0;
    // (1 - e^(-k*n/m))^k where k = numHashFunctions, n = count, m = bitSize
    final exponent = (-_numHashFunctions * _count) / _bitSize;
    final base = 1.0 - exp(exponent);
    return base * base; // Approximate
  }

  /// Clears all bits in the filter.
  void clear() {
    for (int i = 0; i < _bits.length; i++) {
      _bits[i] = 0;
    }
    _count = 0;
  }
}
