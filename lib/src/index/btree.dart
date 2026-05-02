import '../storage/page_manager.dart';
import 'btree_node.dart';

/// Full B-Tree implementation with node splitting.
/// This gives us true O(log n) insert and search performance.
class BTree {
  final PageManager pageManager;
  int? rootPage;

  /// Deserialized node object cache — avoids re-allocating `List<int>` objects
  /// on every _readNode call for pages that are already in the LRU page cache.
  /// Updated on every _writeNode so it is always coherent with storage.
  /// `LinkedHashMap` maintains insertion order so .keys.first is O(1) FIFO eviction.
  final Map<int, BTreeNode> _nodeCache = <int, BTreeNode>{};
  static const int _nodeCacheCapacity = 512;

  BTree(this.pageManager);

  // ─── Search ───────────────────────────────────────────────────────────────
  /// Fully synchronous search — returns the stored value when every node on
  /// the path is already in the node cache, or null if a cache miss occurs
  /// (key not found OR a node was evicted).  Callers must fall back to the
  /// async [search] when this returns null.
  int? searchSync(int key) {
    if (rootPage == null || rootPage == 0) return null;
    int pageIdx = rootPage!;
    final visited = <int>{pageIdx};
    while (true) {
      final node = _nodeCache[pageIdx];
      if (node == null) return null; // cache miss — caller falls back to async
      final i = _lowerBound(node.keys, key);
      if (i < node.keys.length && node.keys[i] == key) {
        if (node.isLeaf) return node.values[i];
        pageIdx = node.values[i + 1];
      } else if (node.isLeaf) {
        return null;
      } else {
        pageIdx = node.values[i];
      }
      if (pageIdx == 0 || !visited.add(pageIdx)) return null;
    }
  }
  /// Returns the value (offset) for [key], or null if not found.
  /// Uses the synchronous node cache on hot paths to avoid microtask bouncing.
  Future<int?> search(int key) async {
    if (rootPage == null || rootPage == 0) return null;
    int pageIdx = rootPage!;
    final visited = <int>{pageIdx};
    while (true) {
      BTreeNode? node = _readNodeSync(pageIdx);
      node ??= await _readNode(pageIdx); // async only on cold-cache miss
      final i = _lowerBound(node.keys, key);
      if (i < node.keys.length && node.keys[i] == key) {
        if (node.isLeaf) return node.values[i];
        pageIdx = node.values[i + 1]; // follow right child
      } else if (node.isLeaf) {
        return null; // not found
      } else {
        pageIdx = node.values[i]; // follow left child
      }
      if (pageIdx == 0 || !visited.add(pageIdx)) {
        // Corrupt tree: child points to page 0 or forms a cycle.
        return null; 
      }
    }
  }

  // ─── Insert ───────────────────────────────────────────────────────────────

  /// Inserts [key] → [value]. Automatically splits nodes when full.
  Future<void> insert(int key, int value) async {
    if (rootPage == null || rootPage == 0) {
      // First insert: create the root leaf node.
      final page = await pageManager.allocatePage();
      final root = BTreeNode(
        pageIndex: page,
        isLeaf: true,
        keys: [key],
        values: [value],
      );
      await _writeNode(root);
      rootPage = page;
      return;
    }

    BTreeNode? root = _readNodeSync(rootPage!);
    root ??= await _readNode(rootPage!);

    if (root.isFull) {
      // Root is full → split it and create a new root
      final newRootPage = await pageManager.allocatePage();
      final newRoot = BTreeNode(
        pageIndex: newRootPage,
        isLeaf: false,
        keys: [],
        values: [rootPage!], // Old root becomes child 0
      );
      await _splitChild(newRoot, 0, root);
      await _insertNonFull(newRoot, key, value);
      rootPage = newRootPage;
    } else {
      await _insertNonFull(root, key, value);
    }
  }

  /// Inserts into a node that is guaranteed NOT full.
  ///
  /// Implemented **iteratively** to avoid stack overflows on deep trees or
  /// when a corrupt WAL leaves circular page-pointer references in the B-Tree.
  /// A [visited] set catches any page cycle and throws a clear [StateError]
  /// instead of recursing until the Dart VM crashes.
  Future<void> _insertNonFull(BTreeNode startNode, int key, int value) async {
    BTreeNode node = startNode;
    final visited = <int>{node.pageIndex};

    while (!node.isLeaf) {
      // Cycle detection — corrupt tree guard.
      int i = _upperBound(node.keys, key);

      BTreeNode? child = _readNodeSync(node.values[i]);
      child ??= await _readNode(node.values[i]);

      if (child.isFull) {
        await _splitChild(node, i, child);
        // After split: node gained a new separator at keys[i].
        // Choose which half to descend into.
        if (i < node.keys.length && key >= node.keys[i]) i++;
      }

      int childPage = node.values[i];
      if (childPage == 0) {
        throw StateError(
          'FastDB BTree: circular page reference detected at page 0. '
          'The database file may be corrupt. Delete the .fdb and .fdb.wal files to start fresh.',
        );
      }

      BTreeNode? targetChild = _readNodeSync(childPage);
      targetChild ??= await _readNode(childPage);

      // Cycle detection — stop before infinite descent.
      if (!visited.add(targetChild.pageIndex)) {
        throw StateError(
          'FastDB BTree: circular page reference detected at page '
          '${targetChild.pageIndex}. The database file may be corrupt. '
          'Delete the .fdb and .fdb.wal files to start fresh.',
        );
      }

      node = targetChild;
    }

    // node is now a leaf — insert here.
    final pos = _lowerBound(node.keys, key);
    if (pos < node.keys.length && node.keys[pos] == key) {
      // Update existing key in-place; no shift needed.
      node.values[pos] = value;
    } else {
      // Insert preserving order; List.insert is native O(n) memmove.
      node.keys.insert(pos, key);
      node.values.insert(pos, value);
    }
    await _writeNode(node);
  }

  /// Bulk-loads the B-Tree from a sorted list of entries (ID -> Offset).
  ///
  /// When the tree is empty this is a fast O(N) bottom-up build.
  /// When the tree already has data:
  ///   - If tree is small (< 500 entries): extract, merge, rebuild (safe memory usage).
  ///   - If tree is large: use individual inserts (avoids OOM from extracting all entries).
  /// This avoids both orphaning existing pages and losing median keys during splits.
  Future<void> bulkLoad(List<MapEntry<int, int>> sortedEntries) async {
    if (sortedEntries.isEmpty) return;

    List<MapEntry<int, int>> allEntries;
    if (rootPage != null && rootPage != 0) {
      // BUG FIX: If tree already has data, count existing entries first to decide strategy.
      // Small tree (<500 entries) → extract and merge with new batch.
      // Large tree (≥500 entries) → use individual inserts to avoid OOM.
      final existingCount = await _countLeafEntries(rootPage!);
      if (existingCount < 500) {
        final existing = <MapEntry<int, int>>[];
        await _extractLeafEntries(rootPage!, existing);
        allEntries = _mergeSorted(existing, sortedEntries);
      } else {
        // Fall back to individual inserts for large trees (avoids OOM from bulk extraction).
        for (final entry in sortedEntries) {
          await insert(entry.key, entry.value);
        }
        return;
      }
    } else {
      allEntries = sortedEntries;
    }

    if (allEntries.isEmpty) return;

    // ── Fast O(N) bulk build ─────────────────────────────────────────────────
    // 1. Build Leaf Layer
    final targetFill = (kMaxKeys * 0.9).floor();
    final leafPages = <int>[];
    final separatorKeys = <int>[]; // First key of each leaf (except first)

    for (int i = 0; i < allEntries.length; i += targetFill) {
      final end = (i + targetFill < allEntries.length)
          ? i + targetFill
          : allEntries.length;
      final chunk = allEntries.sublist(i, end);

      final page = await pageManager.allocatePage();
      final node = BTreeNode(
        pageIndex: page,
        isLeaf: true,
        keys: chunk.map((e) => e.key).toList(),
        values: chunk.map((e) => e.value).toList(),
      );
      await _writeNode(node);
      leafPages.add(page);
      if (i > 0) separatorKeys.add(chunk[0].key);
    }

    // 2. Build Internal Layers Recursively
    rootPage = await _buildInternalLayer(leafPages, separatorKeys);
  }

  /// Counts the total number of entries (key-value pairs) in all leaf nodes.
  /// Used to decide whether to extract+merge or use individual inserts.
  Future<int> _countLeafEntries(int pageIdx, [Set<int>? visited]) async {
    visited ??= {};
    if (!visited.add(pageIdx)) return 0;
    
    final node = await _readNode(pageIdx);
    if (node.isLeaf) {
      return node.keys.length;
    }
    int total = 0;
    for (final childPage in node.values) {
      if (childPage > 0) total += await _countLeafEntries(childPage, visited);
    }
    return total;
  }

  /// Recursively visits all leaf nodes and collects their (key, value) entries
  /// in ascending key order.
  Future<void> _extractLeafEntries(int pageIdx, List<MapEntry<int, int>> out, [Set<int>? visited]) async {
    visited ??= {};
    if (!visited.add(pageIdx)) return;
    
    final node = await _readNode(pageIdx);
    if (node.isLeaf) {
      for (int i = 0; i < node.keys.length; i++) {
        out.add(MapEntry(node.keys[i], node.values[i]));
      }
    } else {
      for (final childPage in node.values) {
        if (childPage > 0) await _extractLeafEntries(childPage, out, visited);
      }
    }
  }

  /// O(N+M) sorted merge of two sorted entry lists.
  /// When both lists contain the same key, [b]'s entry wins (newer offset).
  static List<MapEntry<int, int>> _mergeSorted(
      List<MapEntry<int, int>> a, List<MapEntry<int, int>> b) {
    final result = <MapEntry<int, int>>[];
    int ia = 0, ib = 0;
    while (ia < a.length && ib < b.length) {
      if (a[ia].key < b[ib].key) {
        result.add(a[ia++]);
      } else if (a[ia].key > b[ib].key) {
        result.add(b[ib++]);
      } else {
        result.add(b[ib++]); // newer entry wins
        ia++;
      }
    }
    while (ia < a.length) result.add(a[ia++]);
    while (ib < b.length) result.add(b[ib++]);
    return result;
  }

  Future<int> _buildInternalLayer(List<int> childPages, List<int> separators) async {
    if (childPages.length == 1) return childPages[0];

    final targetFill = (kMaxKeys * 0.9).floor();
    final parentPages = <int>[];
    final parentSeparators = <int>[];

    // numKeys = targetFill. numValues = targetFill + 1.
    final childrenPerNode = targetFill + 1;

    int childIdx = 0; // index into childPages

    while (childIdx < childPages.length) {
      final remaining = childPages.length - childIdx;
      final take = remaining < childrenPerNode ? remaining : childrenPerNode;

      final nodeChildren = childPages.sublist(childIdx, childIdx + take);
      
      // The keys in an internal node are the separators for children 1..N.
      // Child 0 is the "leftmost" child and has no separator to its left in this node.
      // The separator between child J-1 and child J is separators[childIdx + J - 1].
      final nodeKeys = <int>[];
      for (int j = 1; j < take; j++) {
        nodeKeys.add(separators[childIdx + j - 1]);
      }

      final page = await pageManager.allocatePage();
      final node = BTreeNode(
        pageIndex: page,
        isLeaf: false,
        keys: nodeKeys,
        values: nodeChildren,
      );
      await _writeNode(node);
      parentPages.add(page);

      // The separator to promote to the parent layer is the one that would 
      // have been between the last child of this node and the first child 
      // of the NEXT node in this layer.
      if (childIdx + take < childPages.length) {
        parentSeparators.add(separators[childIdx + take - 1]);
      }
      
      childIdx += take;
    }

    return _buildInternalLayer(parentPages, parentSeparators);
  }

  /// Splits the [fullChild] (child i of [parent]) into two nodes,
  /// promoting the median key up into [parent].
  Future<void> _splitChild(BTreeNode parent, int i, BTreeNode fullChild) async {
    final t = kBTreeOrder;
    final mid = t - 1; // index of median key

    // New node takes the right half of fullChild
    final newPage = await pageManager.allocatePage();
    final rightNode = BTreeNode(
      pageIndex: newPage,
      isLeaf: fullChild.isLeaf,
      keys: List.from(fullChild.keys.sublist(mid)),
      values: List.from(fullChild.values.sublist(mid)),
    );

    // Promote median key to parent
    final medianKey = rightNode.keys.first;

    if (fullChild.isLeaf) {
      // B+Tree style: keep median in the right child, remove from left
      fullChild.keys.removeRange(mid, fullChild.keys.length);
      fullChild.values.removeRange(mid, fullChild.values.length);
    } else {
      // B-Tree style: move median up, it's not needed in children
      rightNode.keys.removeAt(0);
      rightNode.values.removeAt(0);
      fullChild.keys.removeRange(mid, fullChild.keys.length);
      fullChild.values.removeRange(mid + 1, fullChild.values.length);
    }

    // Insert median into parent at position i
    parent.keys.insert(i, medianKey);
    parent.values.insert(i + 1, newPage);

    await _writeNode(fullChild);
    await _writeNode(rightNode);
    await _writeNode(parent);
  }

  // ─── Delete ──────────────────────────────────────────────────────────────

  /// Deletes [key] from the B-Tree using full CLRS-style deletion:
  /// - Internal-node separators are replaced with in-order predecessor/successor.
  /// - Children are rebalanced (borrow from sibling or merge) before descending
  ///   so no node is left under-full.
  /// - An empty internal root is collapsed to its sole child.
  Future<void> delete(int key) async {
    if (rootPage == null || rootPage == 0) return;
    await _delete(rootPage!, key);
    // Collapse an empty internal root — its only child becomes the new root.
    final root = await _readNode(rootPage!);
    if (root.keys.isEmpty && !root.isLeaf) {
      rootPage = root.values.first;
    }
  }

  Future<void> _delete(int pageIdx, int key) async {
    final node = await _readNode(pageIdx);
    int i = _lowerBound(node.keys, key);

    if (i < node.keys.length && node.keys[i] == key) {
      if (node.isLeaf) {
        // Case 1: key lives in this leaf — remove directly.
        node.keys.removeAt(i);
        node.values.removeAt(i);
        await _writeNode(node);
      } else {
        // Case 2: key is a separator in an internal node.
        final leftChild  = await _readNode(node.values[i]);
        final rightChild = await _readNode(node.values[i + 1]);

        if (leftChild.keys.length >= kBTreeOrder) {
          // Case 2a: replace with in-order predecessor (max of left subtree).
          final pred = await _getPredecessor(node.values[i]);
          node.keys[i] = pred;
          await _writeNode(node);
          await _delete(node.values[i], pred);
        } else if (rightChild.keys.length >= kBTreeOrder) {
          // Case 2b: replace with in-order successor (min of right subtree).
          final succ = await _getSuccessor(node.values[i + 1]);
          node.keys[i] = succ;
          await _writeNode(node);
          await _delete(node.values[i + 1], succ);
        } else {
          // Case 2c: both children at minimum — merge, then delete from merged node.
          await _merge(node, i);
          // After merge, node.values[i] is the merged child; key is now inside it.
          await _delete(node.values[i], key);
        }
      }
    } else if (!node.isLeaf) {
      // Key not in this node — descend into child i.
      // Ensure the child has strictly more than the minimum keys so it can
      // absorb a deletion without going under-full.
      final child = await _readNode(node.values[i]);
      if (child.keys.length < kBTreeOrder) {
        i = await _fill(node, i);
      }
      // _fill mutates `node` in-place; no re-read needed.
      await _delete(node.values[i], key);
    }
    // else: leaf and key not found — nothing to delete.
  }

  /// Returns the largest key in the subtree rooted at [pageIdx].
  Future<int> _getPredecessor(int pageIdx) async {
    var node = await _readNode(pageIdx);
    while (!node.isLeaf) {
      node = await _readNode(node.values.last);
    }
    return node.keys.last;
  }

  /// Returns the smallest key in the subtree rooted at [pageIdx].
  Future<int> _getSuccessor(int pageIdx) async {
    var node = await _readNode(pageIdx);
    while (!node.isLeaf) {
      node = await _readNode(node.values.first);
    }
    return node.keys.first;
  }

  /// Ensures [parent.values[childIdx]] has at least [kBTreeOrder] keys by
  /// borrowing from a sibling or merging with one.
  /// Returns the (possibly updated) child index to descend into.
  Future<int> _fill(BTreeNode parent, int childIdx) async {
    // Try to borrow from the left sibling.
    if (childIdx > 0) {
      final leftSib = await _readNode(parent.values[childIdx - 1]);
      if (leftSib.keys.length >= kBTreeOrder) {
        final child = await _readNode(parent.values[childIdx]);
        await _borrowFromLeft(parent, childIdx, child, leftSib);
        return childIdx;
      }
    }
    // Try to borrow from the right sibling.
    if (childIdx < parent.values.length - 1) {
      final rightSib = await _readNode(parent.values[childIdx + 1]);
      if (rightSib.keys.length >= kBTreeOrder) {
        final child = await _readNode(parent.values[childIdx]);
        await _borrowFromRight(parent, childIdx, child, rightSib);
        return childIdx;
      }
    }
    // Cannot borrow — must merge.
    if (childIdx > 0) {
      // Merge child with its left sibling; result lands in values[childIdx - 1].
      await _merge(parent, childIdx - 1);
      return childIdx - 1;
    } else {
      // Merge child with its right sibling; result lands in values[childIdx].
      await _merge(parent, childIdx);
      return childIdx;
    }
  }

  /// Borrows a key from the left sibling into [child] at [childIdx].
  ///
  /// Leaf nodes use a B+-style rotation so we never need the separator's lost
  /// file offset; internal nodes use the standard CLRS key-rotation.
  Future<void> _borrowFromLeft(
      BTreeNode parent, int childIdx, BTreeNode child, BTreeNode leftSib) async {
    if (child.isLeaf) {
      // Rotate leftSib's last entry into child's front.
      // New separator = that key (the new minimum of child).
      child.keys.insert(0, leftSib.keys.last);
      child.values.insert(0, leftSib.values.last);
      parent.keys[childIdx - 1] = leftSib.keys.last;
      leftSib.keys.removeLast();
      leftSib.values.removeLast();
    } else {
      // Standard rotation: pull separator down, push sibling's rightmost key up.
      child.keys.insert(0, parent.keys[childIdx - 1]);
      child.values.insert(0, leftSib.values.removeLast());
      parent.keys[childIdx - 1] = leftSib.keys.removeLast();
    }
    await _writeNode(parent);
    await _writeNode(child);
    await _writeNode(leftSib);
  }

  /// Borrows a key from the right sibling into [child] at [childIdx].
  Future<void> _borrowFromRight(
      BTreeNode parent, int childIdx, BTreeNode child, BTreeNode rightSib) async {
    if (child.isLeaf) {
      // Rotate rightSib's first entry into child's end.
      // New separator = sibling's new minimum.
      child.keys.add(rightSib.keys.first);
      child.values.add(rightSib.values.first);
      rightSib.keys.removeAt(0);
      rightSib.values.removeAt(0);
      parent.keys[childIdx] = rightSib.keys.first;
    } else {
      // Standard rotation: pull separator down, push sibling's leftmost key up.
      child.keys.add(parent.keys[childIdx]);
      child.values.add(rightSib.values.removeAt(0));
      parent.keys[childIdx] = rightSib.keys.removeAt(0);
    }
    await _writeNode(parent);
    await _writeNode(child);
    await _writeNode(rightSib);
  }

  /// Merges [parent.values[i+1]] into [parent.values[i]], pulling
  /// [parent.keys[i]] down (for internal nodes) and removing it from
  /// the parent along with the now-redundant right child pointer.
  ///
  /// For leaf nodes the separator is discarded — its file offset was already
  /// lost at split time, so it is not present in either child's entries.
  Future<void> _merge(BTreeNode parent, int i) async {
    final leftChild  = await _readNode(parent.values[i]);
    final rightChild = await _readNode(parent.values[i + 1]);

    if (leftChild.isLeaf) {
      // Leaf merge: concatenate entries; no separator offset to pull down.
      leftChild.keys.addAll(rightChild.keys);
      leftChild.values.addAll(rightChild.values);
    } else {
      // Internal merge: pull separator down as an additional routing key.
      leftChild.keys.add(parent.keys[i]);
      leftChild.keys.addAll(rightChild.keys);
      leftChild.values.addAll(rightChild.values);
    }

    parent.keys.removeAt(i);
    parent.values.removeAt(i + 1);

    await _writeNode(leftChild);
    await _writeNode(parent);
  }

  // ─── Range Scan ──────────────────────────────────────────────────────────

  /// Returns all values where key is between [low] and [high] (inclusive).
  Future<List<int>> rangeSearch(int low, int high) async {
    final results = <int>[];
    if (rootPage == null || rootPage == 0) return results;
    // seenIds prevents duplicate IDs in the output if the B-Tree has
    // structural inconsistencies (e.g. after a failed bulkLoad or compaction).
    final seenIds = <int>{};
    await _rangeNode(rootPage!, low, high, results, null, seenIds);
    return results;
  }

  Future<void> _rangeNode(int pageIdx, int low, int high, List<int> out, [Set<int>? visited, Set<int>? seenIds]) async {
    visited ??= {};
    seenIds ??= {};
    if (visited.contains(pageIdx)) {
      return;
    }
    visited.add(pageIdx);
    
    BTreeNode? node = _readNodeSync(pageIdx);
    node ??= await _readNode(pageIdx);

    for (int i = 0; i < node.keys.length; i++) {
      final k = node.keys[i];

      if (!node.isLeaf && k > low) {
        if (node.values[i] > 0) {
          await _rangeNode(node.values[i], low, high, out, visited, seenIds);
        }
      }

      // All subsequent keys and right subtrees are also > high.
      if (k > high) return;

      if (k >= low && node.isLeaf && seenIds.add(k)) out.add(k);
    }

    // Rightmost child holds keys > keys.last — only descend if it can overlap.
    if (!node.isLeaf &&
        node.values.length > node.keys.length &&
        (node.keys.isEmpty || node.keys.last < high)) {
      if (node.values.last > 0) {
        await _rangeNode(node.values.last, low, high, out, visited, seenIds);
      }
    }
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────

  /// Returns the first index `i` such that `keys[i] >= key` (lower bound).
  int _lowerBound(List<int> keys, int key) {
    int lo = 0, hi = keys.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (keys[mid] < key) lo = mid + 1;
      else hi = mid;
    }
    return lo;
  }

  /// Returns the first index `i` such that `keys[i] > key` (upper bound).
  /// Used for internal-node child selection during insert.
  int _upperBound(List<int> keys, int key) {
    int lo = 0, hi = keys.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (keys[mid] <= key) lo = mid + 1;
      else hi = mid;
    }
    return lo;
  }

  /// Synchronous node read: hits the node object cache first, then the LRU
  /// page byte cache. Returns null only when neither cache holds the page.
  /// Calling this avoids microtask scheduling on hot paths.
  BTreeNode? _readNodeSync(int pageIdx) {
    final cached = _nodeCache[pageIdx];
    if (cached != null) return cached;
    final page = pageManager.readPageSync(pageIdx);
    if (page == null) return null;
    final node = BTreeNode.deserialize(pageIdx, page);
    _nodeCache[pageIdx] = node;
    if (_nodeCache.length > _nodeCacheCapacity) {
      _nodeCache.remove(_nodeCache.keys.first);
    }
    return node;
  }

  Future<BTreeNode> _readNode(int pageIdx) async {
    final sync = _readNodeSync(pageIdx);
    if (sync != null) return sync;
    final data = await pageManager.readPage(pageIdx);
    final node = BTreeNode.deserialize(pageIdx, data);
    _nodeCache[pageIdx] = node;
    if (_nodeCache.length > _nodeCacheCapacity) {
      _nodeCache.remove(_nodeCache.keys.first);
    }
    return node;
  }

  Future<void> _writeNode(BTreeNode node) async {
    _nodeCache[node.pageIndex] = node; // keep node cache coherent
    await pageManager.writePage(node.pageIndex, node.serialize());
  }

  /// Clears the deserialized node cache (call after compact / external rewrite).
  void clearNodeCache() => _nodeCache.clear();
}

