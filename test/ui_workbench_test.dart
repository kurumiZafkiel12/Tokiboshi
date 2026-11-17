import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/main.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/services/store.dart';
import 'package:tokiboshi/services/system_proxy.dart';
import 'package:tokiboshi/ui/preferences.dart';
import 'package:tokiboshi/ui/node_widgets.dart';
import 'package:tokiboshi/ui/import_dialog.dart';
import 'fake_bridge.dart';
import 'widget_test.dart' show MemoryStore;

void main() {
  final capture = Platform.environment['TOKIBOSHI_UI_CAPTURE'];
  setUpAll(() async {
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
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
      bool twoProfiles = false,
      MemoryStore? withStore}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final store = withStore ?? MemoryStore();
    store.data.autoConnect = false;
    store.data.ui = UiPreferences(light: light, motion: 'reduced');
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
    testWidgets(
        'reissue import and general settings surfaces fit ${size.width}',
        (t) async {
      await mount(t, size: size);
      await t.tap(size.width < 900
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
      await t.tap(size.width < 900
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
        await t.tap(size.width < 900
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
    await t.tap(find.text('东京 · Sakura 01').last);
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
    await t.tap(find.byTooltip('节点详情').first);
    await t.pumpAndSettle();
    expect(find.text('凭据默认隐藏。详情不展示密码、UUID 或完整配置。'), findsOneWidget);
    await screenshot(t, 'node-drawer');
    await t.tap(find.byTooltip('关闭详情'));
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('explicit profile switching never reuses a foreign selected node',
      (t) async {
    final store = await mount(t, twoProfiles: true);
    expect(find.text('请选择规则配置'), findsOneWidget);
    await t.tap(find.byType(DropdownButtonFormField<String>).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Orbit · 节点源').last);
    await t.pumpAndSettle();
    expect(store.data.activeProfileId, 's2');
    expect(store.data.selectedIndex, -1);
    expect(find.byType(NodePicker), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(NodePicker), matching: find.text('东京 · Sakura 01')),
        findsNothing);
    await t.tap(find.text('Singapore · Orbit'));
    await t.pumpAndSettle();
    expect(store.data.selected?.source, 's2');
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('pending profile save blocks startup until commit', (t) async {
    final store = SlowProfileStore();
    await mount(t, withStore: store);
    store.block = true;
    await t.tap(find.byType(DropdownButtonFormField<String>).first);
    await t.pumpAndSettle();
    await t.tap(find.text('内置分流模板').last);
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    final start = find.ancestor(
        of: find.text('启动代理'), matching: find.byType(FilledButton));
    expect(t.widget<FilledButton>(start).onPressed, isNull);
    expect(
        (t.widget<TokiboshiApp>(find.byType(TokiboshiApp)).bridge as FakeBridge)
            .running,
        false);
    store.gate.complete();
    await t.pumpAndSettle();
    expect(store.data.activeProfileId, '');
    expect(t.widget<FilledButton>(start).onPressed, isNotNull);
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

class SlowProfileStore extends MemoryStore {
  bool block = false;
  final gate = Completer<void>();
  @override
  Future<void> save(AppData value) async {
    if (block) await gate.future;
    await super.save(value);
  }
}
