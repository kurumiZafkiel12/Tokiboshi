import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/mobile/android_app.dart';
import 'package:tokiboshi/mobile/android_bridge.dart';
import 'package:tokiboshi/mobile/android_controller.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/services/store.dart';
import 'package:tokiboshi/services/client_preferences.dart';
import 'package:tokiboshi/ui/preferences.dart';
import 'package:tokiboshi/ui/import_dialog.dart';
import 'package:tokiboshi/services/subscription_fetcher.dart';
import 'fake_bridge.dart';
import 'widget_test.dart' show MemoryStore;

class FailingMobileStore extends MemoryStore {
  @override
  Future<void> save(AppData value) async =>
      throw const FileSystemException('synthetic locked storage');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sample =
      '{"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":7890}],"route":{"rules":[],"final":"proxy"},"experimental":{"clash_api":{"external_controller":"127.0.0.1:9090","secret":"synthetic","external_ui":"ui","external_ui_download_url":"https://fixture.example/ui.zip","external_ui_download_detour":"direct"}}}';
  test(
      'Android config adds IPv4/IPv6 TUN and DNS hijack while retaining authenticated API',
      () {
    final config = jsonDecode(androidConfig(sample));
    final tun = (config['inbounds'] as List).last;
    expect(tun['address'], ['172.19.0.1/30', 'fdfe:dcba:9876::1/126']);
    expect(tun['stack'], 'gvisor');
    expect(tun['dns_mode'], 'hijack');
    expect(config['route']['rules'][1]['action'], 'hijack-dns');
    expect(config['experimental']['clash_api']['secret'], 'synthetic');
    expect(
        config['experimental']['clash_api']
            .containsKey('external_ui_download_url'),
        false);
  });
  test(
      'Android preferences preserve DNS interception before custom reject rules',
      () {
    final config = jsonDecode(applyClientPreferences(
        androidConfig(sample),
        const ClientPreferences(
            rules: [RoutingRule(kind: 'port', value: '53', target: 'reject')]),
        hasProfile: false));
    expect(config['route']['rules'].map((rule) => rule['action']),
        ['sniff', 'hijack-dns', 'reject']);
  });
  test(
      'Android scheduled refresh preserves old source on failure and clears ambiguous exit',
      () async {
    final store = MemoryStore();
    const url = 'https://fixture.example/scheduled';
    const source = Subscription(
        id: 'source',
        name: 'Fixture',
        url: url,
        refreshMinutes: 30,
        updatedAt: '2020-01-01');
    final fetcher = FakeFetcher({});
    final bridge = FakeBridge();
    final previous =
        (await bridge.parseShareLink('ss://fixture#old')).withSource(source.id);
    store.data
      ..nodes = [previous]
      ..subscriptions = [source]
      ..selectedIndex = 0;
    final c = AndroidController(
        bridge: bridge, store: store, data: store.data, fetcher: fetcher);
    addTearDown(c.dispose);
    c.running = true;
    await c.refreshDueSources();
    expect(fetcher.requested, isEmpty);
    c.running = false;
    await c.refreshDueSources();
    expect(c.data.selected, same(previous));
    expect(c.data.subscriptions.single.lastError, isNotNull);
    fetcher.responses[url] = 'ss://fixture#first\nss://fixture#second';
    await c.refreshDueSources();
    expect(fetcher.requested, [url]);
    await c.updateSource(c.data.subscriptions.single);
    expect(c.data.nodes, hasLength(2));
    expect(c.data.selectedIndex, -1);
    expect(c.data.subscriptions.single.refreshMinutes, 30);
    expect(c.data.subscriptions.single.lastError, isNull);
  });
  test(
      'Android source editor receives failed write and retains original source',
      () async {
    final store = FailingMobileStore();
    const source = Subscription(
        id: 'source', name: 'Before', url: 'https://fixture.example/sub');
    store.data.subscriptions = [source];
    final c =
        AndroidController(bridge: FakeBridge(), store: store, data: store.data);
    addTearDown(c.dispose);
    await expectLater(c.editSource(source, source.copyWith(name: 'After')),
        throwsA(isA<FileSystemException>()));
    expect(c.data.subscriptions.single, same(source));
  });
  test('Android VPN settings persist in store and keep the selected values',
      () async {
    final store = MemoryStore();
    final controller =
        AndroidController(bridge: FakeBridge(), store: store, data: store.data);
    addTearDown(controller.dispose);
    await controller.saveVpnSettings(
        mtu: 1400, excludedApps: ['fixture.app', 'fixture.app']);
    final restored =
        Store.decodeData(jsonEncode(Store.encodeData(store.data)))!;
    expect(restored.androidMtu, 1400);
    expect(restored.androidExcludedApps, ['fixture.app']);
    expect(Store.decodeData('{}')?.androidMtu, 1500);
  });

  test('Android declined VPN consent never starts a service', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidVpnChannel, (call) async {
      calls.add(call.method);
      if (call.method == 'prepare') return false;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidVpnChannel, null));
    await expectLater(
        AndroidCoreBridge().startCore(
            singBoxPath: 'unused', configPath: 'private/config.json'),
        throwsFormatException);
    expect(calls, ['prepare']);
  });
  test('Android start waits for native running state and failure cleans up',
      () async {
    var failing = false;
    Object? startArgs;
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidVpnChannel, (call) async {
      calls.add(call.method);
      if (call.method == 'prepare') return true;
      if (call.method == 'start') startArgs = call.arguments;
      if (call.method == 'status')
        return {
          'phase': failing ? 'error' : 'running',
          'running': !failing,
          'error': failing ? 'synthetic start error' : null
        };
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidVpnChannel, null));
    final bridge = AndroidCoreBridge();
    await bridge.startCore(
        singBoxPath: 'unused',
        configPath: 'private/config.json',
        excludedApps: ['fixture.app']);
    expect(startArgs, containsPair('excludedApps', ['fixture.app']));
    expect(calls.contains('status'), true);
    failing = true;
    await expectLater(
        bridge.startCore(
            singBoxPath: 'unused', configPath: 'private/config.json'),
        throwsFormatException);
    expect(calls.last, 'stop');
  });
  test('Android stop waits for service cleanup after terminal phase', () async {
    var polls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidVpnChannel, (call) async {
      if (call.method == 'status') {
        polls++;
        return {
          'phase': 'stopped',
          'running': false,
          'serviceAlive': polls < 3
        };
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidVpnChannel, null));
    await AndroidCoreBridge().stopCore();
    expect(polls, 3);
  });

  test('mobile failed persistence preserves prior nodes and configuration',
      () async {
    final store = FailingMobileStore();
    store.data.nodes = const [
      NodeInfo(
          name: 'old',
          outboundJson: '{"type":"socks","server":"127.0.0.1","server_port":1}')
    ];
    store.data.selectedIndex = 0;
    final c =
        AndroidController(bridge: FakeBridge(), store: store, data: store.data);
    addTearDown(c.dispose);
    await c.importRequest(
        const ImportRequest(text: 'ss://fixture#new', manual: true));
    expect(c.data.nodes.single.name, 'old');
    expect(c.data.selectedIndex, 0);
    expect(c.message, contains('操作失败'));
  });
  test(
      'mobile remote URL import persists source and update keeps selected source',
      () async {
    final store = MemoryStore();
    final bridge = FakeBridge();
    final fetcher =
        FakeFetcher({'https://fixture.example/sub': 'ss://fixture#remote'});
    final c = AndroidController(
        bridge: bridge, store: store, data: store.data, fetcher: fetcher);
    addTearDown(c.dispose);
    await c.importRequest(
        const ImportRequest(text: 'https://fixture.example/sub'));
    expect(c.data.subscriptions.single.url, 'https://fixture.example/sub');
    expect(c.data.selected?.name, 'remote');
    expect(c.data.nodes.single.source, c.data.subscriptions.single.id);
    await c.updateSource(c.data.subscriptions.single);
    expect(c.data.nodes, hasLength(1));
    expect(c.data.selected?.name, 'remote');
  });
  test('mobile auto-connect defaults on and a saved opt-out survives reopening',
      () async {
    final store = MemoryStore();
    store.data.nodes = const [
      NodeInfo(
          name: 'fixture',
          outboundJson:
              '{"type":"socks","server":"127.0.0.1","server_port":1080}')
    ];
    store.data.selectedIndex = 0;
    final bridge = FakeBridge();
    final controller =
        AndroidController(bridge: bridge, store: store, data: store.data);
    expect(controller.data.autoConnect, true);
    await controller.initialize(poll: false);
    expect(bridge.running, true);
    expect(controller.message, 'VPN 已连接');
    await controller.saveOptions(autoConnect: false);
    controller.dispose();
    await bridge.stopCore();
    final reopened = AndroidController(
        bridge: bridge, store: store, data: await store.load());
    addTearDown(reopened.dispose);
    await reopened.initialize(poll: false);
    expect(reopened.data.autoConnect, false);
    expect(bridge.running, false);
  });
  final capture = Platform.environment['TOKIBOSHI_ANDROID_UI_CAPTURE'];
  setUpAll(() async {
    final font = Platform.environment['TOKIBOSHI_UI_FONT'];
    if (font != null) {
      final bytes = await File(font).readAsBytes();
      for (final family in ['Roboto', 'Segoe UI', 'Noto Sans CJK SC']) {
        await (FontLoader(family)
              ..addFont(Future.value(ByteData.sublistView(bytes))))
            .load();
      }
    }
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  Future<void> shot(WidgetTester t, String name) async {
    if (capture == null) return;
    await t.runAsync(() async {
      final image = await t
          .renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('mobile-capture')))
          .toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(capture).create(recursive: true);
      await File('$capture/$name.png').writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final size in [
    const Size(390, 844),
    const Size(320, 640),
    const Size(740, 360)
  ]) {
    testWidgets(
        'mobile navigation and import panels fit ${size.width}x${size.height}',
        (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final store = MemoryStore();
      store.data.ui = const UiPreferences(motion: 'reduced');
      store.data.nodes = const [
        NodeInfo(
            name: '东京 · Android 测试节点',
            outboundJson:
                '{"type":"socks","server":"fixture.example","server_port":1080}')
      ];
      store.data.selectedIndex = 0;
      final c = AndroidController(
          bridge: FakeBridge(), store: store, data: store.data);
      await t.pumpWidget(RepaintBoundary(
          key: const ValueKey('mobile-capture'),
          child: AndroidApp(controller: c, initialize: false)));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await shot(t, 'home-${size.width.toInt()}');
      for (final name in ['节点', '订阅', '设置', '连接']) {
        await t.tap(find.widgetWithText(NavigationDestination, name));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull, reason: name);
        await shot(
            t,
            'page-${{
              '节点': 'nodes',
              '订阅': 'sources',
              '设置': 'settings',
              '连接': 'home'
            }[name]}-${size.width.toInt()}');
      }
      for (final method in ['链接', '文件', '二维码', '自定义', '剪贴板 / 文本']) {
        await t.tap(find.byTooltip('导入节点或订阅'));
        await t.pumpAndSettle();
        await t.tap(find.text(method));
        await t.pumpAndSettle();
        expect(find.byType(ImportDialog), findsOneWidget);
        expect(t.takeException(), isNull, reason: method);
        await shot(
            t,
            'import-${{
              '链接': 'link',
              '文件': 'file',
              '二维码': 'qr',
              '自定义': 'custom',
              '剪贴板 / 文本': 'clipboard'
            }[method]}-${size.width.toInt()}');
        await t.tap(find.text('取消').last);
        await t.pumpAndSettle();
      }
      await t.pumpWidget(const SizedBox());
    });
  }
}
