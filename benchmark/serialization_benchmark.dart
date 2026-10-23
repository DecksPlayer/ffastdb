// Document encoding: legacy JSON format (FastSerializer) vs binary format
// (DocumentCodec), in isolation from storage and indexes.
//
//   dart run benchmark/serialization_benchmark.dart
import 'dart:typed_data';

import 'package:ffastdb/src/serialization/document_codec.dart';
import 'package:ffastdb/src/serialization/fast_serializer.dart';

Map<String, dynamic> doc(int i) => {
      'name': 'user_$i',
      'email': 'user$i@example.com',
      'age': 18 + i % 60,
      'score': i * 1.25,
      'active': i.isEven,
      'status': i % 3 == 0 ? 'active' : 'inactive',
      'createdAt': DateTime.utc(2024, 1, 1).add(Duration(minutes: i)),
      'tags': ['a', 'b', 'tag$i'],
      'address': {'city': 'City${i % 50}', 'zip': 10000 + i},
      'ffdbID': i,
    };

int measure(void Function() body) {
  body(); // warm-up
  final sw = Stopwatch()..start();
  body();
  return sw.elapsedMilliseconds;
}

void main() {
  const n = 100000;
  final docs = List.generate(n, doc);

  late List<Uint8List> json;
  late List<Uint8List> binary;
  final jsonEncodeMs = measure(() => json = [for (final d in docs) FastSerializer.serialize(d)]);
  final binEncodeMs = measure(() => binary = [for (final d in docs) DocumentCodec.encodeRecord(d)]);
  final jsonDecodeMs = measure(() {
    for (final b in json) {
      FastSerializer.deserialize(b);
    }
  });
  final binDecodeMs = measure(() {
    for (final b in binary) {
      DocumentCodec.decode(Uint8List.sublistView(b, 4, b.length - 4));
    }
  });

  final jsonBytes = json.fold<int>(0, (s, b) => s + b.length);
  final binBytes = binary.fold<int>(0, (s, b) => s + b.length - 8);
  String row(String label, num a, num b) =>
      '${label.padRight(16)} json=${a.toString().padLeft(7)}  '
      'binary=${b.toString().padLeft(7)}  (${(a / b).toStringAsFixed(2)}x)';

  print('$n documents');
  print(row('encode (ms)', jsonEncodeMs, binEncodeMs));
  print(row('decode (ms)', jsonDecodeMs, binDecodeMs));
  print(row('bytes/doc', (jsonBytes / n).round(), (binBytes / n).round()));
}
