/// Abstract interface for secondary indexes.
abstract class SecondaryIndex {
  /// Name of the field this index covers.
  String get fieldName;

  /// Adds a document ID → field value mapping to the index.
  void add(int docId, dynamic fieldValue);

  /// Removes a document ID from the index.
  void remove(int docId, dynamic fieldValue);

  /// Removes a document ID from ALL value buckets (used when field value is unknown).
  void removeById(int docId);

  /// Returns all document IDs matching [value].
  List<int> lookup(dynamic value);

  /// Returns all document IDs whose value is between [low] and [high].
  List<int> range(dynamic low, dynamic high);

  /// Returns all (value, docId) pairs sorted by value.
  List<MapEntry<dynamic, List<int>>> sorted({bool descending = false});

  /// Returns all document IDs stored in this index.
  List<int> all();

  /// Returns the total number of indexed (docId, value) pairs.
  /// Used by the query planner for cost estimation.
  int get size;

  /// Clears all entries from this index.
  /// Called by FastDB during crash recovery to rebuild the index from documents.
  void clear();
}
