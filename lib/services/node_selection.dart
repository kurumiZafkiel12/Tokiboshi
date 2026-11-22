import 'dart:convert';
import '../bridge/core_bridge.dart';

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

String _content(NodeInfo node) {
  final map = Map<String, dynamic>.from(jsonDecode(node.outboundJson) as Map)
    ..remove('tag');
  return jsonEncode(_canonical(map));
}

String _endpoint(NodeInfo node) {
  final map = Map<String, dynamic>.from(jsonDecode(node.outboundJson) as Map);
  return jsonEncode(_canonical({
    'source': node.source,
    'group': node.group,
    'type': map['type'],
    'server': node.server.toLowerCase(),
    'port': node.serverPort,
    'transport': map['transport'],
    'tls': map['tls']
  }));
}

/// Restore within the same source. Never resolve ambiguous same-name nodes by first match.
int restoredNodeIndex(
    NodeInfo previous, List<NodeInfo> oldSource, List<NodeInfo> fresh) {
  final candidates =
      fresh.indexed.where((e) => e.$2.source == previous.source).toList();
  if (previous.isPolicy) {
    final same = candidates
        .where((e) => e.$2.isPolicy && e.$2.name == previous.name)
        .toList();
    return same.length == 1 ? same.single.$1 : -1;
  }
  final content = _content(previous);
  final exact = candidates
      .where((e) => !e.$2.isPolicy && _content(e.$2) == content)
      .toList();
  if (exact.length == 1) return exact.single.$1;
  if (exact.isNotEmpty) return -1;
  final endpoint = _endpoint(previous);
  final located = candidates
      .where((e) => !e.$2.isPolicy && _endpoint(e.$2) == endpoint)
      .toList();
  final old =
      oldSource.where((n) => !n.isPolicy && _endpoint(n) == endpoint).length;
  return located.length == 1 && old == 1 ? located.single.$1 : -1;
}

/// Pair identical entries first, then compare unambiguous endpoint changes.
({int added, int changed, int removed}) subscriptionChanges(
    List<NodeInfo> old, List<NodeInfo> fresh) {
  final byContent = <(String, String, String), List<NodeInfo>>{};
  for (final n in old) {
    (byContent[(n.name, n.group, _content(n))] ??= []).add(n);
  }
  final added = <String, int>{}, removed = <String, int>{};
  for (final n in fresh) {
    final same = byContent[(n.name, n.group, _content(n))];
    if (same != null && same.isNotEmpty) {
      same.removeLast();
      continue;
    }
    added.update(_endpoint(n), (v) => v + 1, ifAbsent: () => 1);
  }
  for (final n in byContent.values.expand((v) => v)) {
    removed.update(_endpoint(n), (v) => v + 1, ifAbsent: () => 1);
  }
  final changed =
      added.keys.where((k) => added[k] == 1 && removed[k] == 1).length;
  return (
    added: added.values.fold<int>(0, (a, b) => a + b) - changed,
    changed: changed,
    removed: removed.values.fold<int>(0, (a, b) => a + b) - changed
  );
}
