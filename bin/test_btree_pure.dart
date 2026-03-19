import 'package:ffastdb/src/index/btree.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';
import 'package:ffastdb/src/storage/page_manager.dart';

void main() async {
  print('=== Pure BTree bulkLoad Test ===');
  final storage = MemoryStorageStrategy();
  await storage.open();
  final pm = PageManager(storage);
  final tree = BTree(pm);

  const count = 50000;
  print('Bulk loading $count entries...');

  final entries = List.generate(count, (i) => MapEntry(i + 1, (i + 1) * 100));
  await tree.bulkLoad(entries);
  print('Root page: ${tree.rootPage}');

  int failures = 0;
  for (final id in [1, 2, 100, 1000, 10000, 25000, 50000]) {
    final val = await tree.search(id);
    final expected = id * 100;
    if (val != expected) {
      print('FAIL: search($id) = $val, expected $expected');
      failures++;
    } else {
      print('OK: search($id) = $val');
    }
  }

  if (failures == 0) {
    print('ALL TESTS PASSED');
  } else {
    print('$failures TESTS FAILED');
  }
}
