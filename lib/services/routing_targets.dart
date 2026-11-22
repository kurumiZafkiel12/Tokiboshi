import 'dart:convert';
import '../bridge/core_bridge.dart';
import 'node_tags.dart';

String routeNodeReference(NodeInfo node) =>
    'node:' +
    base64Url.encode(utf8.encode(jsonEncode([
      node.source,
      node.group,
      node.name,
      node.protocol,
      node.server,
      node.serverPort,
    ])));

class RoutingTargets {
  RoutingTargets(List<NodeInfo> nodes) {
    final tags = assignNodeTags(nodes.map((node) => node.name));
    final byReference = <String, List<int>>{};
    final byName = <String, List<int>>{};
    for (var i = 0; i < nodes.length; i++) {
      (byReference[routeNodeReference(nodes[i])] ??= []).add(i);
      (byName[nodes[i].name] ??= []).add(i);
    }
    for (final entry in byReference.entries) {
      if (entry.value.length == 1) {
        resolved[entry.key] = tags[entry.value.single];
        available.add(nodes[entry.value.single]);
      }
    }
    for (final entry in byName.entries) {
      if (!const {'proxy', 'direct', 'reject'}.contains(entry.key)) {
        resolved[entry.key] =
            entry.value.length == 1 ? tags[entry.value.single] : '';
      }
    }
  }

  final resolved = <String, String>{};
  final available = <NodeInfo>[];
}

/// Apply a generated/configured tag or fail closed if the saved target disappeared.
void applyRouteTarget(Map<dynamic, dynamic> rule, String target,
    Map<String, String> tags, Set<String> outbounds) {
  final resolved = tags[target] ?? target;
  if (target == 'reject' ||
      (outbounds.isNotEmpty && !outbounds.contains(resolved)) ||
      (target.startsWith('node:') && !tags.containsKey(target))) {
    rule.remove('outbound');
    rule['action'] = 'reject';
  } else {
    rule['action'] = 'route';
    rule['outbound'] = resolved;
  }
}
