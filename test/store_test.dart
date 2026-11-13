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
    ));
    final loaded = await store.load();
    expect(loaded.nodes, hasLength(1));
    expect(loaded.nodes.first.name, 'n1');
    expect(loaded.selected?.name, 'n1');
    expect(loaded.mixedPort, 1080);
    expect(loaded.singBoxPath, r'C:\tools\sing-box.exe');
  });

  test('missing file loads defaults', () async {
    final store = Store(File('/nonexistent-dir-xyz/data.json'));
    final loaded = await store.load();
    expect(loaded.nodes, isEmpty);
    expect(loaded.mixedPort, 7890);
  });
}
