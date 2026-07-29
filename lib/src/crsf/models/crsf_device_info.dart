/// CRSF 设备信息。
class CrsfDeviceInfo {
  const CrsfDeviceInfo({
    required this.deviceId,
    required this.name,
    required this.fieldCount,
    required this.isElrs,
  });

  final int deviceId;
  final String name;
  final int fieldCount;
  final bool isElrs;
}
