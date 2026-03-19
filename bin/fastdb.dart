void main(List<String> arguments) {
  print('FastDB — A high-performance, pure-Dart embedded NoSQL database.');
  print('Use FastDB as a library: import \'package:ffastdb/ffastdb.dart\';');
  print('');
  print('Example usage:');
  print('  final db = FastDB(storage: MemoryStorageStrategy());');
  print('  await db.open();');
  print('  await db.insert({\'name\': \'Alice\', \'age\': 30});');
  print('  await db.close();');
}
