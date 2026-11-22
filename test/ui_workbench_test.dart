import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/main.dart';
import 'package:tokiboshi/pages/dashboard_page.dart';
import 'package:tokiboshi/pages/nodes_page.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/services/store.dart';
import 'package:tokiboshi/services/desktop_settings.dart';
import 'package:tokiboshi/services/system_proxy.dart';
import 'package:tokiboshi/ui/preferences.dart';
import 'package:tokiboshi/ui/node_widgets.dart';
import 'package:tokiboshi/ui/import_dialog.dart';
import 'package:tokiboshi/ui/design.dart';
import 'package:tokiboshi/ui/runtime.dart';
import 'fake_bridge.dart';
import 'widget_test.dart' show MemoryStore;

void main() {
  final capture = Platform.environment['TOKIBOSHI_UI_CAPTURE'];
  setUpAll(() async {
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
    await (FontLoader('packages/lucide_icons_flutter/Lucide')
          ..addFont(rootBundle
              .load('packages/lucide_icons_flutter/assets/lucide.ttf')))
        .load();
    final font = Platform.environment['TOKIBOSHI_UI_FONT'];
    if (font != null) {
      final bytes = await File(font).readAsBytes();
      for (final family in [
        'Segoe UI',
        'Cascadia Code',
        'Consolas',
        'Noto Sans CJK SC'
      ]) {
        await (FontLoader(family)
              ..addFont(Future.value(ByteData.sublistView(bytes))))
            .load();
      }
    }
  });
  Future<MemoryStore> mount(WidgetTester t,
      {Size size = const Size(1440, 900),
      bool light = false,
      String motion = 'reduced',
      double dpr = 1,
      List<NodeInfo> extraNodes = const [],
      bool twoProfiles = false,
      MemoryStore? withStore}) async {
    t.view.physicalSize = size * dpr;
    t.view.devicePixelRatio = dpr;
    addTearDown(t.view.reset);
    final store = withStore ?? MemoryStore();
    store.data.autoConnect = false;
    store.data.ui = UiPreferences(light: light, motion: motion);
    store.data.nodes = const [
      NodeInfo(
          name: '东京 · Sakura 01',
          outboundJson:
              '{"type":"vless","server":"jp.example.test","server_port":443}',
          source: 's1'),
      NodeInfo(
          name: '香港 · Victoria 02',
          outboundJson:
              '{"type":"hysteria2","server":"hk.example.test","server_port":443}',
          source: 's1',
          group: '亚洲'),
      NodeInfo(
          name: 'Singapore · Orbit',
          outboundJson:
              '{"type":"trojan","server":"sg.example.test","server_port":443}',
          source: 's2'),
      NodeInfo(
          name: '本地 · SOCKS',
          outboundJson:
              '{"type":"socks","server":"127.0.0.1","server_port":1080}'),
    ];
    store.data.selectedIndex = 0;
    store.data.nodes = [...store.data.nodes, ...extraNodes];
    store.data.subscriptions = const [
      Subscription(
          id: 's1',
          name: '星海 · 主订阅',
          url: 'https://subscription.example.test/?token=fixture-secret',
          lastReport: '示例识别诊断：4 个节点。',
          updatedAt: '2026-11-16T12:00:00Z',
          profileJson:
              '{"route_rules":[{"domain_suffix":["example.test"],"outbound":"DIRECT"}],"rule_sets":[],"final_outbound":"proxy","unsupported":[]}'),
      Subscription(
          id: 's2', name: 'Orbit · 节点源', url: 'https://orbit.example.test/sub'),
    ];
    if (twoProfiles) {
      store.data.subscriptions = [
        store.data.subscriptions.first,
        store.data.subscriptions.last.copyWith(
            profileJson:
                '{"route_rules":[],"rule_sets":[],"final_outbound":"Singapore · Orbit","unsupported":[]}')
      ];
    }
    await t.pumpWidget(RepaintBoundary(
        key: const ValueKey('capture'),
        child: TokiboshiApp(
            bridge: FakeBridge(),
            store: store,
            systemProxy: NoopSystemProxy(),
            allocatePort: (p, r) async => p)));
    await t.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await t.pumpAndSettle();
    return store;
  }

  Future<void> screenshot(WidgetTester t, String name) async {
    if (capture == null) return;
    await t.runAsync(() async {
      final boundary = t.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('capture')));
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(capture).create(recursive: true);
      await File('$capture/$name.png').writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final size in [const Size(1440, 900), const Size(800, 600)]) {
    testWidgets('software routing selects independent targets at ${size.width}',
        (t) async {
      final fixture = MemoryStore();
      fixture.data.desktop =
          const DesktopSettings(autoRun: true, autoCheckUpdates: false);
      final store = await mount(t,
          size: size, light: size.width < 1040, withStore: fixture);
      expect(find.text('内核待命'), findsOneWidget);
      await screenshot(t, 'dashboard-v013-${size.width.toInt()}');
      await t.tap(size.width < 1040
          ? find.byTooltip('分流规则').first
          : find.text('分流规则').first);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await screenshot(t, 'routing-v013-${size.width.toInt()}');
      await t.tap(find.text('通讯'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('微信'));
      await t.tap(find.text('微信'));
      await t.pumpAndSettle();
      await screenshot(t, 'route-picker-v013-${size.width.toInt()}');
      await t.tap(find.text('直连').last);
      await t.pumpAndSettle();
      final rules =
          store.data.client.rules.where((r) => r.kind == 'process_name');
      expect(rules.map((r) => r.value),
          ['WeChat.exe', 'Weixin.exe', 'WeChatAppEx.exe']);
      expect(rules.map((r) => r.target).toSet(), {'direct'});
      expect(find.text('待应用 · 直连'), findsOneWidget);
      await screenshot(t, 'routing-pending-${size.width.toInt()}');
      final apply = find.text('应用配置 (3)');
      await t.ensureVisible(apply);
      await t.tap(apply);
      await t.pumpAndSettle();
      expect(find.text('已应用 3 条进程规则变更'), findsOneWidget);
      expect(find.text('待应用 · 直连'), findsNothing);
      expect(find.text('当前 · 直连'), findsOneWidget);
      await screenshot(t, 'routing-applied-${size.width.toInt()}');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  }

  for (final size in [const Size(1440, 900), const Size(800, 600)]) {
    testWidgets(
        'reissue import and general settings surfaces fit ${size.width}',
        (t) async {
      await mount(t, size: size);
      await t.tap(size.width < 1040
          ? find.byTooltip('节点').first
          : find.text('节点').first);
      await t.pumpAndSettle();
      for (final method in ['二维码', '文件', '链接', '剪贴板', '自定义']) {
        await t.tap(find.text('导入'));
        await t.pumpAndSettle();
        await t.tap(find.text(method == '剪贴板' ? '剪贴板 / 文本' : method));
        await t.pumpAndSettle();
        expect(find.byType(ImportDialog), findsOneWidget);
        expect(t.takeException(), isNull);
        await screenshot(
            t,
            'import-${{
              '二维码': 'qr',
              '文件': 'file',
              '链接': 'link',
              '剪贴板': 'clipboard',
              '自定义': 'custom'
            }[method]}-${size.width.toInt()}');
        await t.tap(find.text('取消').last);
        await t.pumpAndSettle();
      }
      await t.tap(size.width < 1040
          ? find.byTooltip('设置').first
          : find.text('设置').first);
      await t.pumpAndSettle();
      for (final section in ['启动与后台', '请求与更新', '入站与控制']) {
        await t.ensureVisible(find.text(section));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await screenshot(
            t,
            'general-${{
              '启动与后台': 'startup',
              '请求与更新': 'requests',
              '入站与控制': 'inbound'
            }[section]}-${size.width.toInt()}');
      }
      await t.pumpWidget(const SizedBox());
    });
  }
  for (final size in [
    const Size(1440, 900),
    const Size(1280, 800),
    const Size(1024, 768),
    const Size(800, 600)
  ]) {
    testWidgets('all workbench pages fit ${size.width}x${size.height}',
        (t) async {
      await mount(t, size: size);
      expect(t.takeException(), isNull);
      await screenshot(t, 'dashboard-${size.width.toInt()}');
      for (final name in ['节点', '订阅', '分流规则', '请求', '运行日志', '设置']) {
        await t.tap(size.width < 1040
            ? find.byTooltip(name).first
            : find.text(name).first);
        await t.pumpAndSettle();
        expect(t.takeException(), isNull, reason: name);
        await screenshot(
            t,
            '${{
              '节点': 'nodes',
              '订阅': 'sources',
              '分流规则': 'rules',
              '请求': 'connections',
              '运行日志': 'logs',
              '设置': 'settings'
            }[name]}-${size.width.toInt()}');
      }
      await t.pumpWidget(const SizedBox());
    });
  }
  testWidgets('0.1.3 compact workbench preserves primary action at 125% text',
      (t) async {
    t.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await mount(t, size: const Size(800, 600), light: true);
    expect(find.text('连接工作台'), findsOneWidget);
    final start = find.text('启动代理');
    expect(t.getRect(start).bottom, lessThan(600));
    await screenshot(t, 'dashboard-800-light-125percent');
    await t.tap(start);
    await t.pumpAndSettle();
    expect(find.text('停止代理'), findsOneWidget);
    expect(t.takeException(), isNull);
    await screenshot(t, 'dashboard-800-running-light-125percent');
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('sidebar stays within its animated width while expanding',
      (t) async {
    t.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures();
    addTearDown(() => t.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true));
    await mount(t, motion: 'standard');
    await t.tap(find.byTooltip('收起侧栏'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('展开侧栏'));
    await t.pump();
    expect(t.takeException(), isNull);
    await t.pumpAndSettle();
    t.view.physicalSize = const Size(800, 600);
    await t.pump();
    await t.pump(const Duration(milliseconds: 80));
    t.view.physicalSize = const Size(1440, 900);
    await t.pump();
    expect(t.takeException(), isNull);
    await t.pumpAndSettle();
    expect(find.text('Tokiboshi'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('compact workbench navigation at high DPI and 150% text',
      (t) async {
    t.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    final fixture = MemoryStore();
    fixture.data.desktop =
        const DesktopSettings(autoRun: true, autoCheckUpdates: false);
    await mount(t, size: const Size(800, 600), dpr: 1.5, withStore: fixture);
    expect(t.takeException(), isNull, reason: '连接');
    await t.tap(find.byTooltip('查找节点 (Ctrl+K)'));
    await t.pumpAndSettle();
    expect(find.byType(NodePicker), findsOneWidget);
    Navigator.of(t.element(find.byType(NodePicker))).pop();
    await t.pumpAndSettle();
    for (final name in ['节点', '订阅', '分流规则', '请求', '工具箱', '运行日志', '面板', '设置']) {
      final route = find.byTooltip(name).first;
      await t.ensureVisible(route);
      await t.tap(route);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: name);
      await screenshot(t, 'dpi-150-$name');
      if (name == '节点') {
        final nodes = find.byKey(const PageStorageKey('nodes-scroll'));
        final localGroup = find.text('本地导入（1）').hitTestable();
        for (var i = 0; i < 3 && localGroup.evaluate().isEmpty; i++) {
          await t.drag(nodes, const Offset(0, -240));
          await t.pumpAndSettle();
        }
        expect(localGroup, findsOneWidget);
        await t.tap(localGroup);
        await t.pumpAndSettle();
        final localNode = find.text('本地 · SOCKS').hitTestable();
        for (var i = 0; i < 3 && localNode.evaluate().isEmpty; i++) {
          await t.drag(nodes, const Offset(0, -240));
          await t.pumpAndSettle();
        }
        expect(localNode, findsOneWidget);
        expect(t.takeException(), isNull);
        await screenshot(t, 'dpi-150-node-list-scrolled');
      }
    }
    await t.pump(const Duration(seconds: 2));
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'traffic panel integrates rates peaks and session figures with real layout',
      (t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    const ui = UiPreferences(motion: 'reduced');
    const node = NodeInfo(
        name: '东京 · 专线节点 · 适合长名称和正常滚动布局的测试',
        outboundJson:
            '{"type":"socks","server":"127.0.0.1","server_port":1080}');
    final preferences = ValueNotifier(ui);
    final monitor = RuntimeMonitor()
      ..available = true
      ..downSpeed = 512 * 1024
      ..upSpeed = 144 * 1024
      ..download = 12 * 1024 * 1024
      ..upload = 4 * 1024 * 1024
      ..connections = [
        {
          'metadata': {'processName': 'firefox.exe'},
          'download': 4000,
          'upload': 3200
        },
        {
          'metadata': {'processName': 'steam.exe'},
          'download': 1200,
          'upload': 800
        },
      ]
      ..downHistory =
          List.generate(60, (index) => (index % 8 + 1) * 1024 * 128.0)
      ..upHistory = List.generate(60, (index) => (index % 9 + 1) * 1024 * 24.0);
    addTearDown(preferences.dispose);
    addTearDown(monitor.dispose);
    await t.pumpWidget(RepaintBoundary(
      key: const ValueKey('capture'),
      child: UiScope(
        controller: preferences,
        onChanged: (_) {},
        child: MaterialApp(
          theme: workbenchTheme(ui),
          home: Scaffold(
              body: DashboardPage(
                  running: true,
                  proxyActive: true,
                  busy: false,
                  selected: node,
                  nodeCount: 180,
                  subscriptionCount: 2,
                  mixedPort: 7890,
                  systemProxy: true,
                  coreVersion: 'sing-box 1.14.4',
                  onModeChanged: (_) {},
                  selectedLatency: 86,
                  selectedMeasured: true,
                  onToggle: () {},
                  onMeasureSelected: () {},
                  onPickNode: () {},
                  monitor: monitor)),
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text('实时流量'), findsOneWidget);
    expect(find.text('峰值 1.00 MB/s'), findsOneWidget);
    expect(find.text('2 条活动连接'), findsOneWidget);
    expect(find.text('firefox.exe'), findsOneWidget);
    await screenshot(t, 'dashboard-live-wide');
    t.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    t.view.physicalSize = const Size(1200, 900);
    t.view.devicePixelRatio = 1.5;
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('实时流量').hitTestable(), findsOneWidget);
    await screenshot(t, 'dashboard-live-compact');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
      'long names and large source remain searchable in a narrow window',
      (t) async {
    const longName = '🇯🇵 东京 · 多线路家庭宽带节点 · 保留完整的超长名称用于悬停与搜索';
    await mount(t, size: const Size(800, 600), extraNodes: [
      const NodeInfo(
          name: longName,
          source: 's1',
          outboundJson:
              '{"type":"socks","server":"node.example.test","server_port":443}'),
      for (var i = 0; i < 180; i++)
        NodeInfo(
            name: '节点样本 $i',
            source: 's1',
            outboundJson:
                '{"type":"socks","server":"node.example.test","server_port":443}'),
    ]);
    await t.tap(find.byTooltip('节点').first);
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).first, '超长名称');
    await t.pumpAndSettle();
    expect(find.byTooltip('东京 · 多线路家庭宽带节点 · 保留完整的超长名称用于悬停与搜索'), findsOneWidget);
    final search = find.byType(TextField).first;
    expect(search.hitTestable(), findsOneWidget);
    expect(t.takeException(), isNull);
    await screenshot(t, 'nodes-long-name-compact');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
      'red-black dashboard clock opens the detailed movement and survives resizing',
      (t) async {
    final fixture = MemoryStore();
    fixture.data.desktop =
        const DesktopSettings(autoRun: true, autoCheckUpdates: false);
    await mount(t, withStore: fixture);
    await screenshot(t, 'redblack-dashboard-1440');
    final action = find.text('展开机芯');
    await t.ensureVisible(action);
    await t.tap(action);
    await t.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.descendant(of: find.byType(Dialog), matching: find.text('机械钟')),
        findsOneWidget);
    await screenshot(t, 'redblack-mechanical-clock');
    t.view.physicalSize = const Size(800, 600);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    Navigator.of(t.element(find.byType(Dialog))).pop();
    await t.pumpAndSettle();
    await screenshot(t, 'redblack-dashboard-800');
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'layout moves persist, status stays anchored, picker selects and drawer opens',
      (t) async {
    final store = await mount(t);
    await t.tap(find.text('调整组件'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('向后移动traffic组件'));
    await t.pumpAndSettle();
    expect(store.data.ui.order, ['status', 'profile', 'traffic', 'runtime']);
    await screenshot(t, 'dashboard-reordered');
    await t.tap(find.text('恢复布局'));
    await t.pumpAndSettle();
    expect(store.data.ui.order.first, 'status');
    expect(store.data.ui.order[1], 'traffic');
    await t.tap(find.text('完成调整'));
    final outlet = find.byKey(const ValueKey('dashboard-outlet'));
    await t.ensureVisible(outlet);
    await t.tap(outlet);
    await t.pumpAndSettle();
    expect(find.byType(NodePicker), findsOneWidget);
    await screenshot(t, 'node-picker');
    await t.enterText(
        find.descendant(
            of: find.byType(NodePicker), matching: find.byType(TextField)),
        '香港');
    await t.pumpAndSettle();
    await t.tap(find.text('香港 · Victoria 02'));
    await t.pumpAndSettle();
    expect(store.data.selectedIndex, 1);
    await t.tap(find.text('节点').first);
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(ChoiceChip, '星海 · 主订阅'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('节点操作').first);
    await t.pumpAndSettle();
    await t.tap(find.text('查看详情'));
    await t.pumpAndSettle();
    expect(find.text('凭据默认隐藏。详情不展示密码、UUID 或完整配置。'), findsOneWidget);
    await screenshot(t, 'node-drawer');
    await t.tap(find.byTooltip('关闭详情'));
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'old subscriptions become node sources without changing the selected node',
      (t) async {
    final store = await mount(t, twoProfiles: true);
    expect(store.data.activeProfileId, '');
    expect(
        store.data.subscriptions
            .every((s) => s.nodesOnly && s.profileJson == null),
        isTrue);
    expect(store.data.selected?.source, 's1');
    await t.tap(find.text('节点').first);
    await t.pumpAndSettle();
    t
        .widget<NodesPage>(find.byType(NodesPage))
        .onSelect(store.data.nodes.indexWhere((node) => node.source == 's2'));
    await t.pumpAndSettle();
    expect(store.data.selected?.source, 's2');
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'light theme, density and character preferences survive real store roundtrip',
      (t) async {
    final store = await mount(t, light: true);
    await screenshot(t, 'dashboard-light');
    await t.tap(find.text('设置').first);
    await t.pumpAndSettle();
    await t.tap(find.text('外观动效'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(ChoiceChip, '紧凑'));
    await t.pumpAndSettle();
    expect(store.data.ui.compact, true);
    final dir =
        await t.runAsync(() => Directory.systemTemp.createTemp('tkb-ui-'));
    await t.runAsync(() async {
      try {
        final disk = Store(File('${dir!.path}/data.json'));
        await disk.save(store.data);
        final loaded = await disk.load();
        expect(loaded.ui.light, true);
        expect(loaded.ui.compact, true);
        expect(loaded.nodes.length, 4);
      } finally {
        await dir!.delete(recursive: true);
      }
    });
    await t.pumpWidget(const SizedBox());
  });
}
