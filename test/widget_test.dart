import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/main.dart';
import 'package:tokiboshi/services/store.dart';
import 'package:tokiboshi/services/system_proxy.dart';

import 'fake_bridge.dart';

/// Store that never touches the disk, so widget tests stay inside the
/// fake-async zone (real file IO would never complete there).
class MemoryStore extends Store {
  MemoryStore() : super(File('memory-data.json'));

  AppData data = AppData();
  String? runtimeConfig;

  @override
  Directory get dir => Directory.systemTemp;

  @override
  Future<AppData> load() async => data;

  @override
  Future<void> save(AppData value) async {
    data = value;
  }

  @override
  Future<File> writeRuntimeConfig(String configJson) async {
    runtimeConfig = configJson;
    return File('memory-config.json');
  }
}

void main() {
  testWidgets('import, select and start/stop flow', (tester) async {
    final store = MemoryStore();
    final bridge = FakeBridge();
    final proxy = NoopSystemProxy();

    await tester.pumpWidget(
      TokiboshiApp(bridge: bridge, store: store, systemProxy: proxy),
    );
    await tester.pumpAndSettle();
    expect(find.text('sing-box 已停止'), findsOneWidget);
    expect(find.text('还没有节点，点右上角图标导入'), findsOneWidget);

    // Import one ss link through the dialog.
    await tester.tap(find.byTooltip('导入节点 / 订阅'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'ss://aes-256-gcm:pw@127.0.0.1:8388#x',
    );
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(find.text('FakeSS'), findsWidgets); // list tile + status subtitle
    expect(store.data.nodes, hasLength(1));

    // Start and stop.
    await tester.tap(find.text('启动'));
    await tester.pumpAndSettle();
    expect(find.text('sing-box 运行中'), findsOneWidget);
    expect(bridge.running, isTrue);
    expect(store.runtimeConfig, isNotNull);
    expect(proxy.calls, [(enable: true, port: 7890)]);

    await tester.tap(find.text('停止'));
    await tester.pumpAndSettle();
    expect(find.text('sing-box 已停止'), findsOneWidget);
    expect(bridge.running, isFalse);
    expect(proxy.calls.last, (enable: false, port: 7890));
  });
}
