// Imports ONLY the public barrel: everything used here must be exported.
import 'package:ffastdb/ffastdb.dart';
import 'package:test/test.dart';

class Point {
  final int x, y;
  Point(this.x, this.y);
}

class PointAdapter extends TypeAdapter<Point> {
  @override
  int get typeId => 7;

  @override
  Point read(BinaryReader reader) {
    final n = reader.readUint8();
    final f = <int, dynamic>{
      for (int i = 0; i < n; i++) reader.readUint8(): reader.readDynamic(),
    };
    return Point(f[0] as int, f[1] as int);
  }

  @override
  void write(BinaryWriter writer, Point obj) {
    writer.writeUint8(2);
    writer.writeUint8(0);
    writer.writeDynamic(obj.x);
    writer.writeUint8(1);
    writer.writeDynamic(obj.y);
  }
}

void main() {
  late FastDB db;

  setUp(() async {
    db = FastDB.forTesting(MemoryStorageStrategy());
    await db.open();
  });

  tearDown(() => db.close());

  test('TypeAdapter, BinaryReader and BinaryWriter are public API', () async {
    db.registerAdapter(PointAdapter());
    await db.put(1, Point(3, -4));
    final p = await db.findById(1) as Point;
    expect([p.x, p.y], [3, -4]);
  });
}
