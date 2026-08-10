import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';

void main() async {
  final db = FastDB(MemoryStorageStrategy());
  db.addIndex('type');
  db.addIndex('userId');
  db.addIndex('postId');
  db.addSortedIndex('likes');
  db.addFtsIndex('content');
  await db.open();

  print('Generating 1000 users...');
  final users = List.generate(1000, (i) => {'type': 'user', 'name': 'User $i'});
  await db.insertAll(users);

  print('Generating 98000 posts...');
  final posts = List.generate(98000, (i) => {
    'type': 'post',
    'userId': i % 1000,
    'content': 'Post $i content with some text words',
    'likes': i % 500,
  });
  await db.insertAll(posts);

  print('Generating 1000 comments...');
  final comments = List.generate(1000, (i) => {'type': 'comment', 'postId': i, 'text': 'Comment $i'});
  await db.insertAll(comments);

  final totalCount = await db.count();
  print('📊 TOTAL DB COUNT = $totalCount (expected 100000)');

  for (final entry in db.indexes.all.entries) {
    print('   Index [${entry.key}]: size=${entry.value.size}');
  }
}
