import 'package:ffastdb/ffastdb.dart';
import 'package:ffastdb/src/storage/memory_storage_strategy.dart';
import 'package:test/test.dart';

void main() {
  group('Data Types Support', () {
    late FastDB db;

    setUp(() async {
      await FfastDb.disposeInstance();
      db = await FfastDb.init(MemoryStorageStrategy());
    });

    tearDown(() async {
      await FfastDb.disposeInstance();
    });

    test('supports int type', () async {
      final doc = {
        'smallInt': 42,
        'largeInt': 9223372036854775807, // max int64
        'negativeInt': -12345,
        'zero': 0,
      };

      final id = await db.insert(doc);
      final retrieved = await db.findById(id);

      expect(retrieved['smallInt'], equals(42));
      expect(retrieved['largeInt'], equals(9223372036854775807));
      expect(retrieved['negativeInt'], equals(-12345));
      expect(retrieved['zero'], equals(0));
    });

    test('supports double type', () async {
      final doc = {
        'pi': 3.14159265359,
        'negative': -123.456,
        'zero': 0.0,
        'scientific': 1.23e-10,
        'large': 9.999999e100,
      };

      final id = await db.insert(doc);
      final retrieved = await db.findById(id);

      expect(retrieved['pi'], closeTo(3.14159265359, 0.0000001));
      expect(retrieved['negative'], closeTo(-123.456, 0.001));
      expect(retrieved['zero'], equals(0.0));
      expect(retrieved['scientific'], closeTo(1.23e-10, 1e-15));
      expect(retrieved['large'], closeTo(9.999999e100, 1e95));
    });

    test('supports string type', () async {
      final doc = {
        'simple': 'Hello, World!',
        'empty': '',
        'unicode': '你好🌍',
        'multiline': 'Line 1\nLine 2\nLine 3',
        'withQuotes': 'She said "Hello"',
        'withSpecialChars': 'Tab\tNewline\nBackslash\\',
      };

      final id = await db.insert(doc);
      final retrieved = await db.findById(id);

      expect(retrieved['simple'], equals('Hello, World!'));
      expect(retrieved['empty'], equals(''));
      expect(retrieved['unicode'], equals('你好🌍'));
      expect(retrieved['multiline'], equals('Line 1\nLine 2\nLine 3'));
      expect(retrieved['withQuotes'], equals('She said "Hello"'));
      expect(retrieved['withSpecialChars'], equals('Tab\tNewline\nBackslash\\'));
    });

    test('supports char type (single character strings)', () async {
      final doc = {
        'letter': 'A',
        'digit': '7',
        'symbol': '@',
        'unicode': '😀',
        'space': ' ',
      };

      final id = await db.insert(doc);
      final retrieved = await db.findById(id);

      expect(retrieved['letter'], equals('A'));
      expect(retrieved['digit'], equals('7'));
      expect(retrieved['symbol'], equals('@'));
      expect(retrieved['unicode'], equals('😀'));
      expect(retrieved['space'], equals(' '));
    });

    test('supports boolean type', () async {
      final doc = {
        'isActive': true,
        'isDeleted': false,
        'hasPermission': true,
      };

      final id = await db.insert(doc);
      final retrieved = await db.findById(id);

      expect(retrieved['isActive'], equals(true));
      expect(retrieved['isDeleted'], equals(false));
      expect(retrieved['hasPermission'], equals(true));
    });

    test('supports DateTime type (timestamp)', () async {
      final now = DateTime.now();
      final past = DateTime(2020, 1, 15, 10, 30, 45);
      final future = DateTime(2030, 12, 31, 23, 59, 59);
      final utc = DateTime.utc(2025, 6, 15, 12, 0, 0);

      final doc = {
        'createdAt': now,
        'pastDate': past,
        'futureDate': future,
        'utcDate': utc,
      };

      final id = await db.insert(doc);
      final retrieved = await db.findById(id);

      expect(retrieved['createdAt'], isA<DateTime>());
      expect((retrieved['createdAt'] as DateTime).millisecondsSinceEpoch,
          equals(now.millisecondsSinceEpoch));
      
      final retrievedPast = retrieved['pastDate'] as DateTime;
      expect(retrievedPast.year, equals(2020));
      expect(retrievedPast.month, equals(1));
      expect(retrievedPast.day, equals(15));
      
      final retrievedFuture = retrieved['futureDate'] as DateTime;
      expect(retrievedFuture.millisecondsSinceEpoch,
          equals(future.millisecondsSinceEpoch));
      
      final retrievedUtc = retrieved['utcDate'] as DateTime;
      expect(retrievedUtc.millisecondsSinceEpoch,
          equals(utc.millisecondsSinceEpoch));
    });

    test('supports location type (GeoPoint as latitude/longitude)', () async {
      final doc = {
        'homeLocation': {
          'latitude': 40.7128,
          'longitude': -74.0060,
        },
        'officeLocation': {
          'latitude': 51.5074,
          'longitude': -0.1278,
        },
      };

      final id = await db.insert(doc);
      final retrieved = await db.findById(id);

      expect(retrieved['homeLocation'], isA<Map>());
      expect(retrieved['homeLocation']['latitude'], closeTo(40.7128, 0.0001));
      expect(retrieved['homeLocation']['longitude'], closeTo(-74.0060, 0.0001));
      expect(retrieved['officeLocation']['latitude'], closeTo(51.5074, 0.0001));
      expect(retrieved['officeLocation']['longitude'], closeTo(-0.1278, 0.0001));
    });

    test('supports null values', () async {
      final doc = {
        'name': 'John',
        'middleName': null,
        'nickname': null,
        'age': 30,
      };

      final id = await db.insert(doc);
      final retrieved = await db.findById(id);

      expect(retrieved['name'], equals('John'));
      expect(retrieved['middleName'], isNull);
      expect(retrieved['nickname'], isNull);
      expect(retrieved['age'], equals(30));
    });

    test('supports nested objects and arrays', () async {
      final doc = {
        'user': {
          'name': 'Alice',
          'age': 30,
          'address': {
            'street': '123 Main St',
            'city': 'New York',
            'zipCode': '10001',
          },
        },
        'tags': ['developer', 'designer', 'manager'],
        'scores': [95, 87, 92, 88],
        'matrix': [
          [1, 2, 3],
          [4, 5, 6],
        ],
      };

      final id = await db.insert(doc);
      final retrieved = await db.findById(id);

      expect(retrieved['user']['name'], equals('Alice'));
      expect(retrieved['user']['age'], equals(30));
      expect(retrieved['user']['address']['city'], equals('New York'));
      expect(retrieved['tags'], equals(['developer', 'designer', 'manager']));
      expect(retrieved['scores'], equals([95, 87, 92, 88]));
      expect(retrieved['matrix'][0], equals([1, 2, 3]));
      expect(retrieved['matrix'][1], equals([4, 5, 6]));
    });

    test('supports mixed types in single document', () async {
      final doc = {
        'id': 'user_123',
        'name': 'John Doe',
        'age': 35,
        'salary': 75000.50,
        'isActive': true,
        'createdAt': DateTime(2023, 1, 15),
        'lastLogin': null,
        'location': {
          'latitude': 37.7749,
          'longitude': -122.4194,
        },
        'roles': ['admin', 'user'],
        'metadata': {
          'department': 'Engineering',
          'level': 5,
          'remote': true,
        },
      };

      final id = await db.insert(doc);
      final retrieved = await db.findById(id);

      expect(retrieved['id'], equals('user_123'));
      expect(retrieved['name'], equals('John Doe'));
      expect(retrieved['age'], equals(35));
      expect(retrieved['salary'], closeTo(75000.50, 0.01));
      expect(retrieved['isActive'], equals(true));
      expect(retrieved['createdAt'], isA<DateTime>());
      expect(retrieved['lastLogin'], isNull);
      expect(retrieved['location']['latitude'], closeTo(37.7749, 0.0001));
      expect(retrieved['roles'], equals(['admin', 'user']));
      expect(retrieved['metadata']['department'], equals('Engineering'));
      expect(retrieved['metadata']['level'], equals(5));
      expect(retrieved['metadata']['remote'], equals(true));
    });

    test('supports Firebase Timestamp duck-typing', () async {
      // Simulate a Firebase Timestamp object
      final fakeTimestamp = _FakeFirebaseTimestamp(DateTime(2024, 6, 15, 10, 30));

      final doc = {
        'name': 'Test',
        'createdAt': fakeTimestamp,
      };

      final id = await db.insert(doc);
      final retrieved = await db.findById(id);

      expect(retrieved['createdAt'], isA<DateTime>());
      expect((retrieved['createdAt'] as DateTime).year, equals(2024));
      expect((retrieved['createdAt'] as DateTime).month, equals(6));
      expect((retrieved['createdAt'] as DateTime).day, equals(15));
    });

    test('supports Firebase GeoPoint duck-typing', () async {
      // Simulate a Firebase GeoPoint object
      final fakeGeoPoint = _FakeFirebaseGeoPoint(34.0522, -118.2437);

      final doc = {
        'name': 'Los Angeles Office',
        'location': fakeGeoPoint,
      };

      final id = await db.insert(doc);
      final retrieved = await db.findById(id);

      expect(retrieved['location'], isA<Map>());
      expect(retrieved['location']['latitude'], closeTo(34.0522, 0.0001));
      expect(retrieved['location']['longitude'], closeTo(-118.2437, 0.0001));
    });

    test('handles large documents with all types', () async {
      final largeDocs = List.generate(100, (i) => {
        'index': i,
        'name': 'User $i',
        'age': 20 + (i % 50),
        'score': (i * 1.5),
        'isActive': i % 2 == 0,
        'createdAt': DateTime.now().subtract(Duration(days: i)),
        'location': {
          'latitude': 40.0 + (i * 0.01),
          'longitude': -74.0 - (i * 0.01),
        },
        'tags': ['tag$i', 'category${i % 10}'],
      });

      final ids = await db.insertAll(largeDocs);
      expect(ids.length, equals(100));

      // Verify random samples
      final sample1 = await db.findById(ids[0]);
      expect(sample1['index'], equals(0));
      expect(sample1['isActive'], equals(true));

      final sample2 = await db.findById(ids[50]);
      expect(sample2['index'], equals(50));
      expect(sample2['age'], equals(20));

      final sample3 = await db.findById(ids[99]);
      expect(sample3['index'], equals(99));
      expect(sample3['tags'][0], equals('tag99'));
    });
  });
}

// Mock classes to simulate Firebase types
class _FakeFirebaseTimestamp {
  final DateTime _dateTime;
  _FakeFirebaseTimestamp(this._dateTime);
  DateTime toDate() => _dateTime;
}

class _FakeFirebaseGeoPoint {
  final double latitude;
  final double longitude;
  _FakeFirebaseGeoPoint(this.latitude, this.longitude);
}
