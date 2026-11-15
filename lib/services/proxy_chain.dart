import 'dart:convert';
import '../bridge/core_bridge.dart';

/// Independent copies avoid mutating a subscription or its existing routes.
List<NodeInfo> createProxyChain(List<NodeInfo> nodes, int entry, int exit, String name) {
  if (entry == exit) throw const FormatException('前置节点和落地节点不能相同');
  if (entry < 0 || exit < 0 || entry >= nodes.length || exit >= nodes.length) {
    throw const FormatException('请选择有效节点');
  }
  if (nodes[entry].isPolicy || nodes[exit].isPolicy) {
    throw const FormatException('链式代理请选择具体节点，而不是策略组');
  }
  final entryOb = jsonDecode(nodes[entry].outboundJson) as Map<String, dynamic>;
  final exitOb = jsonDecode(nodes[exit].outboundJson) as Map<String, dynamic>;
  if (entryOb.containsKey('detour') || exitOb.containsKey('detour')) {
    throw const FormatException('请选择两个未设置链式代理的节点，避免重复链路');
  }
  final used = nodes.map((n) => n.name).toSet();
  String unique(String base) {
    var candidate = base;
    var i = 2;
    while (used.contains(candidate)) { candidate = '$base-$i'; i++; }
    used.add(candidate);
    return candidate;
  }
  final base = name.trim().isEmpty ? '链式代理' : name.trim();
  final entryName = unique('$base · 前置');
  final exitName = unique('$base · 落地');
  entryOb.remove('tag');
  exitOb.remove('tag');
  exitOb['detour'] = entryName;
  return [
    NodeInfo(name: entryName, outboundJson: jsonEncode(entryOb), group: base),
    NodeInfo(name: exitName, outboundJson: jsonEncode(exitOb), group: base),
  ];
}
