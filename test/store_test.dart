import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/services/store.dart';

void main() {
  test('store round-trips nodes and settings', () async {
    final tmp = await Directory.systemTemp.createTemp('tokiboshi-store');
    addTearDown(() => tmp.delete(recursive: true));
    final store = Store(File('${tmp.path}/sub/data.json'));
    await store.save(AppData(
      nodes: const [NodeInfo(name: 'n1', outboundJson: '{"type":"direct"}')],
      selectedIndex: 0,
      mixedPort: 1080,
      singBoxPath: 'C:\\tools\\sing-box.exe',
      autoConnect: false,
    ));
    final loaded = await store.load();
    expect(loaded.nodes, hasLength(1));
    expect(loaded.nodes.first.name, 'n1');
    expect(loaded.selected?.name, 'n1');
    expect(loaded.mixedPort, 1080);
    expect(loaded.autoConnect, isFalse);
    expect(loaded.singBoxPath, r'C:\tools\sing-box.exe');
  });

  test('missing file loads defaults', () async {
    final store = Store(File('/nonexistent-dir-xyz/data.json'));
    final loaded = await store.load();
    expect(loaded.nodes, isEmpty);
    expect(loaded.mixedPort, 7890);
    expect(loaded.autoConnect, isTrue);
  });

  test('store round-trips subscriptions and node sources', () async {
    final tmp = await Directory.systemTemp.createTemp('tokiboshi-store2');
    addTearDown(() => tmp.delete(recursive: true));
    final store = Store(File('${tmp.path}/data.json'));
    await store.save(AppData(
      nodes: const [
        NodeInfo(name: 'sn', outboundJson: '{"type":"ss"}', source: 'sub-1'),
      ],
      subscriptions: const [
        Subscription(
          id: 'sub-1',
          name: 'MySub',
          url: 'https://example.com/sub',
          updatedAt: '2026-11-14T00:00:00.000',
        ),
      ],
      systemProxy: false,
    ));
    final loaded = await store.load();
    expect(loaded.nodes.single.source, 'sub-1');
    expect(loaded.subscriptions.single.name, 'MySub');
    expect(loaded.subscriptions.single.updatedAt, isNotNull);
    expect(loaded.systemProxy, isFalse);
  });

  test('v0.1 format loads with defaults', () async {
    final tmp = await Directory.systemTemp.createTemp('tokiboshi-store3');
    addTearDown(() => tmp.delete(recursive: true));
    final file = File('${tmp.path}/data.json');
    await file.writeAsString(
      '{"nodes":[{"name":"old","outboundJson":"{\\"type\\":\\"direct\\"}"}],'
      '"selectedIndex":0,"mixedPort":7890,"singBoxPath":""}',
    );
    final loaded = await Store(file).load();
    expect(loaded.nodes.single.name, 'old');
    expect(loaded.nodes.single.source, '');
    expect(loaded.subscriptions, isEmpty);
    expect(loaded.systemProxy, isTrue);
  });
}
