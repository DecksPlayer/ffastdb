/// FFastDB annotations — used to mark Dart classes and fields for the
/// database engine.
///
/// These annotations serve as documentation today and will drive code
/// generation in a future release (similar to how `@HiveType`/`@HiveField`
/// drive `hive_generator`).
///
/// Example:
/// ```dart
/// @FFastDB(typeId: 0)
/// class Person {
///   @FFastId()
///   int? id;
///
///   @FFastField(0)
///   String name;
///
///   @FFastField(1)
///   @FFastIndex(sorted: true)
///   int age;
///
///   @FFastField(2)
///   @FFastIndex()
///   String city;
/// }
/// ```
library;

// ─── Class-level annotation ───────────────────────────────────────────────

/// Marks a Dart class as a FFastDB model / collection.
///
/// [typeId] must be unique across all registered adapters in the same
/// database — identical to `@HiveType(typeId: n)`.
class FFastDB {
  /// Unique adapter identifier (0–255).
  final int typeId;
  const FFastDB({required this.typeId});
}

// ─── Field-level annotations ──────────────────────────────────────────────

/// Marks the integer primary-key field of the collection.
///
/// The field type must be `int` or `int?`.  FFastDB auto-assigns an
/// incrementing value when inserting, identical to Isar's `@Id`.
class FFastId {
  const FFastId();
}

/// Associates a field with a stable serialization slot [n].
///
/// The slot number is preserved across schema changes, so old data can
/// still be decoded even after fields are renamed or reordered — identical
/// to `@HiveField(n)`.
///
/// Slot numbers must be unique within the same class (0–255).
class FFastField {
  /// The stable slot number for this field.
  final int n;
  const FFastField(this.n);
}

/// Creates a secondary index on the annotated field.
///
/// - [sorted] = `false` (default): O(1) hash index — best for equality
///   lookups (`where('city').equals('Paris')`).
/// - [sorted] = `true`: O(log n) sorted index — supports range queries
///   and `sortBy` (`where('age').between(20, 30)`).
/// - [bitmask] = `true`: bitmask index — best for low-cardinality boolean
///   or enum fields.
///
/// Corresponds to FFastDB's `addIndex()` / `addSortedIndex()` /
/// `addBitmaskIndex()` runtime calls.
class FFastIndex {
  /// Use a sorted (B-Tree-like) index for range / sort queries.
  final bool sorted;

  /// Use a bitmask index (best for low-cardinality fields like booleans).
  final bool bitmask;

  const FFastIndex({this.sorted = false, this.bitmask = false});
}
