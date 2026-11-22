import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/main.dart';
import 'package:tokiboshi/ui/import_dialog.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/services/store.dart';
import 'package:tokiboshi/services/desktop_settings.dart';
import 'package:tokiboshi/services/subscription_fetcher.dart';
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
  Future<AppData> load() async => data.copyWith();

  @override
  Future<void> save(AppData value) async {
    data = value.copyWith();
  }

  @override
  Future<File> writeRuntimeConfig(String configJson) async {
    runtimeConfig = configJson;
    return File('memory-config.json');
  }
}

void main() {
  testWidgets('cancel connection cleans up a core that finishes starting late',
      (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final store = MemoryStore();
    store.data.autoConnect = false;
    store.data.nodes = const [
      NodeInfo(
          name: 'cancel-fixture',
          outboundJson: '{"type":"socks","server":"127.0.0.1","server_port":1}')
    ];
    store.data.selectedIndex = 0;
    final bridge = LateStartBridge(), proxy = NoopSystemProxy();
    await t.pumpWidget(TokiboshiApp(
        bridge: bridge,
        store: store,
        systemProxy: proxy,
        allocatePort: (p, r) async => p));
    await t.pumpAndSettle();
    await t.tap(find.text('启动代理'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(bridge.enteredStart, true);
    await t.tap(find.text('取消连接'));
    bridge.gate.complete();
    await t.pumpAndSettle();
    expect(bridge.running, false);
    expect(proxy.calls.where((c) => c.enable), isEmpty);
    expect(store.data.selectedIndex, 0);
    expect(find.textContaining('已取消连接'), findsWidgets);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
      'opening app prepares the selected node without engaging the proxy',
      (tester) async {
    final store = MemoryStore();
    store.data.desktop = const DesktopSettings(autoRun: true);
    store.data.enableTun = true;
    final proxy = NoopSystemProxy();
    store.data.nodes = const [
      NodeInfo(
          name: 'saved',
          outboundJson:
              '{"type":"socks","server":"127.0.0.1","server_port":1080}')
    ];
    store.data.selectedIndex = 0;
    // 自动连接 restores the running state of a previous clean exit.
    store.data.runningAtExit = true;
    final bridge = FakeBridge();
    await tester.pumpWidget(TokiboshiApp(
      bridge: bridge,
      store: store,
      systemProxy: proxy,
      allocatePort: (port, reserved) async => port,
    ));
    await tester.pumpAndSettle();
    expect(bridge.running, isTrue);
    expect(store.runtimeConfig, isNotNull);
    expect(bridge.lastTunEnabled, isFalse);
    expect(proxy.calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
    store.data.desktop = const DesktopSettings(autoRun: false);
    final stoppedBridge = FakeBridge();
    await tester.pumpWidget(TokiboshiApp(
      bridge: stoppedBridge,
      store: store,
      systemProxy: NoopSystemProxy(),
      allocatePort: (port, reserved) async => port,
    ));
    await tester.pumpAndSettle();
    expect(stoppedBridge.running, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('first open with no nodes keeps a loopback-only core available',
      (tester) async {
    final store = MemoryStore();
    store.data.desktop = const DesktopSettings(autoRun: true, allowLan: true);
    store.data.systemProxy = true;
    store.data.enableTun = true;
    final bridge = FakeBridge();
    final proxy = NoopSystemProxy();
    await tester.pumpWidget(TokiboshiApp(
      bridge: bridge,
      store: store,
      systemProxy: proxy,
      allocatePort: (port, reserved) async => port,
    ));
    await tester.pumpAndSettle();
    final config = jsonDecode(store.runtimeConfig!) as Map<String, dynamic>;
    final inbound = (config['inbounds'] as List).single as Map;
    expect(inbound['listen'], '127.0.0.1');
    expect(inbound['type'], 'mixed');
    expect(bridge.running, isTrue);
    expect(proxy.calls, isEmpty);
    final binary = Platform.environment['SING_BOX'];
    if (binary != null) {
      await tester.runAsync(() async {
        final sandbox =
            await Directory.systemTemp.createTemp('tkb-standby-check-');
        try {
          final file = await File('${sandbox.path}/config.json')
              .writeAsString(store.runtimeConfig!);
          final result = await Process.run(binary, ['check', '-c', file.path]);
          expect(result.exitCode, 0, reason: '${result.stderr}');
        } finally {
          await sandbox.delete(recursive: true);
        }
      });
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('import, subscribe and start/stop flow', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = MemoryStore();
    final bridge = FakeBridge();
    final proxy = NoopSystemProxy();
    final fetcher = FakeFetcher({
      'https://sub.example.com/abc': 'ss://aes-256-gcm:pw@127.0.0.1:8388#a\n'
          'ss://aes-256-gcm:pw@127.0.0.1:8389#b\n',
    });

    await tester.pumpWidget(
      TokiboshiApp(
        allocatePort: (port, reserved) async => port,
        bridge: bridge,
        store: store,
        systemProxy: proxy,
        fetcher: fetcher,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('未连接'), findsWidgets);
    expect(find.text('未选择节点'), findsWidgets);

    // Import one ss link from the nodes page.
    await tester.tap(find.text('节点').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('链接'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'ss://aes-256-gcm:pw@127.0.0.1:8388#x',
    );
    await tester.tap(find.text('导入').last);
    await tester.pumpAndSettle();
    expect(find.text('x'), findsWidgets);
    expect(store.data.nodes, hasLength(1));
    expect(store.data.nodes.single.source, '');

    await tester.tap(find.text('连接').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('启动代理'));
    await tester.pumpAndSettle();
    expect(bridge.running, isTrue);
    final activeConfig = store.runtimeConfig;

    // Add a subscription by URL while the connected core keeps its config.
    await tester.tap(find.text('订阅').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加订阅'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('链接'));
    await tester.pumpAndSettle();
    final dialogFields = find.descendant(
      of: find.byType(ImportDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogFields.first, 'TestSub');
    await tester.enterText(dialogFields.last, 'https://sub.example.com/abc');
    await tester.tap(find.text('导入').last);
    await tester.pumpAndSettle();
    expect(fetcher.requested, ['https://sub.example.com/abc']);
    expect(find.text('TestSub'), findsOneWidget);
    expect(store.data.subscriptions, hasLength(1));
    expect(store.data.nodes, hasLength(3));
    expect(store.data.nodes.where((n) => n.source.isNotEmpty), hasLength(2));

    expect(bridge.running, isTrue);
    expect(store.runtimeConfig, activeConfig);

    // Back on the dashboard: inspect the current session and stop.
    await tester.tap(find.text('连接').first);
    await tester.pumpAndSettle();
    expect(find.text('代理接管中'), findsOneWidget);
    expect(bridge.running, isTrue);
    expect(store.runtimeConfig, isNotNull);
    expect(proxy.calls, [(enable: true, port: 7890)]);

    await tester.tap(find.text('停止代理'));
    await tester.pumpAndSettle();
    expect(find.text('内核待命'), findsOneWidget);
    expect(bridge.running, isTrue);
    expect(bridge.startCount, 1);
    expect(proxy.calls.last, (enable: false, port: 7890));
  });

  for (final reject in [false, true]) {
    testWidgets(
        'applying a manually imported running node ${reject ? 'restores the old core on failure' : 'switches the active core'}',
        (t) async {
      t.view.physicalSize = const Size(1280, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final store = MemoryStore();
      final bridge = RejectNextStartBridge();
      store.data.desktop =
          const DesktopSettings(autoRun: true, autoCheckUpdates: false);
      store.data.nodes = const [
        NodeInfo(
            name: '原出口',
            outboundJson:
                '{"type":"socks","server":"127.0.0.1","server_port":1080}')
      ];
      store.data.selectedIndex = 0;
      await t.pumpWidget(TokiboshiApp(
          bridge: bridge,
          store: store,
          systemProxy: NoopSystemProxy(),
          allocatePort: (p, r) async => p));
      await t.pumpAndSettle();
      await t.tap(find.text('启动代理'));
      await t.pumpAndSettle();
      final oldConfig = store.runtimeConfig;
      await t.tap(find.text('节点').first);
      await t.pumpAndSettle();
      await t.tap(find.text('导入'));
      await t.pumpAndSettle();
      await t.tap(find.text('链接'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).last,
          'ss://aes-256-gcm:pw@127.0.0.1:8388#新出口');
      await t.tap(find.text('导入').last);
      await t.pumpAndSettle();
      expect(find.text('待应用'), findsOneWidget);
      expect(store.data.selected?.name, '原出口');
      await t.tap(find.text('新出口'));
      await t.pumpAndSettle();
      expect(find.text('应用新节点'), findsOneWidget);
      bridge.reject = reject;
      await t.tap(find.text('应用并切换'));
      await t.pumpAndSettle();
      expect(bridge.running, isTrue);
      expect(store.data.nodes, hasLength(2));
      expect(store.data.selected?.name, reject ? '原出口' : '新出口');
      expect(store.runtimeConfig, reject ? oldConfig : isNot(oldConfig));
      expect(find.text('待应用'), reject ? findsOneWidget : findsNothing);
      await t.pumpWidget(const SizedBox());
    });
  }

  testWidgets('pasting a subscription URL in import adds a subscription',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = MemoryStore();
    final fetcher = FakeFetcher({
      'https://sub.example.com/abc': 'ss://aes-256-gcm:pw@127.0.0.1:8388#a\n',
    });
    await tester.pumpWidget(
      TokiboshiApp(
        allocatePort: (port, reserved) async => port,
        bridge: FakeBridge(),
        store: store,
        systemProxy: NoopSystemProxy(),
        fetcher: fetcher,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('节点').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('链接'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'https://sub.example.com/abc',
    );
    await tester.tap(find.text('导入').last);
    await tester.pumpAndSettle();
    expect(fetcher.requested, ['https://sub.example.com/abc']);
    expect(store.data.subscriptions, hasLength(1));
    expect(store.data.subscriptions.single.name, 'sub.example.com');
    expect(store.data.nodes, hasLength(1));
    expect(store.data.nodes.single.source, store.data.subscriptions.single.id);
  });

  testWidgets('subscription proxy-providers are fetched, filtered, grouped',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = MemoryStore();
    final fetcher = FakeFetcher({
      'https://hub.example.com/sub': 'PROVIDERS-DEMO',
      'https://provider.example/sub':
          'ss://aes-256-gcm:pw@127.0.0.1:8388#香港01\n'
              'ss://aes-256-gcm:pw@127.0.0.1:8389#剩余流量\n',
    });
    await tester.pumpWidget(
      TokiboshiApp(
        allocatePort: (port, reserved) async => port,
        bridge: FakeBridge(),
        store: store,
        systemProxy: NoopSystemProxy(),
        fetcher: fetcher,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('订阅').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加订阅'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('链接'));
    await tester.pumpAndSettle();
    final dialogFields = find.descendant(
      of: find.byType(ImportDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogFields.first, 'HubSub');
    await tester.enterText(dialogFields.last, 'https://hub.example.com/sub');
    await tester.tap(find.text('导入').last);
    await tester.pumpAndSettle();
    expect(
      fetcher.requested,
      ['https://hub.example.com/sub', 'https://provider.example/sub'],
    );
    // Inline node + provider node; the 剩余流量 info node is excluded
    // by the provider's exclude-filter.
    expect(store.data.nodes, hasLength(2));
    final providerNode = store.data.nodes.singleWhere((n) => n.name == '香港01');
    expect(providerNode.group, '源A');
    expect(providerNode.source, store.data.subscriptions.single.id);
    expect(store.data.nodes.any((n) => n.name.contains('流量')), isFalse);
  });
}

class LateStartBridge extends FakeBridge {
  final gate = Completer<void>();
  bool enteredStart = false;
  @override
  Future<void> startCore(
      {required String singBoxPath, required String configPath}) async {
    enteredStart = true;
    await gate.future;
    await super.startCore(singBoxPath: singBoxPath, configPath: configPath);
  }
}

class RejectNextStartBridge extends FakeBridge {
  bool reject = false;
  @override
  Future<void> startCore(
      {required String singBoxPath, required String configPath}) async {
    if (reject) {
      reject = false;
      throw StateError('test rejected candidate config');
    }
    await super.startCore(singBoxPath: singBoxPath, configPath: configPath);
  }
}
