import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../serialization/fast_serializer.dart';

/// Represents a single database operation in the sequential log.
class LoggedOp {
  final String type; // 'insert', 'put', 'update', 'delete'
  final int? id;
  final dynamic data;
  final int timestamp;

  LoggedOp({required this.type, this.id, this.data, required this.timestamp});

  Map<String, dynamic> toJson() => {
    't': type,
    'id': id,
    'd': data,
    'ts': timestamp,
  };

  factory LoggedOp.fromJson(Map<String, dynamic> json) => LoggedOp(
    type: json['t'],
    id: json['id'],
    data: json['d'],
    timestamp: json['ts'],
  );
}

/// A high-level sequential log for database operations.
///
/// This ensures that even if the main DB file or index is corrupted,
/// the last set of operations can be replayed from this log.
///
/// Replays are IDEMPOTENT (put/update/delete by id), so entries do not need
/// to be cleared after every operation — the log is checkpointed
/// (truncated) only every [_checkpointEvery] durable ops, and flushed every
/// [_flushEvery] ops. That removes ~4 syscalls per CRUD operation.
class OperationLog {
  final String path;
  final bool _enabled;
  File? _file;
  IOSink? _sink;

  /// Clear (truncate) the log after this many durable operations.
  static const int _checkpointEvery = 1000;

  /// Flush the sink every this many logged operations.
  static const int _flushEvery = 32;

  int _opsSinceClear = 0;
  int _opsSinceFlush = 0;

  OperationLog(this.path) : _enabled = true;

  OperationLog.disabled() : path = '', _enabled = false;

  Future<void> open() async {
    if (!_enabled) return;
    _file = File(path);
    if (!await _file!.exists()) {
      await _file!.create(recursive: true);
    }
    _sink = _file!.openWrite(mode: FileMode.append);
  }

  /// Appends an operation to the log.
  Future<void> log(String type, {int? id, dynamic data}) async {
    if (!_enabled) return;
    if (_sink == null) return;

    // Map data is serialized with FastSerializer (type-safe: DateTime,
    // Uint8List, etc. survive the round trip — the old toEncodable fallback
    // degraded unknown objects to toString()).
    dynamic encodedData = data;
    if (data is Map) {
      encodedData = {
        '\u0000fs': base64Encode(
          FastSerializer.serialize(Map<String, dynamic>.from(data)),
        ),
      };
    }

    final op = LoggedOp(
      type: type,
      id: id,
      data: encodedData,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    final jsonStr = jsonEncode(
      op.toJson(),
      toEncodable: (val) {
        if (val is Uint8List) {
          return '\u0000bl:${base64Encode(val)}';
        }
        return val.toString();
      },
    );

    final bytes = utf8.encode(jsonStr);
    final lenHeader = Uint8List(4);
    lenHeader[0] = bytes.length & 0xFF;
    lenHeader[1] = (bytes.length >> 8) & 0xFF;
    lenHeader[2] = (bytes.length >> 16) & 0xFF;
    lenHeader[3] = (bytes.length >> 24) & 0xFF;

    _sink!.add(lenHeader);
    _sink!.add(bytes);
    // Amortized flush — the WAL already provides crash recovery; this log is
    // a secondary safety net, so per-op flushing is not required.
    if (++_opsSinceFlush >= _flushEvery) {
      await _sink!.flush();
      _opsSinceFlush = 0;
    }
  }

  /// Reads all pending operations from the log.
  Future<List<LoggedOp>> readAll() async {
    if (!_enabled) return [];
    if (_file == null) return [];
    final ops = <LoggedOp>[];
    try {
      final bytes = await _file!.readAsBytes();
      int offset = 0;
      while (offset + 4 <= bytes.length) {
        final len =
            bytes[offset] |
            (bytes[offset + 1] << 8) |
            (bytes[offset + 2] << 16) |
            (bytes[offset + 3] << 24);
        offset += 4;
        if (offset + len > bytes.length) break;

        final jsonStr = utf8.decode(bytes.sublist(offset, offset + len));
        offset += len;

        final Map<String, dynamic> raw = jsonDecode(jsonStr);
        // Revive Uint8List / FastSerializer payloads if needed
        _revive(raw);
        // FastSerializer-encoded document (type-safe round trip)
        final d = raw['d'];
        if (d is Map && d.length == 1 && d['\u0000fs'] is String) {
          raw['d'] = FastSerializer.deserialize(
            base64Decode(d['\u0000fs'] as String),
          );
        }
        ops.add(LoggedOp.fromJson(raw));
      }
    } catch (_) {}
    return ops;
  }

  void _revive(dynamic v) {
    if (v is Map) {
      for (final key in v.keys.toList()) {
        final val = v[key];
        if (val is String && val.startsWith('\u0000bl:')) {
          v[key] = base64Decode(val.substring(4));
        } else {
          _revive(val);
        }
      }
    } else if (v is List) {
      for (int i = 0; i < v.length; i++) {
        final val = v[i];
        if (val is String && val.startsWith('\u0000bl:')) {
          v[i] = base64Decode(val.substring(4));
        } else {
          _revive(val);
        }
      }
    }
  }

  /// Clears the log (checkpoint).
  Future<void> clear() async {
    if (!_enabled) return;
    _opsSinceClear = 0;
    await _sink?.close();
    if (_file != null && await _file!.exists()) {
      await _file!.writeAsBytes([]);
    }
    _sink = _file?.openWrite(mode: FileMode.append);
  }

  /// Amortized checkpoint: clears the log only once it has accumulated
  /// [_checkpointEvery] durable operations — previously every CRUD op paid a
  /// truncate+reopen (3 syscalls).
  ///
  /// Safe because replays are idempotent and entries are only dropped after
  /// their operation is already durable in the main DB.
  Future<void> maybeCheckpoint() async {
    if (!_enabled) return;
    if (++_opsSinceClear < _checkpointEvery) return;
    await clear();
  }

  Future<void> close() async {
    if (!_enabled) return;
    if (_opsSinceFlush > 0) {
      await _sink?.flush();
      _opsSinceFlush = 0;
    }
    await _sink?.close();
    _sink = null;
  }
}
