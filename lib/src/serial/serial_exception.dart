/// 串口异常。
class SerialException implements Exception {
  const SerialException(this.message);

  final String message;

  @override
  String toString() => 'SerialException: $message';
}
