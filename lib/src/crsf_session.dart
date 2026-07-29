import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'rc_channel_constants.dart';
import 'serial_interface.dart';

const int crsfAddressBroadcast = 0x00;
const int crsfAddressRadioTransmitter = 0xEA;
const int crsfAddressTxModule = 0xEE;
const int crsfAddressHandsetLua = 0xEF;

const int crsfTypeDevicePing = 0x28;
const int crsfTypeRcChannelsPacked = 0x16;
const int crsfTypeDeviceInfo = 0x29;
const int crsfTypeParameterRead = 0x2C;
const int crsfTypeParameterWrite = 0x2D;
const int crsfTypeParameterInfo = 0x2B;
const int crsfTypeElrsStatus = 0x2E;

const int crsfElrsSerial = 0x454C5253;

class CrsfSerialConfig {
  const CrsfSerialConfig({
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

  SerialConfig toSerialConfig() {
    return SerialConfig(
      baudRate: baudRate,
      dataBits: dataBits,
      stopBits: stopBits,
      parity: parity,
      flowControl: flowControl,
    );
  }
}

class CrsfFrame {
  CrsfFrame({required this.address, required this.type, required this.payload});

  final int address;
  final int type;
  final Uint8List payload;
}

/// CRSF RC Channels 打包（16通道 × 11bit，LSB 优先）
/// - channels: 长度必须为 16，每项将按 11bit（0~2047）处理
/// - 返回: CrsfFrame(0xEE, 0x16, 22字节payload)
CrsfFrame rcChannelsPack(List<int> channels) {
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

class CrsfDeviceInfo {
  CrsfDeviceInfo({
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

class CrsfParameterChunk {
  CrsfParameterChunk({
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

class CrsfElrsStatus {
  CrsfElrsStatus({
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

class CrsfSettingsLoadProgress {
  const CrsfSettingsLoadProgress({
    required this.isLoading,
    required this.loaded,
    required this.total,
  });

  final bool isLoading;
  final int loaded;
  final int total;
}

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

enum ElrsFieldKind {
  uint8,
  int8,
  uint16,
  int16,
  float,
  textSelect,
  string,
  folder,
  info,
  command,
  back,
  device,
  deviceFolder,
  unknown,
}

class ElrsField {
  ElrsField({
    required this.id,
    required this.name,
    required this.parentId,
    required this.type,
    required this.kind,
    required this.hidden,
    this.intValue,
    this.minInt,
    this.maxInt,
    this.stepInt = 1,
    this.unit = '',
    this.options = const <String>[],
    this.stringValue,
    this.commandStatus,
    this.commandTimeout,
    this.rawData = const <int>[],
    this.valueSize = 1,
    this.signed = false,
    this.floatDivisor = 1,
    this.maxLength,
  });

  final int id;
  final String name;
  final int? parentId;
  final int type;
  final ElrsFieldKind kind;
  final bool hidden;

  int? intValue;
  int? minInt;
  int? maxInt;
  int stepInt;
  String unit;
  List<String> options;
  String? stringValue;
  int? commandStatus;
  int? commandTimeout;
  List<int> rawData;
  int valueSize;
  bool signed;
  int floatDivisor;
  int? maxLength;

  bool get isEditable =>
      kind == ElrsFieldKind.uint8 ||
      kind == ElrsFieldKind.int8 ||
      kind == ElrsFieldKind.uint16 ||
      kind == ElrsFieldKind.int16 ||
      kind == ElrsFieldKind.float ||
      kind == ElrsFieldKind.string ||
      kind == ElrsFieldKind.textSelect ||
      kind == ElrsFieldKind.command;
}

class CrsfSession {
  CrsfSession({
    required SerialPort serialPort,
    this.defaultDeviceId = crsfAddressTxModule,
    this.defaultHandsetId = crsfAddressHandsetLua,
  }) : _serial = serialPort {
    _dataSub = _serial.onData.listen(
      _onSerialBytes,
      onError: _rawErrorController.addError,
    );
    _deviceLostSub = _serial.onDeviceLost.listen((_) {
      _deviceLostController.add(null);
    });
  }

  final SerialPort _serial;
  final int defaultDeviceId;
  final int defaultHandsetId;

  final List<int> _rxBuffer = <int>[];

  late final StreamSubscription<Uint8List> _dataSub;
  late final StreamSubscription<void> _deviceLostSub;

  final StreamController<CrsfFrame> _rawFrameController =
      StreamController<CrsfFrame>.broadcast();
  final StreamController<CrsfDeviceInfo> _deviceInfoController =
      StreamController<CrsfDeviceInfo>.broadcast();
  final StreamController<CrsfParameterChunk> _parameterChunkController =
      StreamController<CrsfParameterChunk>.broadcast();
  final StreamController<CrsfElrsStatus> _elrsStatusController =
      StreamController<CrsfElrsStatus>.broadcast();
  final StreamController<void> _deviceLostController =
      StreamController<void>.broadcast();
  final StreamController<Object> _rawErrorController =
      StreamController<Object>.broadcast();
  final StreamController<String> _messageController =
      StreamController<String>.broadcast();
  final StreamController<int?> _activeDeviceController =
      StreamController<int?>.broadcast();
  final StreamController<List<ElrsField>> _elrsFieldsController =
      StreamController<List<ElrsField>>.broadcast();
  final StreamController<CrsfSettingsLoadProgress>
  _settingsLoadProgressController =
      StreamController<CrsfSettingsLoadProgress>.broadcast();
  final StreamController<ElrsCommandState?> _commandStateController =
      StreamController<ElrsCommandState?>.broadcast();

  int? _activeDeviceId;
  final Map<int, CrsfDeviceInfo> _devices = <int, CrsfDeviceInfo>{};
  List<ElrsField> _elrsFields = <ElrsField>[];
  final Map<String, List<int>> _chunkBuffers = <String, List<int>>{};

  final List<int> _fieldLoadQueue = <int>[];
  Timer? _pollTimer;
  Timer? _rcSendTimer;
  List<int> _rcChannels = List<int>.filled(16, rcChannelCenter);
  double _rcSendHz = 50;
  DateTime _nextDevicesRefreshAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _nextLinkStatsAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _nextFieldPollAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastCrcResendAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _nextCommandQueryAt = DateTime.fromMillisecondsSinceEpoch(0);

  _PendingParameterRead? _pendingParameterRead;
  int _crcErrorCount = 0;
  bool _isReloadingAllSettingsAfterWrite = false;
  bool _pendingReloadAllSettingsAfterWrite = false;
  ElrsCommandState? _commandState;

  static const int _chunkTimeoutRetries = 50;
  static const int _maxCrcResendPerChunk = 50;
  static const Duration _crcResendCooldown = Duration(milliseconds: 10);

  bool get isConnected => _serial.isConnected;
  String? get connectedPortName => _serial.connectedPortName;

  Stream<CrsfFrame> get onRawFrame => _rawFrameController.stream;
  Stream<CrsfDeviceInfo> get onDeviceInfo => _deviceInfoController.stream;
  Stream<CrsfParameterChunk> get onParameterChunk =>
      _parameterChunkController.stream;
  Stream<CrsfElrsStatus> get onElrsStatus => _elrsStatusController.stream;
  Stream<void> get onDeviceLost => _deviceLostController.stream;
  Stream<Object> get onRawError => _rawErrorController.stream;
  Stream<String> get onMessage => _messageController.stream;
  Stream<int?> get onActiveDeviceChanged => _activeDeviceController.stream;
  Stream<List<ElrsField>> get onElrsFieldsChanged =>
      _elrsFieldsController.stream;
  Stream<CrsfSettingsLoadProgress> get onSettingsLoadProgress =>
      _settingsLoadProgressController.stream;
  Stream<ElrsCommandState?> get onCommandStateChanged =>
      _commandStateController.stream;
  int? get activeDeviceId => _activeDeviceId;
  ElrsCommandState? get commandState => _commandState;
  List<ElrsField> get elrsFields => List<ElrsField>.unmodifiable(_elrsFields);
  bool get isRcSending => _rcSendTimer?.isActive ?? false;
  double get rcSendHz => _rcSendHz;
  List<int> get rcChannels => List<int>.unmodifiable(_rcChannels);

  CrsfDeviceInfo? getDevice(int id) => _devices[id];

  Future<List<String>> listAllPorts() => _serial.listAllPorts();

  Future<void> connect(
    String portName, {
    CrsfSerialConfig config = const CrsfSerialConfig(),
  }) {
    return _serial.connect(portName, config: config.toSerialConfig());
  }

  Future<void> disconnect() async {
    stopRcSending();
    await _serial.disconnect();
    _rxBuffer.clear();
    _chunkBuffers.clear();
    _fieldLoadQueue.clear();
    _pendingParameterRead = null;
    _pendingReloadAllSettingsAfterWrite = false;
    stopAutoPolling();
    _setCommandState(null);
    _setActiveDeviceId(null);
  }

  void pingDevices() {
    push(crsfTypeDevicePing, <int>[
      crsfAddressBroadcast,
      crsfAddressRadioTransmitter,
    ]);
  }

  void discoverDevices() {
    pingDevices();
  }

  void requestField({
    required int fieldId,
    int chunk = 0,
    int? deviceId,
    int? handsetId,
  }) {
    final targetDeviceId = deviceId ?? defaultDeviceId;
    final targetHandsetId = handsetId ?? _resolveHandsetId(targetDeviceId);
    requestParameterChunk(
      deviceId: targetDeviceId,
      handsetId: targetHandsetId,
      fieldId: fieldId,
      chunk: chunk,
    );
  }

  void requestField1({int? deviceId, int chunk = 0}) {
    requestField(fieldId: 1, deviceId: deviceId, chunk: chunk);
  }

  Future<List<ElrsField>> loadDeviceSettings({
    int deviceId = crsfAddressTxModule,
    Duration timeout = const Duration(milliseconds: 100),
    void Function(int loaded, int total)? onProgress,
  }) async {
    var loadedCount = 0;
    var totalCount = 0;
    _emitSettingsLoadProgress(
      isLoading: true,
      loaded: loadedCount,
      total: totalCount,
    );
    final resumePolling = isAutoPolling;
    if (resumePolling) {
      stopAutoPolling();
    }
    _chunkBuffers.clear();
    _fieldLoadQueue.clear();

    discoverDevices();
    try {
      final info = await _waitDeviceInfo(deviceId: deviceId, timeout: timeout);
      _setActiveDeviceId(deviceId);
      final handsetId = _resolveHandsetId(deviceId);
      final loaded = <ElrsField>[];
      totalCount = info.fieldCount;
      onProgress?.call(loadedCount, totalCount);
      _emitSettingsLoadProgress(
        isLoading: true,
        loaded: loadedCount,
        total: totalCount,
      );

      for (var fieldId = 1; fieldId <= info.fieldCount; fieldId++) {
        final bytes = await _loadParameterBytes(
          deviceId: deviceId,
          handsetId: handsetId,
          fieldId: fieldId,
          timeout: timeout,
        );
        final field = _parseElrsField(fieldId: fieldId, data: bytes);
        if (field != null) {
          loaded.add(field);
        }
        loadedCount = fieldId;
        onProgress?.call(loadedCount, totalCount);
        _emitSettingsLoadProgress(
          isLoading: true,
          loaded: loadedCount,
          total: totalCount,
        );
      }

      loaded.addAll(
        _buildOtherDeviceFields(
          currentDeviceId: deviceId,
          currentDeviceFieldCount: info.fieldCount,
        ),
      );

      _elrsFields = loaded;
      _elrsFieldsController.add(List<ElrsField>.unmodifiable(_elrsFields));
      _emitMessage('已加载 TX 设置项: ${_elrsFields.length}');
      return List<ElrsField>.unmodifiable(_elrsFields);
    } finally {
      _emitSettingsLoadProgress(
        isLoading: false,
        loaded: loadedCount,
        total: totalCount,
      );
      if (resumePolling) {
        startAutoPolling();
      }
    }
  }

  Future<List<ElrsField>> loadTxSettings({
    int deviceId = crsfAddressTxModule,
    Duration timeout = const Duration(milliseconds: 100),
    void Function(int loaded, int total)? onProgress,
  }) {
    return loadDeviceSettings(
      deviceId: deviceId,
      timeout: timeout,
      onProgress: onProgress,
    );
  }

  Future<void> setIntFieldValue({
    required ElrsField field,
    required int value,
    int? deviceId,
    int? handsetId,
  }) async {
    if (!(field.kind == ElrsFieldKind.uint8 ||
        field.kind == ElrsFieldKind.int8 ||
        field.kind == ElrsFieldKind.uint16 ||
        field.kind == ElrsFieldKind.int16)) {
      throw SerialServiceException('该字段不是整型可写字段');
    }

    final actualDeviceId = deviceId ?? activeDeviceId ?? defaultDeviceId;
    final actualHandsetId = handsetId ?? _resolveHandsetId(actualDeviceId);
    final payloadValue = _toFieldValueBytes(
      value: value,
      size: field.valueSize,
      signed: field.signed,
    );
    writeParameterValue(
      deviceId: actualDeviceId,
      handsetId: actualHandsetId,
      fieldId: field.id,
      valueBytes: payloadValue,
    );
    _onParameterFieldWritten(
      deviceId: actualDeviceId,
      updateLocalField: () => field.intValue = value,
    );
  }

  Future<void> setSelectFieldValue({
    required ElrsField field,
    required int index,
    int? deviceId,
    int? handsetId,
  }) async {
    if (field.kind != ElrsFieldKind.textSelect) {
      throw SerialServiceException('该字段不是选项可写字段');
    }
    final actualDeviceId = deviceId ?? activeDeviceId ?? defaultDeviceId;
    final actualHandsetId = handsetId ?? _resolveHandsetId(actualDeviceId);
    writeParameterValue(
      deviceId: actualDeviceId,
      handsetId: actualHandsetId,
      fieldId: field.id,
      valueBytes: <int>[index & 0xFF],
    );
    _onParameterFieldWritten(
      deviceId: actualDeviceId,
      updateLocalField: () => field.intValue = index,
    );
  }

  Future<void> executeCommandField({
    required ElrsField field,
    int status = 1,
    int? deviceId,
    int? handsetId,
  }) async {
    if (field.kind != ElrsFieldKind.command) {
      throw SerialServiceException('该字段不是命令字段');
    }
    final actualDeviceId = deviceId ?? activeDeviceId ?? defaultDeviceId;
    final actualHandsetId = handsetId ?? _resolveHandsetId(actualDeviceId);
    _setCommandState(
      ElrsCommandState(
        deviceId: actualDeviceId,
        handsetId: actualHandsetId,
        fieldId: field.id,
        name: field.name,
        status: status,
        timeout: field.commandTimeout ?? 100,
        info: field.stringValue ?? '',
      ),
    );
    sendCommand(
      deviceId: actualDeviceId,
      handsetId: actualHandsetId,
      fieldId: field.id,
      status: status,
    );
    _nextCommandQueryAt = DateTime.now();
  }

  Future<void> confirmActiveCommand() async {
    final state = _commandState;
    if (state == null) {
      return;
    }
    sendCommand(
      deviceId: state.deviceId,
      handsetId: state.handsetId,
      fieldId: state.fieldId,
      status: 4,
    );
    _setCommandState(state.copyWith(status: 4));
    _nextCommandQueryAt = DateTime.now();
  }

  Future<void> cancelActiveCommand() async {
    final state = _commandState;
    if (state == null) {
      return;
    }
    sendCommand(
      deviceId: state.deviceId,
      handsetId: state.handsetId,
      fieldId: state.fieldId,
      status: 5,
    );
    _setCommandState(null);
  }

  void dismissActiveCommandPopup() {
    _setCommandState(null);
  }

  Future<void> setFloatFieldValue({
    required ElrsField field,
    required double value,
    int? deviceId,
    int? handsetId,
  }) async {
    if (field.kind != ElrsFieldKind.float) {
      throw SerialServiceException('该字段不是浮点可写字段');
    }
    final actualDeviceId = deviceId ?? activeDeviceId ?? defaultDeviceId;
    final actualHandsetId = handsetId ?? _resolveHandsetId(actualDeviceId);
    final raw = (value * field.floatDivisor).round();
    final payloadValue = _toFieldValueBytes(value: raw, size: 4, signed: true);
    writeParameterValue(
      deviceId: actualDeviceId,
      handsetId: actualHandsetId,
      fieldId: field.id,
      valueBytes: payloadValue,
    );
    _onParameterFieldWritten(
      deviceId: actualDeviceId,
      updateLocalField: () => field.intValue = raw,
    );
  }

  Future<void> setStringFieldValue({
    required ElrsField field,
    required String value,
    int? deviceId,
    int? handsetId,
  }) async {
    if (field.kind != ElrsFieldKind.string) {
      throw SerialServiceException('该字段不是字符串可写字段');
    }
    final actualDeviceId = deviceId ?? activeDeviceId ?? defaultDeviceId;
    final actualHandsetId = handsetId ?? _resolveHandsetId(actualDeviceId);
    final bytes = utf8.encode(value);
    final maxLength = field.maxLength;
    final limited = maxLength == null
        ? bytes
        : bytes.take(maxLength).toList(growable: false);
    writeParameterValue(
      deviceId: actualDeviceId,
      handsetId: actualHandsetId,
      fieldId: field.id,
      valueBytes: <int>[...limited, 0],
    );
    _onParameterFieldWritten(
      deviceId: actualDeviceId,
      updateLocalField: () =>
          field.stringValue = utf8.decode(limited, allowMalformed: true),
    );
  }

  void _onParameterFieldWritten({
    required int deviceId,
    required void Function() updateLocalField,
  }) {
    updateLocalField();
    _elrsFieldsController.add(List<ElrsField>.unmodifiable(_elrsFields));
    _scheduleReloadAllSettingsAfterWrite(deviceId: deviceId);
  }

  void reloadAllFields() {
    final activeId = _activeDeviceId;
    final realFieldCount = activeId == null
        ? 0
        : (_devices[activeId]?.fieldCount ?? 0);
    _fieldLoadQueue
      ..clear()
      ..addAll(
        _elrsFields
            .where(
              (field) =>
                  field.kind != ElrsFieldKind.device &&
                  field.kind != ElrsFieldKind.deviceFolder &&
                  (realFieldCount <= 0 || field.id <= realFieldCount),
            )
            .map((field) => field.id)
            .toList()
            .reversed,
      );
    _nextFieldPollAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  List<ElrsField> _buildOtherDeviceFields({
    required int currentDeviceId,
    required int currentDeviceFieldCount,
  }) {
    final otherDevices =
        _devices.values
            .where(
              (device) => device.deviceId != currentDeviceId,
              // && device.fieldCount > 0,
              // 可选忽略 fieldCount 为 0 的设备
            )
            .toList()
          ..sort((a, b) => a.deviceId.compareTo(b.deviceId));
    if (otherDevices.isEmpty) {
      return const <ElrsField>[];
    }

    final folderId = currentDeviceFieldCount + 1;
    final fields = <ElrsField>[
      ElrsField(
        id: folderId,
        name: 'Other Devices',
        parentId: null,
        type: 16,
        kind: ElrsFieldKind.deviceFolder,
        hidden: false,
      ),
    ];

    for (var i = 0; i < otherDevices.length; i++) {
      final device = otherDevices[i];
      fields.add(
        ElrsField(
          id: folderId + i + 1,
          name: device.name,
          parentId: folderId,
          type: 15,
          kind: ElrsFieldKind.device,
          hidden: false,
          intValue: device.deviceId,
          stringValue: device.name,
        ),
      );
    }

    return fields;
  }

  void _scheduleReloadAllSettingsAfterWrite({required int deviceId}) {
    if (_isReloadingAllSettingsAfterWrite) {
      _pendingReloadAllSettingsAfterWrite = true;
      return;
    }
    unawaited(_reloadAllSettingsAfterWrite(deviceId: deviceId));
  }

  Future<void> _reloadAllSettingsAfterWrite({required int deviceId}) async {
    if (!isConnected) {
      return;
    }

    if (_isReloadingAllSettingsAfterWrite) {
      _pendingReloadAllSettingsAfterWrite = true;
      return;
    }

    _isReloadingAllSettingsAfterWrite = true;
    try {
      await loadDeviceSettings(
        deviceId: deviceId,
        timeout: const Duration(milliseconds: 200),
      );
      _emitMessage('参数写入后已重新加载全部设置');
    } catch (e) {
      _emitMessage('参数写入后全量刷新失败: $e');
    } finally {
      _isReloadingAllSettingsAfterWrite = false;
      if (_pendingReloadAllSettingsAfterWrite && isConnected) {
        _pendingReloadAllSettingsAfterWrite = false;
        unawaited(_reloadAllSettingsAfterWrite(deviceId: deviceId));
      }
    }
  }

  void startAutoPolling({
    Duration interval = const Duration(milliseconds: 100),
  }) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(interval, (_) => _onPollTick());
  }

  void stopAutoPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  bool get isAutoPolling => _pollTimer?.isActive ?? false;

  void requestParameterChunk({
    required int deviceId,
    required int handsetId,
    required int fieldId,
    int chunk = 0,
  }) {
    push(crsfTypeParameterRead, <int>[deviceId, handsetId, fieldId, chunk]);
  }

  void writeParameterValue({
    required int deviceId,
    required int handsetId,
    required int fieldId,
    required List<int> valueBytes,
  }) {
    final payload = <int>[deviceId, handsetId, fieldId, ...valueBytes];
    push(crsfTypeParameterWrite, payload);
  }

  void sendCommand({
    required int deviceId,
    required int handsetId,
    required int fieldId,
    required int status,
  }) {
    // 打印到日志，方便调试
    push(crsfTypeParameterWrite, <int>[deviceId, handsetId, fieldId, status]);
  }

  void requestLinkStats({int? deviceId, int? handsetId}) {
    push(crsfTypeParameterWrite, <int>[
      deviceId ?? defaultDeviceId,
      handsetId ?? defaultHandsetId,
      0x00,
      0x00,
    ]);
  }

  void clearElrsWarning({int? deviceId, int? handsetId}) {
    push(crsfTypeParameterWrite, <int>[
      deviceId ?? defaultDeviceId,
      handsetId ?? defaultHandsetId,
      0x2E,
      0x00,
    ]);
  }

  int _resolveHandsetId(int deviceId) {
    return deviceId == crsfAddressTxModule
        ? crsfAddressHandsetLua
        : crsfAddressRadioTransmitter;
  }

  int push(int type, List<int> payload, {int address = crsfAddressTxModule}) {
    final frame = _buildFrame(address: address, type: type, payload: payload);
    unawaited(
      _serial.sendBytes(Uint8List.fromList(frame)).catchError((Object error) {
        _rawErrorController.add(error);
        _emitMessage('串口发送失败: $error');
      }),
    );
    return frame.length;
  }

  int sendRcChannels(List<int> channels) {
    final frame = rcChannelsPack(channels);
    return push(frame.type, frame.payload, address: frame.address);
  }

  void setRcChannels(List<int> channels) {
    if (channels.length != 16) {
      throw ArgumentError('channels 必须包含 16 个通道');
    }
    _rcChannels = List<int>.from(channels);
  }

  void setRcSendFrequency(double hz) {
    if (hz <= 0) {
      throw ArgumentError('频率必须为正数');
    }
    _rcSendHz = hz;
    if (isRcSending) {
      _restartRcTimer();
    }
  }

  void startRcSending() {
    if (!isConnected) {
      throw SerialServiceException('RC发送失败: 串口未连接');
    }
    _restartRcTimer();
  }

  void stopRcSending() {
    _rcSendTimer?.cancel();
    _rcSendTimer = null;
  }

  void _restartRcTimer() {
    _rcSendTimer?.cancel();
    final intervalUs = (1000000 / _rcSendHz).round();
    final interval = Duration(
      microseconds: intervalUs < 1000 ? 1000 : intervalUs,
    );

    _rcSendTimer = Timer.periodic(interval, (_) {
      try {
        sendRcChannels(_rcChannels);
      } catch (e) {
        stopRcSending();
        _emitMessage('RC发送异常: $e');
      }
    });
  }

  void _onSerialBytes(Uint8List bytes) {
    _rxBuffer.addAll(bytes);
    _drainBuffer();
  }

  void _drainBuffer() {
    while (_rxBuffer.length >= 4) {
      final len = _rxBuffer[1];
      if (len < 2) {
        _rxBuffer.removeAt(0);
        continue;
      }

      final frameLength = len + 2;
      if (_rxBuffer.length < frameLength) {
        return;
      }

      final candidate = _rxBuffer.sublist(0, frameLength);
      final expectedCrc = candidate.last;
      final computedCrc = _crc8(
        Uint8List.fromList(candidate.sublist(2, frameLength - 1)),
      );

      if (expectedCrc != computedCrc) {
        _crcErrorCount += 1;
        _retryPendingParameterChunkOnCrcError();
        _rxBuffer.removeAt(0);
        continue;
      }

      final frame = CrsfFrame(
        address: candidate[0],
        type: candidate[2],
        payload: Uint8List.fromList(candidate.sublist(3, frameLength - 1)),
      );

      _rawFrameController.add(frame);
      _dispatchFrame(frame);
      _rxBuffer.removeRange(0, frameLength);
    }
  }

  void _dispatchFrame(CrsfFrame frame) {
    switch (frame.type) {
      case crsfTypeDeviceInfo:
        final info = _parseDeviceInfo(frame.payload);
        if (info != null) {
          _devices[info.deviceId] = info;
          _deviceInfoController.add(info);
          _setActiveDeviceId(_activeDeviceId ?? info.deviceId);
          _emitMessage(
            '设备: id=0x${info.deviceId.toRadixString(16).toUpperCase()} name=${info.name} fields=${info.fieldCount} elrs=${info.isElrs}',
          );
        }
        break;
      case crsfTypeParameterInfo:
        final chunk = _parseParameterChunk(frame.payload);
        if (chunk != null) {
          _parameterChunkController.add(chunk);
          _emitMessage(
            '参数块: dev=0x${chunk.deviceId.toRadixString(16).toUpperCase()} field=${chunk.fieldId} remain=${chunk.chunksRemaining} bytes=${chunk.chunkData.length}',
          );
          _consumeFieldChunk(chunk);
        }
        break;
      case crsfTypeElrsStatus:
        final status = _parseElrsStatus(frame.payload);
        if (status != null) {
          _elrsStatusController.add(status);
          _emitMessage(
            'ELRS状态: bad=${status.badPackets} good=${status.goodPackets} flags=0x${status.flags.toRadixString(16).toUpperCase()} info=${status.info}',
          );
        }
        break;
      case crsfTypeParameterWrite:
        if (frame.payload.length >= 2 &&
            frame.payload[0] == crsfAddressRadioTransmitter &&
            frame.payload[1] == crsfAddressTxModule) {
          const message = '检测到 ELRS v1 固件响应';
          _rawErrorController.add(SerialServiceException(message));
          _emitMessage('CRSF错误: $message');
        }
        break;
      default:
        break;
    }
  }

  Future<CrsfDeviceInfo> _waitDeviceInfo({
    required int deviceId,
    required Duration timeout,
  }) async {
    final cached = _devices[deviceId];
    if (cached != null && cached.fieldCount > 0) {
      return cached;
    }

    return onDeviceInfo
        .firstWhere((info) => info.deviceId == deviceId)
        .timeout(
          timeout,
          onTimeout: () => throw TimeoutException(
            '等待设备信息超时: 0x${deviceId.toRadixString(16)}',
          ),
        );
  }

  void _onPollTick() {
    if (!isConnected) {
      return;
    }

    final now = DateTime.now();
    if (_devices.isEmpty && now.isAfter(_nextDevicesRefreshAt)) {
      discoverDevices();
      _nextDevicesRefreshAt = now.add(const Duration(seconds: 1));
    }

    if (now.isAfter(_nextLinkStatsAt)) {
      requestLinkStats();
      _nextLinkStatsAt = now.add(const Duration(seconds: 1));
    }

    if (_fieldLoadQueue.isNotEmpty && now.isAfter(_nextFieldPollAt)) {
      final fieldId = _fieldLoadQueue.removeLast();
      requestField(fieldId: fieldId, deviceId: activeDeviceId, chunk: 0);
      _nextFieldPollAt = now.add(
        activeDeviceId == crsfAddressTxModule
            ? const Duration(milliseconds: 50)
            : const Duration(milliseconds: 500),
      );
    }

    final command = _commandState;
    if (command != null &&
        !command.needsConfirm &&
        now.isAfter(_nextCommandQueryAt)) {
      sendCommand(
        deviceId: command.deviceId,
        handsetId: command.handsetId,
        fieldId: command.fieldId,
        status: 6,
      );
      _nextCommandQueryAt = now.add(
        Duration(
          milliseconds: (command.timeout <= 0 ? 100 : command.timeout) * 10,
        ),
      );
    }
  }

  void _consumeFieldChunk(CrsfParameterChunk chunk) {
    final key = '${chunk.deviceId}:${chunk.fieldId}';
    final buffer = _chunkBuffers.putIfAbsent(key, () => <int>[]);
    buffer.addAll(chunk.chunkData);
    if (chunk.chunksRemaining > 0) {
      return;
    }

    _chunkBuffers.remove(key);
    final parsed = _parseElrsField(
      fieldId: chunk.fieldId,
      data: Uint8List.fromList(buffer),
    );
    if (parsed == null) {
      return;
    }

    final index = _elrsFields.indexWhere((field) => field.id == parsed.id);
    if (index >= 0) {
      _elrsFields[index] = parsed;
      _elrsFieldsController.add(List<ElrsField>.unmodifiable(_elrsFields));
    }

    final command = _commandState;
    if (command != null &&
        parsed.kind == ElrsFieldKind.command &&
        parsed.id == command.fieldId) {
      final updated = command.copyWith(
        status: parsed.commandStatus ?? command.status,
        timeout: parsed.commandTimeout ?? command.timeout,
        info: parsed.stringValue?.isNotEmpty == true
            ? parsed.stringValue
            : command.info,
      );
      _setCommandState(updated);
    }
  }

  Future<Uint8List> _loadParameterBytes({
    required int deviceId,
    required int handsetId,
    required int fieldId,
    required Duration timeout,
  }) async {
    final output = <int>[];
    var chunk = 0;
    while (true) {
      final response = await _requestParameterChunkWithRetry(
        deviceId: deviceId,
        handsetId: handsetId,
        fieldId: fieldId,
        chunk: chunk,
        timeout: timeout,
        maxRetries: _chunkTimeoutRetries,
      );
      output.addAll(response.chunkData);
      if (response.chunksRemaining == 0) {
        break;
      }
      chunk += 1;
    }
    return Uint8List.fromList(output);
  }

  Future<CrsfParameterChunk> _requestParameterChunkWithRetry({
    required int deviceId,
    required int handsetId,
    required int fieldId,
    required int chunk,
    required Duration timeout,
    required int maxRetries,
  }) async {
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      _pendingParameterRead = _PendingParameterRead(
        deviceId: deviceId,
        handsetId: handsetId,
        fieldId: fieldId,
        chunk: chunk,
      );

      requestParameterChunk(
        deviceId: deviceId,
        handsetId: handsetId,
        fieldId: fieldId,
        chunk: chunk,
      );

      try {
        final response = await onParameterChunk
            .firstWhere(
              (item) => item.deviceId == deviceId && item.fieldId == fieldId,
            )
            .timeout(
              timeout,
              onTimeout: () => throw TimeoutException(
                '等待参数块超时: field=$fieldId chunk=$chunk',
              ),
            );
        _pendingParameterRead = null;
        return response;
      } on TimeoutException {
        final isLastAttempt = attempt >= maxRetries;
        if (isLastAttempt) {
          _pendingParameterRead = null;
          rethrow;
        }
        _emitMessage(
          '参数块超时，自动重发: field=$fieldId chunk=$chunk (${attempt + 1}/${maxRetries + 1})',
        );
      }
    }

    _pendingParameterRead = null;
    throw TimeoutException('参数块重试失败: field=$fieldId chunk=$chunk');
  }

  void _retryPendingParameterChunkOnCrcError() {
    final pending = _pendingParameterRead;
    if (pending == null || !isConnected) {
      return;
    }
    if (pending.crcResendCount >= _maxCrcResendPerChunk) {
      return;
    }

    final now = DateTime.now();
    if (now.difference(_lastCrcResendAt) < _crcResendCooldown) {
      return;
    }

    _lastCrcResendAt = now;
    pending.crcResendCount += 1;
    requestParameterChunk(
      deviceId: pending.deviceId,
      handsetId: pending.handsetId,
      fieldId: pending.fieldId,
      chunk: pending.chunk,
    );
    _emitMessage(
      '检测到CRC错误(#$_crcErrorCount)，自动重发参数块: field=${pending.fieldId} chunk=${pending.chunk} (${pending.crcResendCount}/$_maxCrcResendPerChunk)',
    );
  }

  ElrsField? _parseElrsField({required int fieldId, required Uint8List data}) {
    if (data.length < 3) {
      return null;
    }

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
        break;
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
        break;
      case ElrsFieldKind.textSelect:
        final optionsRead = _readOptions(data, offset);
        field.options = optionsRead.$1;
        offset = optionsRead.$2;
        field.intValue = offset < data.length ? data[offset] : 0;
        field.unit = _readCString(data, offset + 4).$1;
        break;
      case ElrsFieldKind.string:
      case ElrsFieldKind.info:
        final strRead = _readCString(data, offset);
        field.stringValue = strRead.$1;
        if (kind == ElrsFieldKind.string && strRead.$2 < data.length) {
          field.maxLength = data[strRead.$2];
        }
        break;
      case ElrsFieldKind.command:
        field.commandStatus = offset < data.length ? data[offset] : 0;
        field.commandTimeout = offset + 1 < data.length ? data[offset + 1] : 0;
        field.stringValue = _readCString(data, offset + 2).$1;
        break;
      case ElrsFieldKind.folder:
      case ElrsFieldKind.back:
      case ElrsFieldKind.device:
      case ElrsFieldKind.deviceFolder:
      case ElrsFieldKind.unknown:
        break;
    }

    return field;
  }

  ElrsFieldKind _fieldKindFromType(int type) {
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

  (List<String>, int) _readOptions(Uint8List data, int start) {
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

  int _readInt(Uint8List data, int start, int size, bool signed) {
    if (start + size > data.length) {
      return 0;
    }
    var value = 0;
    for (var i = 0; i < size; i++) {
      value = (value << 8) | data[start + i];
    }
    if (!signed) {
      return value;
    }
    final signBit = 1 << (size * 8 - 1);
    if ((value & signBit) != 0) {
      value -= 1 << (size * 8);
    }
    return value;
  }

  List<int> _toFieldValueBytes({
    required int value,
    required int size,
    required bool signed,
  }) {
    var normalized = value;
    if (signed && value < 0) {
      normalized = (1 << (size * 8)) + value;
    }
    final out = <int>[];
    for (var i = size - 1; i >= 0; i--) {
      out.add((normalized >> (8 * i)) & 0xFF);
    }
    return out;
  }

  void _emitMessage(String message) {
    _messageController.add(message);
  }

  void _emitSettingsLoadProgress({
    required bool isLoading,
    required int loaded,
    required int total,
  }) {
    _settingsLoadProgressController.add(
      CrsfSettingsLoadProgress(
        isLoading: isLoading,
        loaded: loaded,
        total: total,
      ),
    );
  }

  void _setCommandState(ElrsCommandState? state) {
    _commandState = state;
    _commandStateController.add(state);
  }

  void _setActiveDeviceId(int? id) {
    if (_activeDeviceId == id) {
      return;
    }
    _activeDeviceId = id;
    _activeDeviceController.add(id);
  }

  CrsfDeviceInfo? _parseDeviceInfo(Uint8List payload) {
    if (payload.length < 3) {
      return null;
    }

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

  CrsfParameterChunk? _parseParameterChunk(Uint8List payload) {
    if (payload.length < 4) {
      return null;
    }

    return CrsfParameterChunk(
      deviceId: payload[1],
      fieldId: payload[2],
      chunksRemaining: payload[3],
      chunkData: Uint8List.fromList(payload.sublist(4)),
    );
  }

  CrsfElrsStatus? _parseElrsStatus(Uint8List payload) {
    if (payload.length < 6) {
      return null;
    }

    final read = _readCString(payload, 6);
    return CrsfElrsStatus(
      deviceId: payload[1],
      badPackets: payload[2],
      goodPackets: (payload[3] << 8) | payload[4],
      flags: payload[5],
      info: read.$1,
    );
  }

  List<int> _buildFrame({
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
    final crc = _crc8(Uint8List.fromList(frame.sublist(2)));
    frame.add(crc);
    return frame;
  }

  int _crc8(Uint8List data) {
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

  (String, int) _readCString(Uint8List data, int start) {
    final bytes = <int>[];
    var index = start;
    while (index < data.length) {
      final value = data[index];
      index += 1;
      if (value == 0) {
        break;
      }
      bytes.add(value);
    }
    return (String.fromCharCodes(bytes), index);
  }

  int _readUint32Be(Uint8List data, int start) {
    if (start + 3 >= data.length) {
      return 0;
    }
    return (data[start] << 24) |
        (data[start + 1] << 16) |
        (data[start + 2] << 8) |
        data[start + 3];
  }

  Future<void> dispose() async {
    await _dataSub.cancel();
    await _deviceLostSub.cancel();
    _pollTimer?.cancel();
    _rcSendTimer?.cancel();
    _rawFrameController.close();
    _deviceInfoController.close();
    _parameterChunkController.close();
    _elrsStatusController.close();
    _deviceLostController.close();
    _rawErrorController.close();
    _messageController.close();
    _activeDeviceController.close();
    _elrsFieldsController.close();
    _settingsLoadProgressController.close();
    _commandStateController.close();
  }
}

class _PendingParameterRead {
  _PendingParameterRead({
    required this.deviceId,
    required this.handsetId,
    required this.fieldId,
    required this.chunk,
  });

  final int deviceId;
  final int handsetId;
  final int fieldId;
  final int chunk;
  int crcResendCount = 0;
}
