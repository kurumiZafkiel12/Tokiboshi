import 'dart:convert';

import 'client_preferences.dart';
import 'store.dart';

const backupMaxBytes = 64 * 1024 * 1024;
String encodeBackup(AppData data) {
  final portable = Store.encodeData(data)
    ..remove('clashApiSecret')
    ..remove('singBoxPath');
  final text = const JsonEncoder.withIndent('  ').convert({
    'format': 'tokiboshi-backup',
    'version': 1,
    'createdAt': DateTime.now().toUtc().toIso8601String(),
    'data': portable
  });
  if (utf8.encode(text).length > backupMaxBytes)
    throw const FormatException('配置超过 64MiB，无法导出单文件备份');
  return text;
}

AppData decodeBackup(String text, AppData current) {
  if (utf8.encode(text).length > backupMaxBytes)
    throw const FormatException('备份文件超过 64MiB');
  final root = jsonDecode(text);
  if (root is! Map ||
      root['format'] != 'tokiboshi-backup' ||
      root['version'] != 1 ||
      root['data'] is! Map) throw const FormatException('不是受支持的 Tokiboshi 备份');
  final map = root['data'] as Map;
  final restored = Store.decodeData(jsonEncode(map));
  if (restored == null) throw const FormatException('备份内容损坏，原配置保留');
  final ids = restored.subscriptions.map((s) => s.id).toSet();
  if (ids.length != restored.subscriptions.length ||
      ids.contains('') ||
      restored.nodes.length > 50000 ||
      restored.selectedIndex < -1 ||
      restored.selectedIndex >= restored.nodes.length ||
      restored.mixedPort < 1 ||
      restored.mixedPort > 65535 ||
      restored.clashApiPort < 1 ||
      restored.clashApiPort > 65535 ||
      restored.mixedPort == restored.clashApiPort)
    throw const FormatException('备份包含无效的来源、选择或端口');
  for (final node in restored.nodes) {
    if (jsonDecode(node.outboundJson) is! Map ||
        (node.source.isNotEmpty && !ids.contains(node.source)))
      throw const FormatException('备份中的节点或来源引用无效');
  }
  for (final source in restored.subscriptions) {
    if (source.profileJson != null && jsonDecode(source.profileJson!) is! Map)
      throw const FormatException('备份中的完整配置无效');
  }
  if (map['client'] != null)
    restored.client = ClientPreferences.fromJson(map['client'], strict: true);
  if (restored.activeProfileId?.isNotEmpty == true &&
      !ids.contains(restored.activeProfileId))
    throw const FormatException('备份中的激活来源不存在');
  // Device-local executable paths, controller identity and startup registration stay local.
  restored.singBoxPath = current.singBoxPath;
  restored.clashApiSecret = current.clashApiSecret.isEmpty
      ? generateClashSecret()
      : current.clashApiSecret;
  restored.desktop = restored.desktop.copyWith(
    launchAtLogin: current.desktop.launchAtLogin,
    autoRun: false,
    onDemand: false,
  );
  restored.resumeConnect = false;
  restored.runningAtExit = false;
  restored.cleanExit = false;
  return restored;
}
