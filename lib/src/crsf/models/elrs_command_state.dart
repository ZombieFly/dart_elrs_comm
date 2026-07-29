/// ELRS 命令状态（如 Bind、Load 等命令弹窗）。
class ElrsCommandState {
  const ElrsCommandState({
    required this.deviceId,
    required this.handsetId,
    required this.fieldId,
    required this.name,
    required this.status,
    required this.timeout,
    required this.info,
  });

  final int deviceId;
  final int handsetId;
  final int fieldId;
  final String name;
  final int status;
  final int timeout;
  final String info;

  bool get isRunning => status == 2;
  bool get needsConfirm => status == 3;
  bool get isStopped => status == 0;

  ElrsCommandState copyWith({int? status, int? timeout, String? info}) {
    return ElrsCommandState(
      deviceId: deviceId,
      handsetId: handsetId,
      fieldId: fieldId,
      name: name,
      status: status ?? this.status,
      timeout: timeout ?? this.timeout,
      info: info ?? this.info,
    );
  }
}
