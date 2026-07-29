/// ELRS 状态信息。
class CrsfElrsStatus {
  const CrsfElrsStatus({
    required this.deviceId,
    required this.badPackets,
    required this.goodPackets,
    required this.flags,
    required this.info,
  });

  final int deviceId;
  final int badPackets;
  final int goodPackets;
  final int flags;
  final String info;
}
