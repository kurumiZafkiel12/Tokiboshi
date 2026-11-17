import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/main.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/services/desktop_settings.dart';
import 'package:tokiboshi/services/system_proxy.dart';
import 'package:tokiboshi/ui/preferences.dart';
import 'fake_bridge.dart';
import 'widget_test.dart' show MemoryStore;

void main() {
  Future<(MemoryStore, FakeBridge)> mount(WidgetTester t,
      {required DesktopSettings settings,
      Future<Set<String>> Function()? probe}) async {
    t.view.physicalSize = const Size(1280, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final store = MemoryStore();
    store.data.autoConnect = false;
    store.data.desktop = settings;
    store.data.ui = const UiPreferences(motion: 'reduced');
    store.data.nodes = const [
      NodeInfo(
          name: 'fixture',
          outboundJson: '{"type":"socks","server":"127.0.0.1","server_port":1}')
    ];
    store.data.selectedIndex = 0;
    final bridge = FakeBridge();
    await t.pumpWidget(TokiboshiApp(
        bridge: bridge,
        store: store,
        systemProxy: NoopSystemProxy(),
        allocatePort: (p, r) async => p,
        processProbe: probe));
    await t.pumpAndSettle();
    return (store, bridge);
  }

  testWidgets(
      'always-connect starts selected node even when prior-state restore is off',
      (t) async {
    final (_, bridge) =
        await mount(t, settings: const DesktopSettings(autoRun: true));
    expect(bridge.running, true);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('on-demand owns only its own session and respects manual stop',
      (t) async {
    var processes = <String>{'example'};
    final (_, bridge) = await mount(t,
        settings:
            const DesktopSettings(onDemand: true, processes: ['example.exe']),
        probe: () async => processes);
    expect(bridge.running, true);
    processes = {};
    await t.pump(const Duration(seconds: 8));
    await t.pumpAndSettle();
    expect(bridge.running, false);
    processes = {'example'};
    await t.pump(const Duration(seconds: 8));
    await t.pumpAndSettle();
    expect(bridge.running, true);
    await t.tap(find.text('停止代理'));
    await t.pumpAndSettle();
    expect(bridge.running, false);
    await t.pump(const Duration(seconds: 16));
    await t.pumpAndSettle();
    expect(bridge.running, false);
    processes = {};
    await t.pump(const Duration(seconds: 8));
    await t.pumpAndSettle();
    processes = {'example'};
    await t.pump(const Duration(seconds: 8));
    await t.pumpAndSettle();
    expect(bridge.running, true);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('on-demand never stops a manually started session', (t) async {
    final (_, bridge) = await mount(t,
        settings:
            const DesktopSettings(onDemand: true, processes: ['example.exe']),
        probe: () async => <String>{});
    expect(bridge.running, false);
    await t.tap(find.text('启动代理'));
    await t.pumpAndSettle();
    expect(bridge.running, true);
    await t.pump(const Duration(seconds: 16));
    await t.pumpAndSettle();
    expect(bridge.running, true);
    await t.pumpWidget(const SizedBox());
  });
}
