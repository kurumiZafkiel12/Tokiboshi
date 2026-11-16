import '../bridge/core_bridge.dart';
import 'store.dart';

/// null is legacy single-profile inference. Empty is an explicit template.
/// Never infer a winner among several routing sources or bind across sources.
Subscription? activeProfile(AppData data) {
  if (data.activeProfileId == '') return null;
  final profiles =
      data.subscriptions.where((s) => s.profileJson != null).toList();
  if (data.activeProfileId != null) {
    final matches =
        profiles.where((s) => s.id == data.activeProfileId).toList();
    if (matches.length != 1)
      throw const FormatException('激活配置已删除或不再包含规则，请重新选择配置');
    return matches.single;
  }
  if (profiles.length > 1)
    throw const FormatException('多个订阅包含规则，请在工作台明确选择激活配置');
  return profiles.firstOrNull;
}

List<NodeInfo> profileNodes(AppData data) {
  final profile = activeProfile(data);
  return profile == null
      ? data.nodes
      : data.nodes.where((n) => n.source == profile.id).toList();
}
