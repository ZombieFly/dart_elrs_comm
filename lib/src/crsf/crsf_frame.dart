import 'dart:typed_data';

import 'crsf_constants.dart';

/// CRSF 帧。
class CrsfFrame {
  const CrsfFrame({
    required this.address,
    required this.type,
    required this.payload,
  });

  final int address;
  final int type;
  final Uint8List payload;

  /// 将帧序列化为完整字节（含地址、长度、类型、payload、CRC）。
  Uint8List toBytes() => CrsfFrameBuilder.build(
    address: address,
    type: type,
    payload: payload,
  );
}

/// CRSF 帧构建工具。
class CrsfFrameBuilder {
  CrsfFrameBuilder._();

  /// 构建完整 CRSF 帧字节。
  static Uint8List build({
    required int address,
    required int type,
    required List<int> payload,
  }) {
    final len = payload.length + 2;
    final frame = <int>[
      address & 0xFF,
      len & 0xFF,
      type & 0xFF,
      ...payload.map((e) => e & 0xFF),
    ];
    final crc = crc8(Uint8List.fromList(frame.sublist(2)));
    frame.add(crc);
    return Uint8List.fromList(frame);
  }

  /// CRSF RC Channels 打包（16通道 × 11bit，LSB 优先）。
  /// - channels: 长度必须为 16，每项将按 11bit（0~2047）处理
  static CrsfFrame rcChannels(List<int> channels) {
    const numChannels = 16;
    const srcBits = 11;
    const channelMask = (1 << srcBits) - 1;

    if (channels.length != numChannels) {
      throw ArgumentError('channels 必须包含 16 个通道');
    }

    var bitsMerged = 0;
    var writeValue = 0;
    final payload = <int>[];

    for (final channel in channels) {
      writeValue |= (channel & channelMask) << bitsMerged;
      bitsMerged += srcBits;

      while (bitsMerged >= 8) {
        payload.add(writeValue & 0xFF);
        writeValue >>= 8;
        bitsMerged -= 8;
      }
    }

    return CrsfFrame(
      address: crsfAddressTxModule,
      type: crsfTypeRcChannelsPacked,
      payload: Uint8List.fromList(payload),
    );
  }

  /// CRSF CRC-8-D5 校验。
  static int crc8(Uint8List data) {
    var crc = 0;
    for (final byte in data) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        if ((crc & 0x80) != 0) {
          crc = ((crc << 1) ^ 0xD5) & 0xFF;
        } else {
          crc = (crc << 1) & 0xFF;
        }
      }
    }
    return crc & 0xFF;
  }
}

/// CRSF RC Channels 打包（16通道 × 11bit，LSB 优先）。
///
/// 这是 [CrsfFrameBuilder.rcChannels] 的顶层便捷函数。
CrsfFrame rcChannelsPack(List<int> channels) =>
    CrsfFrameBuilder.rcChannels(channels);
