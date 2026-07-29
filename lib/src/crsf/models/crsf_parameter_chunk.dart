import 'dart:typed_data';

/// CRSF 参数分块。
class CrsfParameterChunk {
  const CrsfParameterChunk({
    required this.deviceId,
    required this.fieldId,
    required this.chunksRemaining,
    required this.chunkData,
  });

  final int deviceId;
  final int fieldId;
  final int chunksRemaining;
  final Uint8List chunkData;
}
