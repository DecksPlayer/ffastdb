/// No-op implementation of OperationLog for Web/WASM.
class OperationLog {
  final String path;
  OperationLog(this.path);
  OperationLog.disabled() : path = '';
  Future<void> open() async {}
  Future<void> log(String type, {int? id, dynamic data}) async {}
  Future<dynamic> readAll() async => [];
  Future<void> clear() async {}
  Future<void> close() async {}
}
