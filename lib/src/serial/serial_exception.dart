/// 串口异常。
class SerialException implements Exception {
  const SerialException(this.message);

  final String message;

  @override
  String toString() => 'SerialException: $message';
}

/// 旧异常名称的兼容别名，已废弃，请使用 [SerialException]。
@Deprecated('Use SerialException instead')
typedef SerialServiceException = SerialException;
