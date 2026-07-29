/// 串口连接配置。
class SerialConfig {
  const SerialConfig({
    this.baudRate = 1870000,
    this.dataBits = 8,
    this.stopBits = 1,
    this.parity = 0,
    this.flowControl = 0,
  });

  final int baudRate;
  final int dataBits;
  final int stopBits;
  final int parity;
  final int flowControl;
}
