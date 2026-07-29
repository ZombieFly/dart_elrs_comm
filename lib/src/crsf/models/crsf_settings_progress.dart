/// 设置加载进度。
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
