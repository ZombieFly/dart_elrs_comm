import 'dart:typed_data';

import 'crsf_constants.dart';
import 'models/crsf_device_info.dart';
import 'models/crsf_elrs_status.dart';
import 'models/crsf_parameter_chunk.dart';
import 'models/elrs_field.dart';

/// CRSF 协议解析器。
///
/// 提供对 DeviceInfo、ParameterChunk、ELRS Status 以及 ELRS Field 的静态解析方法。
/// 外部调用方也可以直接使用这些方法来解析自己收到的 payload。
class CrsfParser {
  CrsfParser._();

  /// 解析设备信息帧 payload。
  static CrsfDeviceInfo? parseDeviceInfo(Uint8List payload) {
    if (payload.length < 3) return null;

    final deviceId = payload[1];
    final nameRead = _readCString(payload, 2);
    final name = nameRead.$1;
    final afterName = nameRead.$2;

    if (payload.length <= afterName + 12) {
      return CrsfDeviceInfo(
        deviceId: deviceId,
        name: name,
        fieldCount: 0,
        isElrs: false,
      );
    }

    final serial = _readUint32Be(payload, afterName);
    final fieldCount = payload[afterName + 12];

    return CrsfDeviceInfo(
      deviceId: deviceId,
      name: name,
      fieldCount: fieldCount,
      isElrs: serial == crsfElrsSerial,
    );
  }

  /// 解析参数分块帧 payload。
  static CrsfParameterChunk? parseParameterChunk(Uint8List payload) {
    if (payload.length < 4) return null;

    return CrsfParameterChunk(
      deviceId: payload[1],
      fieldId: payload[2],
      chunksRemaining: payload[3],
      chunkData: Uint8List.fromList(payload.sublist(4)),
    );
  }

  /// 解析 ELRS 状态帧 payload。
  static CrsfElrsStatus? parseElrsStatus(Uint8List payload) {
    if (payload.length < 6) return null;

    final read = _readCString(payload, 6);
    return CrsfElrsStatus(
      deviceId: payload[1],
      badPackets: payload[2],
      goodPackets: (payload[3] << 8) | payload[4],
      flags: payload[5],
      info: read.$1,
    );
  }

  /// 解析单个 ELRS 字段。
  static ElrsField? parseField({
    required int fieldId,
    required Uint8List data,
  }) {
    if (data.length < 3) return null;

    final parentByte = data[0];
    final rawType = data[1];
    final hidden = (rawType & 0x80) != 0;
    final type = rawType & 0x7F;
    final nameRead = _readCString(data, 2);
    final name = nameRead.$1;
    var offset = nameRead.$2;

    final kind = _fieldKindFromType(type);
    final field = ElrsField(
      id: fieldId,
      name: name,
      parentId: parentByte == 0 ? null : parentByte,
      type: type,
      kind: kind,
      hidden: hidden,
      rawData: data,
    );

    switch (kind) {
      case ElrsFieldKind.uint8:
      case ElrsFieldKind.int8:
      case ElrsFieldKind.uint16:
      case ElrsFieldKind.int16:
        final size = (type ~/ 2) + 1;
        final signed = (type % 2) == 1;
        field.valueSize = size;
        field.signed = signed;
        field.intValue = _readInt(data, offset, size, signed);
        field.minInt = _readInt(data, offset + size, size, signed);
        field.maxInt = _readInt(data, offset + size * 2, size, signed);
        field.stepInt = 1;
        final unitRead = _readCString(data, offset + size * 4);
        field.unit = unitRead.$1;
      case ElrsFieldKind.float:
        field.valueSize = 4;
        field.signed = true;
        field.intValue = _readInt(data, offset, 4, true);
        field.minInt = _readInt(data, offset + 4, 4, true);
        field.maxInt = _readInt(data, offset + 8, 4, true);
        final precision = offset + 16 < data.length
            ? data[offset + 16].clamp(0, 3)
            : 0;
        field.floatDivisor = [1, 10, 100, 1000][precision];
        field.stepInt = _readInt(data, offset + 17, 4, false);
        field.unit = _readCString(data, offset + 21).$1;
      case ElrsFieldKind.textSelect:
        final optionsRead = _readOptions(data, offset);
        field.options = optionsRead.$1;
        offset = optionsRead.$2;
        field.intValue = offset < data.length ? data[offset] : 0;
        field.unit = _readCString(data, offset + 4).$1;
      case ElrsFieldKind.string:
      case ElrsFieldKind.info:
        final strRead = _readCString(data, offset);
        field.stringValue = strRead.$1;
        if (kind == ElrsFieldKind.string && strRead.$2 < data.length) {
          field.maxLength = data[strRead.$2];
        }
      case ElrsFieldKind.command:
        field.commandStatus = offset < data.length ? data[offset] : 0;
        field.commandTimeout = offset + 1 < data.length ? data[offset + 1] : 0;
        field.stringValue = _readCString(data, offset + 2).$1;
      case ElrsFieldKind.folder:
      case ElrsFieldKind.back:
      case ElrsFieldKind.device:
      case ElrsFieldKind.deviceFolder:
      case ElrsFieldKind.unknown:
        break;
    }

    return field;
  }

  static ElrsFieldKind _fieldKindFromType(int type) {
    switch (type) {
      case 0:
        return ElrsFieldKind.uint8;
      case 1:
        return ElrsFieldKind.int8;
      case 2:
        return ElrsFieldKind.uint16;
      case 3:
        return ElrsFieldKind.int16;
      case 8:
        return ElrsFieldKind.float;
      case 9:
        return ElrsFieldKind.textSelect;
      case 10:
        return ElrsFieldKind.string;
      case 11:
        return ElrsFieldKind.folder;
      case 12:
        return ElrsFieldKind.info;
      case 13:
        return ElrsFieldKind.command;
      case 14:
        return ElrsFieldKind.back;
      case 15:
        return ElrsFieldKind.device;
      case 16:
        return ElrsFieldKind.deviceFolder;
      default:
        return ElrsFieldKind.unknown;
    }
  }

  static (List<String>, int) _readOptions(Uint8List data, int start) {
    final values = <String>[];
    final buffer = <int>[];
    var index = start;
    while (index < data.length) {
      final b = data[index++];
      if (b == 0) {
        if (buffer.isNotEmpty) {
          values.add(String.fromCharCodes(buffer));
          buffer.clear();
        }
        break;
      }
      if (b == 59) {
        values.add(String.fromCharCodes(buffer));
        buffer.clear();
      } else {
        buffer.add(b);
      }
    }
    return (values, index);
  }

  static int _readInt(Uint8List data, int start, int size, bool signed) {
    if (start + size > data.length) return 0;
    var value = 0;
    for (var i = 0; i < size; i++) {
      value = (value << 8) | data[start + i];
    }
    if (!signed) return value;
    final signBit = 1 << (size * 8 - 1);
    if ((value & signBit) != 0) {
      value -= 1 << (size * 8);
    }
    return value;
  }

  static (String, int) _readCString(Uint8List data, int start) {
    final bytes = <int>[];
    var index = start;
    while (index < data.length) {
      final value = data[index++];
      if (value == 0) break;
      bytes.add(value);
    }
    return (String.fromCharCodes(bytes), index);
  }

  static int _readUint32Be(Uint8List data, int start) {
    if (start + 3 >= data.length) return 0;
    return (data[start] << 24) |
        (data[start + 1] << 16) |
        (data[start + 2] << 8) |
        data[start + 3];
  }
}
