/// ELRS 字段类型。
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

/// ELRS 设置字段。
///
/// 注意：为了兼容历史实现，部分字段当前为可变状态。建议通过 [elrsFields] 的
/// 整体更新来替换实例，而不是直接修改内部字段。
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
