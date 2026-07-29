# elrs_comm

A Dart package for CRSF/ELRS serial communication with pluggable serial port backends.

This package provides a platform-agnostic implementation of the CRSF protocol used by ExpressLRS (ELRS). It does **not** include a concrete serial port driver. Instead, you provide your own `SerialPort` implementation, making it usable on desktop, mobile, or embedded targets.

## Features

- Platform-independent CRSF frame parsing and building
- RC channels packing (`rcChannelsPack`) for 16 channels × 11 bit
- Device discovery, parameter read/write, and ELRS status parsing
- Command execution with confirm/cancel lifecycle
- Auto-polling and RC channel streaming
- Pluggable `SerialPort` interface for custom serial backends

## Getting started

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  elrs_comm:
    path: ../elrs_comm # or a published version once available
```

Then implement `SerialPort` for your platform. For example:

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:elrs_comm/elrs_comm.dart';

class MySerialPort implements SerialPort {
  final _dataController = StreamController<Uint8List>.broadcast();
  final _deviceLostController = StreamController<void>.broadcast();

  @override
  bool isConnected = false;

  @override
  String? connectedPortName;

  @override
  Stream<Uint8List> get onData => _dataController.stream;

  @override
  Stream<void> get onDeviceLost => _deviceLostController.stream;

  @override
  Future<List<String>> listAllPorts() async => ['COM1', 'COM2'];

  @override
  Future<void> connect(String portName, {required SerialConfig config}) async {
    // open your platform serial port here
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
    // write bytes to your platform serial port
  }
}
```

## Usage

```dart
import 'package:elrs_comm/elrs_comm.dart';

void main() async {
  final session = CrsfSession(serialPort: MySerialPort());

  await session.connect('COM3');
  session.discoverDevices();

  session.onDeviceInfo.listen((info) {
    print('Device: ${info.name} (${info.fieldCount} fields)');
  });

  // Stream RC channels at 50 Hz
  session.setRcChannels(List<int>.filled(16, rcChannelCenter));
  session.startRcSending();

  // Load Device settings (Default value is TX 0xEE)
  final fields = await session.loadDeviceSettings();
  print('Loaded ${fields.length} fields');

  await session.dispose();
}
```

## API overview

| Class / Function | Description |
| ---------------- | ----------- |
| `SerialPort`     | Interface you implement to provide serial I/O |
| `SerialConfig`   | Baud rate, data bits, stop bits, parity, flow control |
| `CrsfSession`    | Main entry point for CRSF/ELRS communication |
| `rcChannelsPack` | Pack 16 RC channels into a CRSF RC_CHANNELS_PACKED frame |
| `ElrsField`      | Represents a single ELRS setting field |
| `ElrsCommandState` | Represents an active command dialog state |

## Additional information

For more details on the CRSF protocol, see the [ExpressLRS documentation](https://www.expresslrs.org/).

Contributions and issue reports are welcome.
