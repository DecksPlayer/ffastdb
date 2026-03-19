import 'dart:typed_data';

/// A fixed-capacity LRU (Least Recently Used) cache for database pages.
/// 
/// Internally uses a doubly-linked list + HashMap to achieve O(1) get/put.
/// When the cache is full, the least recently used page is evicted.
class LruCache {
  final int capacity;
  
  final Map<int, _Node> _map = {};
  final _Node _head = _Node(-1, Uint8List(0)); // dummy head
  final _Node _tail = _Node(-1, Uint8List(0)); // dummy tail

  int _hits = 0;
  int _misses = 0;

  LruCache({this.capacity = 128}) {
    _head.next = _tail;
    _tail.prev = _head;
  }

  /// Returns the cached page for [pageIndex], or null on cache miss.
  Uint8List? get(int pageIndex) {
    final node = _map[pageIndex];
    if (node == null) {
      _misses++;
      return null;
    }
    _hits++;
    _moveToFront(node);
    return node.data;
  }

  /// Stores [data] in the cache for [pageIndex].
  /// Evicts the LRU entry if at capacity.
  void put(int pageIndex, Uint8List data) {
    if (_map.containsKey(pageIndex)) {
      final node = _map[pageIndex]!;
      node.data = data;
      _moveToFront(node);
      return;
    }

    if (_map.length >= capacity) {
      // Evict least recently used (node before tail)
      final lru = _tail.prev!;
      if (lru != _head) {
        _removeNode(lru);
        _map.remove(lru.key);
      }
    }

    final newNode = _Node(pageIndex, data);
    _map[pageIndex] = newNode;
    _insertAfterHead(newNode);
  }

  /// Invalidates a cached page (e.g., after a write).
  void invalidate(int pageIndex) {
    final node = _map.remove(pageIndex);
    if (node != null) _removeNode(node);
  }

  /// Clears the cache.
  void clear() {
    _map.clear();
    _head.next = _tail;
    _tail.prev = _head;
    _hits = 0;
    _misses = 0;
  }

  double get hitRate {
    final total = _hits + _misses;
    return total == 0 ? 0.0 : _hits / total;
  }

  int get size => _map.length;

  @override
  String toString() =>
      'LruCache(size: $size/$capacity, hitRate: ${(hitRate * 100).toStringAsFixed(1)}%)';

  // ─── Doubly-linked list helpers ──────────────────────────────────────────

  void _moveToFront(_Node node) {
    _removeNode(node);
    _insertAfterHead(node);
  }

  void _removeNode(_Node node) {
    node.prev?.next = node.next;
    node.next?.prev = node.prev;
  }

  void _insertAfterHead(_Node node) {
    node.next = _head.next;
    node.prev = _head;
    _head.next?.prev = node;
    _head.next = node;
  }
}

class _Node {
  final int key;
  Uint8List data;
  _Node? prev;
  _Node? next;

  _Node(this.key, this.data);
}
