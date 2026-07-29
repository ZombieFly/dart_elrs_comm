import 'dart:async';
import 'dart:typed_data';

import 'serial_config.dart';

/// 外部调用方需要实现的串口接口。
///
/// [CrsfSession] 通过此接口与底层串口解耦，使用方在构造会话时传入自己的实现。
abstract interface class SerialPort {
  /// 是否已连接。
  bool get isConnected;

  /// 当前连接的端口名称，未连接时为 `null`。
  String? get connectedPortName;

  /// 收到的串口数据流。
  Stream<Uint8List> get onData;

  /// 设备断开事件流。
  Stream<void> get onDeviceLost;

  /// 列出可用串口。
  Future<List<String>> listAllPorts();

  /// 连接指定串口。
  Future<void> connect(String portName, {required SerialConfig config});

  /// 断开串口连接。
  Future<void> disconnect();

  /// 发送字节数据。
  Future<void> sendBytes(Uint8List bytes);
}
