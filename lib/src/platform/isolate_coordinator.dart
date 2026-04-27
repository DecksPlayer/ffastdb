import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../fastdb.dart';

/// Manages cross-isolate communication using local sockets.
/// This works on all Native platforms without depending on Flutter/dart:ui.
class IsolateCoordinator {
  final String dbName;
  final String directory;
  final FastDB _db;
  ServerSocket? _server;
  final List<Socket> _clients = [];

  IsolateCoordinator(this.dbName, this.directory, this._db);

  String get _portFile => '$directory/$dbName.fdb.port';

  /// Starts a local server to receive write commands from other isolates.
  Future<void> register() async {
    try {
      _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      
      // Save the port to a sidecar file so other isolates can find us
      final file = File(_portFile);
      await file.writeAsString(_server!.port.toString());

      _server!.listen((client) {
        _clients.add(client);
        client.listen((data) => _handleSocketData(client, data), 
          onDone: () => _clients.remove(client),
          onError: (_) => _clients.remove(client),
        );
      });
    } catch (_) {
      // If we can't bind, we just don't act as a coordinator.
    }
  }

  void _handleSocketData(Socket client, Uint8List data) async {
    try {
      final message = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      final String type = message['type'];
      final dynamic payload = message['data'];
      final String? msgId = message['msgId'];

      dynamic result;
      try {
        switch (type) {
          case 'put':
            await _db.put(message['id'], payload);
            result = {'success': true};
            break;
          case 'insert':
            final id = await _db.insert(payload);
            result = {'success': true, 'id': id};
            break;
          case 'delete':
            await _db.delete(message['id']);
            result = {'success': true};
            break;
        }
      } catch (e) {
        result = {'success': false, 'error': e.toString()};
      }

      if (msgId != null) {
        client.write(jsonEncode({'msgId': msgId, ...result}));
      }
    } catch (_) {}
  }

  /// Attempts to find a coordinator server for this DB.
  static Future<int?> findOwnerPort(String dbName, String directory) async {
    try {
      final file = File('$directory/$dbName.fdb.port');
      if (await file.exists()) {
        final content = await file.readAsString();
        return int.tryParse(content);
      }
    } catch (_) {}
    return null;
  }

  /// Returns true if a local socket server is accepting connections on [port].
  /// Used to detect stale .fdb.port files left by crashed owner isolates.
  static Future<bool> isPortAlive(int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4, port,
        timeout: const Duration(milliseconds: 200),
      );
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Deletes the port sidecar file for a given DB (stale file cleanup).
  static Future<void> deletePortFile(String dbName, String directory) async {
    try {
      final file = File('$directory/$dbName.fdb.port');
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  void stop() {
    _server?.close();
    _clients.forEach((c) => c.destroy());
    try {
      File(_portFile).deleteSync();
    } catch (_) {}
  }
}

/// Communicates with the Coordinator Isolate via Sockets.
class SocketProxy {
  final int port;
  final Map<String, Completer> _pending = {};

  SocketProxy(this.port);

  Future<dynamic> call(String type, Map<String, dynamic> params) async {
    final msgId = DateTime.now().microsecondsSinceEpoch.toString();
    final completer = Completer();
    _pending[msgId] = completer;

    Socket? socket;
    try {
      socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      socket.write(jsonEncode({
        'type': type,
        'msgId': msgId,
        'id': params['id'],
        'data': params['doc'] ?? params['value'] ?? params['fields'],
      }));

      socket.listen((data) {
        final response = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
        final String? rid = response['msgId'];
        if (rid != null && _pending.containsKey(rid)) {
          final c = _pending.remove(rid)!;
          if (response['success'] == true) {
            c.complete(response['id'] ?? true);
          } else {
            c.completeError(response['error'] ?? 'Unknown error');
          }
        }
        socket?.destroy();
      }, onError: (e) {
        _pending.remove(msgId)?.completeError(e);
        socket?.destroy();
      });
    } catch (e) {
      _pending.remove(msgId)?.completeError(e);
      socket?.destroy();
    }

    return completer.future;
  }
}
