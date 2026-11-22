import 'dart:convert';

import '../bridge/core_bridge.dart';
import 'store.dart';
import 'subscription_resolver.dart' show isIndependentSubscriptionNode;

/// Convert installed data and restored backups to the nodes-only model.
/// Keep source identities and restore a selected node by its original row.
bool migrateSubscriptionNodes(AppData data) {
  final before = data.nodes;
  final selected = data.selected;
  final manualEntries = {
    for (final node in before)
      if (node.source.isEmpty &&
          node.group.isNotEmpty &&
          node.name.startsWith('${node.group} · 前置') &&
          isIndependentSubscriptionNode(node))
        (node.group, node.name),
  };
  final retained = [
    for (final node in before)
      if (isIndependentSubscriptionNode(node) ||
          (node.source.isEmpty &&
              node.group.isNotEmpty &&
              node.name.startsWith('${node.group} · 落地') &&
              manualEntries.contains((node.group, node.outbound['detour']))))
        node,
  ];
  final sourcesChanged = data.subscriptions
      .any((source) => source.profileJson != null || !source.nodesOnly);
  if (retained.length == before.length &&
      !sourcesChanged &&
      data.activeProfileId?.isNotEmpty != true) return false;

  data.nodes = retained;
  data.activeProfileId = '';
  final selectedIndex =
      retained.indexWhere((node) => identical(node, selected));
  data.selectedIndex = selectedIndex >= 0
      ? selectedIndex
      : selected != null && retained.isNotEmpty
          ? 0
          : -1;
  if (sourcesChanged) {
    data.subscriptions = [
      for (final source in data.subscriptions)
        Subscription.fromJson({
          ...source.toJson(),
          'profileJson': null,
          'profileState': 'nodes-only',
          'nodesOnly': true,
          if (source.profileJson != null) 'lastReport': '已迁移为仅节点。沿用此来源的实际节点。',
        }),
    ];
  }
  return true;
}

/// Give local chain references an internal alias independent of display names.
List<NodeSpec> buildNodesOnlySpecs(List<NodeInfo> nodes) {
  final names = nodes.map((node) => node.name).toSet();
  final manualEntries = <(String, String), int>{
    for (final (index, node) in nodes.indexed)
      if (node.source.isEmpty && node.group.isNotEmpty)
        (node.group, node.name): index,
  };
  final aliases = <int, String>{};
  final outbounds = [
    for (final node in nodes)
      Map<String, dynamic>.of(node.outbound)..remove('tag'),
  ];
  for (final (index, node) in nodes.indexed) {
    final detour = outbounds[index]['detour'];
    if (node.source.isNotEmpty || detour is! String || detour.isEmpty) continue;
    final entry = manualEntries[(node.group, detour)];
    if (entry == null) continue;
    final alias = aliases.putIfAbsent(entry, () {
      var suffix = entry;
      while (!names.add('__tokiboshi_chain_$suffix')) {
        suffix++;
      }
      return '__tokiboshi_chain_$suffix';
    });
    outbounds[entry]['tag'] = alias;
    outbounds[index]['detour'] = alias;
  }
  return [
    for (final (index, node) in nodes.indexed)
      NodeSpec(name: node.name, outboundJson: jsonEncode(outbounds[index])),
  ];
}
