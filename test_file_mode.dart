import 'dart:io';
import 'dart:typed_data';

void main() async {
  final file = File('test_raf.bin');
  if (await file.exists()) await file.delete();
  
  // Create with initial data: Page 0 (Header), Page 1 (Root), Page 2 (Doc)
  // Page 1 points to ID 1 at offset 8192
  final bytes = Uint8List(12288);
  // Header: nextId=2, rootPage=1
  bytes[8] = 2; // nextId
  bytes[4] = 1; // rootPage
  // Page 1 (Root): leaf=1, keyCount=1, key0=1, val0=8192
  // Let's assume some simplified encoding for the root node for this test
  bytes[4096] = 1; // isLeaf
  bytes[4096+1] = 1; // keyCount
  bytes[4096+4] = 1; // key0
  bytes[4096+8] = (8192 >> 0) & 0xFF; // val0 offset
  bytes[4096+9] = (8192 >> 8) & 0xFF;

  await file.writeAsBytes(bytes);

  print('--- Opening with FileMode.append ---');
  final raf = await file.open(mode: FileMode.append);
  try {
    // 1. Overwrite Root (Page 1) to point to offset 16384 (simulation of transaction update)
    await raf.setPosition(4096 + 8);
    await raf.writeFrom([(16384 >> 0) & 0xFF, (16384 >> 8) & 0xFF]);
    
    // 2. Read back from pos 4096+8
    await raf.setPosition(4096 + 8);
    final buf = Uint8List(2);
    await raf.readInto(buf);
    final readVal = buf[0] | (buf[1] << 8);
    print('Read offset back from Page 1 (expect 16384): $readVal');
    
    // 3. Read from physical file at the beginning
    final fileBytes = await file.readAsBytes();
    final physVal = fileBytes[4096+8] | (fileBytes[4096+9] << 8);
    print('Physical file[4096+8] (expect 8192 if append only): $physVal');
    
    if (readVal == 16384 && physVal == 16384) {
      print('RESULT: Overwrite works locally and on disk!');
    } else if (readVal == 16384 && physVal == 8192) {
      print('RESULT: Overwrite works in-memory/buffer but NOT on disk (DANGEROUS)');
    } else {
      print('RESULT: Behavior is weird');
    }
  } finally {
    await raf.close();
    if (await file.exists()) await file.delete();
  }
}
