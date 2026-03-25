import 'dart:io';
import 'dart:typed_data';

void main() async {
  final file = File('test_mode.bin');
  if (await file.exists()) await file.delete();
  
  // 1. Write initial data
  var raf = await file.open(mode: FileMode.write);
  await raf.writeFrom(Uint8List.fromList([1, 2, 3, 4]));
  await raf.close();
  print('Initial: [1, 2, 3, 4]');

  // 2. Open with FileMode.append and try to overwrite byte 1
  raf = await file.open(mode: FileMode.append);
  print('Reopened with FileMode.append. Length: ${await raf.length()}');
  await raf.setPosition(1);
  await raf.writeByte(9);
  await raf.close();

  final bytes = await File('test_mode.bin').readAsBytes();
  print('Result: $bytes');
  if (bytes[1] == 9) {
    print('SUCCESS: FileMode.append allows random access writes!');
  } else {
    print('FAILURE: FileMode.append appended at end instead of pos 1.');
  }
}
