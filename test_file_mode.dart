import 'dart:io';
import 'dart:typed_data';

/// Test to verify that FileMode.write correctly handles setPosition() + write
/// operations at arbitrary offsets, unlike FileMode.append which can cause
/// corruption on mobile platforms.
void main() async {
  print('=== Testing FileMode.append (BROKEN on mobile) ===');
  await testFileMode(FileMode.append, 'test_append.bin');
  
  print('\n=== Testing FileMode.write (CORRECT) ===');
  await testFileMode(FileMode.write, 'test_write.bin');
}

Future<void> testFileMode(FileMode mode, String filename) async {
  final file = File(filename);
  if (await file.exists()) await file.delete();
  
  // Create with initial data: Page 0 (Header), Page 1 (Root), Page 2 (Doc)
  // Page 1 points to ID 1 at offset 8192
  final bytes = Uint8List(12288);
  // Header: nextId=2, rootPage=1
  bytes[8] = 2; // nextId
  bytes[4] = 1; // rootPage
  // Page 1 (Root): leaf=1, keyCount=1, key0=1, val0=8192
  bytes[4096] = 1; // isLeaf
  bytes[4096+1] = 1; // keyCount
  bytes[4096+4] = 1; // key0
  bytes[4096+8] = (8192 >> 0) & 0xFF; // val0 offset
  bytes[4096+9] = (8192 >> 8) & 0xFF;

  await file.writeAsBytes(bytes);

  print('Opening with $mode...');
  final raf = await file.open(mode: mode);
  try {
    // 1. Overwrite Root (Page 1) to point to offset 16384 (simulates B-tree update)
    await raf.setPosition(4096 + 8);
    await raf.writeFrom([(16384 >> 0) & 0xFF, (16384 >> 8) & 0xFF]);
    await raf.flush();
    
    // 2. Read back from the RandomAccessFile handle
    await raf.setPosition(4096 + 8);
    final buf = Uint8List(2);
    await raf.readInto(buf);
    final readVal = buf[0] | (buf[1] << 8);
    print('  In-memory read (expect 16384): $readVal');
    
    await raf.close();
    
    // 3. Read from physical file on disk
    final fileBytes = await file.readAsBytes();
    final diskVal = fileBytes[4096+8] | (fileBytes[4096+9] << 8);
    print('  Physical disk read (expect 16384): $diskVal');
    
    if (readVal == 16384 && diskVal == 16384) {
      print('  ✅ RESULT: Random-access writes work correctly!');
    } else if (readVal == 16384 && diskVal == 8192) {
      print('  ❌ RESULT: Write ignored by disk (append-only)! CAUSES CORRUPTION!');
    } else {
      print('  ❌ RESULT: Unexpected behavior - readVal=$readVal diskVal=$diskVal');
    }
  } catch (e) {
    print('  ❌ ERROR: $e');
  } finally {
    if (await file.exists()) await file.delete();
  }
}
