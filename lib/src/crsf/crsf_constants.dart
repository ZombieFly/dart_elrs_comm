/// CRSF 广播地址。
const int crsfAddressBroadcast = 0x00;

/// CRSF 无线电发射机地址。
const int crsfAddressRadioTransmitter = 0xEA;

/// CRSF TX 模块地址。
const int crsfAddressTxModule = 0xEE;

/// CRSF 手持（Lua）地址。
const int crsfAddressHandsetLua = 0xEF;

/// CRSF 帧类型：设备 Ping。
const int crsfTypeDevicePing = 0x28;

/// CRSF 帧类型：RC 通道打包数据。
const int crsfTypeRcChannelsPacked = 0x16;

/// CRSF 帧类型：设备信息。
const int crsfTypeDeviceInfo = 0x29;

/// CRSF 帧类型：读取参数。
const int crsfTypeParameterRead = 0x2C;

/// CRSF 帧类型：写入参数。
const int crsfTypeParameterWrite = 0x2D;

/// CRSF 帧类型：参数信息。
const int crsfTypeParameterInfo = 0x2B;

/// CRSF 帧类型：ELRS 状态。
const int crsfTypeElrsStatus = 0x2E;

/// ELRS 序列号魔数 `ELRS`。
const int crsfElrsSerial = 0x454C5253;
