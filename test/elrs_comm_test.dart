import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:elrs_comm/elrs_comm.dart';

class _FakeSerialPort implements SerialPort {
  final _dataController = StreamController<Uint8List>.broadcast();
  final _deviceLostController = StreamController<void>.broadcast();
  final List<Uint8List> sent = <Uint8List>[];

  @override
  bool isConnected = false;

  @override
  String? connectedPortName;

  @override
  Stream<Uint8List> get onData => _dataController.stream;

  @override
  Stream<void> get onDeviceLost => _deviceLostController.stream;

  @override
  Future<List<String>> listAllPorts() async => <String>['COM1'];

  @override
  Future<void> connect(String portName, {required SerialConfig config}) async {
    isConnected = true;
    connectedPortName = portName;
  }

  @override
  Future<void> disconnect() async {
    isConnected = false;
    connectedPortName = null;
  }

  @override
  Future<void> sendBytes(Uint8List bytes) async {
    sent.add(Uint8List.fromList(bytes));
  }

  void emit(Uint8List bytes) => _dataController.add(bytes);
}

void main() {
  test('rcChannelsPack produces 22 byte payload', () {
    final channels = List<int>.filled(16, rcChannelCenter);
    final frame = rcChannelsPack(channels);
    expect(frame.address, crsfAddressTxModule);
    expect(frame.type, crsfTypeRcChannelsPacked);
    expect(frame.payload.length, 22);
  });

  test('CrsfSession delegates connect/send to provided SerialPort', () async {
    final serial = _FakeSerialPort();
    final session = CrsfSession(serialPort: serial);

    await session.connect('COM1');
    expect(serial.isConnected, isTrue);
    expect(serial.connectedPortName, 'COM1');

    session.sendRcChannels(List<int>.filled(16, rcChannelCenter));
    await Future<void>.delayed(Duration.zero);
    expect(serial.sent.length, 1);

    final frame = serial.sent.first;
    expect(frame.first, crsfAddressTxModule);
    expect(frame[2], crsfTypeRcChannelsPacked);

    await session.dispose();
  });
}
