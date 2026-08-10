import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../serialization/fast_serializer.dart';

/// Entry representing an extracted document field for index rebuilding.
class ExtractedIndexDoc {
  final int docId;
  final Map<String, dynamic> fields;

  ExtractedIndexDoc(this.docId, this.fields);
}

/// Payload passed to isolate worker for background parsing and extraction.
class ExtractionTaskPayload {
  final List<MapEntry<int, Uint8List>> rawDocs;
  final List<String> fieldPaths;

  ExtractionTaskPayload(this.rawDocs, this.fieldPaths);
}

/// Top-level worker function executed inside Isolate.run for background CPU processing.
List<ExtractedIndexDoc> extractFieldsWorker(ExtractionTaskPayload payload) {
  final results = <ExtractedIndexDoc>[];

  for (final entry in payload.rawDocs) {
    final docId = entry.key;
    final fullData = entry.value;

    if (fullData.length < 8) continue;
    final length = (fullData[0] & 0xFF) |
        ((fullData[1] & 0xFF) << 8) |
        ((fullData[2] & 0xFF) << 16) |
        ((fullData[3] & 0xFF) << 24);

    if (fullData.length < 4 + length) continue;

    try {
      final payloadBytes = fullData.sublist(4, 4 + length);
      final doc = FastSerializer.deserialize(payloadBytes);

      final extracted = <String, dynamic>{};
      for (final fieldPath in payload.fieldPaths) {
        final val = _extractFieldPath(doc, fieldPath);
        if (val != null) {
          extracted[fieldPath] = val;
        }
      }

      results.add(ExtractedIndexDoc(docId, extracted));
    } catch (_) {
      // Ignore corrupted or un-parseable records during background extraction
    }
  }

  return results;
}

dynamic _extractFieldPath(Map doc, String fieldPath) {
  if (!fieldPath.contains('.')) return doc[fieldPath];

  final parts = fieldPath.split('.');
  dynamic current = doc;
  for (final part in parts) {
    if (current is! Map) return null;
    current = current[part];
  }
  return current;
}

/// Runs extraction in a background Isolate on Native platforms, or inline on Web.
Future<List<ExtractedIndexDoc>> runParallelExtraction(
  List<MapEntry<int, Uint8List>> rawDocs,
  List<String> fieldPaths,
) async {
  if (rawDocs.isEmpty || fieldPaths.isEmpty) return [];

  final payload = ExtractionTaskPayload(rawDocs, fieldPaths);

  // Check if running on web (JS numbers: int and double identical)
  const isWeb = identical(0, 0.0);

  if (isWeb) {
    return extractFieldsWorker(payload);
  }

  try {
    return await Isolate.run(() => extractFieldsWorker(payload));
  } catch (_) {
    // Fallback to inline processing if Isolate.run fails
    return extractFieldsWorker(payload);
  }
}
