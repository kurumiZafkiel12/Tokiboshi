import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/services/proxy_chain.dart';
import 'package:tokiboshi/services/node_tags.dart';

void main() {
  const nodes = [
    NodeInfo(name: 'a', outboundJson: '{"type":"socks","server":"127.0.0.1","server_port":1080,"tag":"a"}'),
    NodeInfo(name: 'b', outboundJson: '{"type":"socks","server":"127.0.0.1","server_port":1081,"tag":"b"}'),
  ];
  test('chain is an independent exit through an entry with unique names', () {
    final first = createProxyChain(nodes, 0, 1, 'chain');
    final second = createProxyChain([...nodes, ...first], 0, 1, 'chain');
    final exit = jsonDecode(first.last.outboundJson) as Map<String, dynamic>;
    expect(exit['detour'], first.first.name);
    expect(exit['server_port'], 1081);
    expect(exit.containsKey('tag'), isFalse);
    expect(second.first.name, isNot(first.first.name));
    expect(nodes.last.outboundJson, isNot(contains('detour')));
    expect(() => createProxyChain(nodes, 0, 0, ''), throwsFormatException);
    expect(() => createProxyChain(first, 1, 0, ''), throwsFormatException);
  });
  test('Clash selection uses deterministic unique tags', () {
    expect(assignNodeTags(['proxy', 'dup', 'dup', '']), ['proxy-2', 'dup', 'dup-2', 'node-4']);
  });
}
