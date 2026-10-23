import 'dart:convert';
import 'dart:typed_data';

import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/serialization/document_codec.dart';
import 'package:ffastdb/src/serialization/type_adapter.dart';
import 'package:test/test.dart';

// Duck-typed stand-ins for cloud_firestore types (matched by type name).
class Timestamp {
  final DateTime _dt;
  Timestamp(this._dt);
  DateTime toDate() => _dt;
}

class GeoPoint {
  final double latitude, longitude;
  GeoPoint(this.latitude, this.longitude);
}

class DocumentReference {
  final String path;
  DocumentReference(this.path);
}

class Blob {
  final Uint8List bytes;
  Blob(this.bytes);
}

class Opaque {
  @override
  String toString() => 'Opaque!';
}

Map<String, dynamic> roundTrip(Map doc, {int? id}) {
  final record = DocumentCodec.encodeRecord(doc, id: id);
  final length = ByteData.sublistView(record).getUint32(0, Endian.little);
  expect(record.length, 4 + length + 4);
  return DocumentCodec.decode(Uint8List.sublistView(record, 4, 4 + length));
}

void main() {
  group('DocumentCodec', () {
    test('round-trips every supported type', () {
      final doc = {
        'null': null,
        't': true,
        'f': false,
        'str': 'hello',
        'empty': '',
        'unicode': 'Ñandú 🚀 日本',
        'nul': '\u0000dt:not-a-date',
        'double': 0.1,
        'whole': 2.0,
        'negDouble': -1.5e300,
        'when': DateTime.utc(2024, 5, 6, 7, 8, 9, 123, 456),
        'bytes': Uint8List.fromList([0, 1, 2, 255]),
        'emptyBytes': Uint8List(0),
        'list': ['x', 1, false, null, [1, 2], {'a': 1}],
        'emptyList': [],
        'nested': {'deep': {'k': 'v'}, 'm': <String, dynamic>{}},
      };
      final out = roundTrip(doc);
      expect(out, equals(doc));
      expect(out['whole'], isA<double>());
      expect(out['bytes'], isA<Uint8List>());
      expect((out['when'] as DateTime).isUtc, isTrue);
      expect(out['nested'], isA<Map<String, dynamic>>());
      expect(out['list'], isA<List<dynamic>>());
      (out['list'] as List).add('growable');
    });

    test('integers keep exact values across int8/int32/int64 boundaries', () {
      final values = <int>[
        0, 1, -1, 127, 128, -128, -129, 255, 256,
        0x7FFFFFFF, 0x80000000, -0x80000000, -0x80000001,
        0xFFFFFFFF, 0x100000000, 9007199254740991, -9007199254740991,
      ];
      final doc = {for (int i = 0; i < values.length; i++) 'v$i': values[i]};
      final out = roundTrip(doc);
      for (int i = 0; i < values.length; i++) {
        expect(out['v$i'], values[i], reason: 'value ${values[i]}');
        expect(out['v$i'], isA<int>());
      }
    });

    test('full 64-bit range on the VM', () {
      // int.parse: these literals do not compile with dart2js.
      final doc = {
        'max': int.parse('9223372036854775807'),
        'min': int.parse('-9223372036854775808'),
        'big': int.parse('9007199254740993'),
      };
      expect(roundTrip(doc), equals(doc));
    }, testOn: 'vm');

    test('non-finite doubles are preserved (JSON stored them as strings)', () {
      final out = roundTrip({
        'nan': double.nan,
        'inf': double.infinity,
        'ninf': double.negativeInfinity,
      });
      expect((out['nan'] as double).isNaN, isTrue);
      expect(out['inf'], double.infinity);
      expect(out['ninf'], double.negativeInfinity);
    });

    test('Firebase duck types and toString fallback', () {
      final out = roundTrip({
        'ts': Timestamp(DateTime.utc(2020, 1, 2)),
        'geo': GeoPoint(-34.6, -58.4),
        'ref': DocumentReference('users/42'),
        'blob': Blob(Uint8List.fromList([9, 8])),
        'opaque': Opaque(),
        'set': {1, 2},
      });
      expect(out['ts'], DateTime.utc(2020, 1, 2));
      expect(out['geo'], {'latitude': -34.6, 'longitude': -58.4});
      expect(out['ref'], 'users/42');
      expect(out['blob'], Uint8List.fromList([9, 8]));
      expect(out['opaque'], 'Opaque!');
      expect(out['set'], '{1, 2}');
    });

    test('nested non-String keys are stored as strings', () {
      final out = roundTrip({
        'm': {1: 'a', true: 'b'},
      });
      expect(out['m'], {'1': 'a', 'true': 'b'});
    });

    test('id replaces ffdbID without mutating the input', () {
      final doc = {'ffdbID': 99, 'a': 1};
      final out = roundTrip(doc, id: 7);
      expect(out, {'a': 1, 'ffdbID': 7});
      expect(doc, {'ffdbID': 99, 'a': 1});
      expect(roundTrip({'a': 1}, id: 3), {'a': 1, 'ffdbID': 3});
    });

    test('root keys must be Strings', () {
      expect(() => DocumentCodec.encodeRecord({1: 'a'}), throwsArgumentError);
    });

    test('corrupt payloads throw instead of returning garbage', () {
      final record = DocumentCodec.encodeRecord({'a': 'hello world'});
      final payload = Uint8List.sublistView(record, 4, record.length - 4);
      expect(() => DocumentCodec.decode(Uint8List.sublistView(payload, 0, 8)),
          throwsA(anything));
      expect(() => DocumentCodec.decode(Uint8List.fromList([0, 1, 9])),
          throwsArgumentError);
    });

    test('decodeDocumentPayload ignores TypeAdapter payloads', () {
      expect(decodeDocumentPayload(Uint8List.fromList([5, 0, 1, 2])), isNull);
    });
  });

  group('FastDB with the binary format', () {
    late FastDB db;

    setUp(() async {
      db = FastDB.forTesting(MemoryStorageStrategy())
        ..addIndex('status')
        ..addSortedIndex('when');
      await db.open();
    });

    tearDown(() => db.close());

    test('documents, indexes and reindex work end to end', () async {
      final when = DateTime.utc(2024, 1, 1);
      final ids = await db.insertAll([
        for (int i = 0; i < 100; i++)
          {
            'status': i.isEven ? 'on' : 'off',
            'when': when.add(Duration(days: i)),
            'payload': Uint8List.fromList([i]),
          },
      ]);
      final doc = await db.findById(ids[10]);
      expect(doc['when'], when.add(const Duration(days: 10)));
      expect(doc['payload'], Uint8List.fromList([10]));
      expect(doc['ffdbID'], ids[10]);

      expect(await db.query().where('status').equals('on').count(), 50);
      await db.reindex(); // isolate extraction decodes the binary records
      expect(await db.query().where('status').equals('on').count(), 50);
      final range = await db
          .query()
          .where('when')
          .between(when, when.add(const Duration(days: 4)))
          .findIds();
      expect(range.length, 5);
    });

    test('exportJson produces plain JSON; importJson inserts it back',
        () async {
      await db.insert({
        'status': 'on',
        'when': DateTime.utc(2024, 1, 2, 3, 4, 5),
        'bytes': Uint8List.fromList([1, 2, 3]),
        'nan': double.nan,
        'nested': {'list': [1, 'a', null]},
      });
      await db.insert({'status': 'off', 'n': 2});

      final json = await db.exportJson();
      final decoded = jsonDecode(json) as List;
      expect(decoded, [
        {
          'status': 'on',
          'when': '2024-01-02T03:04:05.000Z',
          'bytes': 'AQID',
          'nan': null,
          'nested': {'list': [1, 'a', null]},
          'ffdbID': 1,
        },
        {'status': 'off', 'n': 2, 'ffdbID': 2},
      ]);

      final other = FastDB.forTesting(MemoryStorageStrategy())
        ..addIndex('status');
      await other.open();
      addTearDown(other.close);
      await other.insert({'pre': true}); // id 1 is taken
      final ids = await other.importJson(json);
      expect(ids, [2, 3]);
      expect(await other.findById(2), {
        ...decoded[0] as Map,
        'ffdbID': 2,
      });
      expect(await other.query().where('status').equals('off').count(), 1);
      expect(await other.importJson('{"single": 1}'), [4]);
      expect(() => other.importJson('[1, 2]'), throwsFormatException);
    });

    test('registering typeId 512 is rejected (collides with the magic)', () {
      expect(() => db.registerAdapter(_Adapter512()), throwsArgumentError);
    });
  });
}

class _Adapter512 extends TypeAdapter<Opaque> {
  @override
  int get typeId => 512;
  @override
  Opaque read(BinaryReader reader) => Opaque();
  @override
  void write(BinaryWriter writer, Opaque obj) {}
}
