import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/main.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/services/import_io.dart';
import 'package:tokiboshi/services/subscription_fetcher.dart';
import 'package:tokiboshi/services/system_proxy.dart';
import 'package:tokiboshi/ui/import_dialog.dart';
import 'fake_bridge.dart';
import 'widget_test.dart' show MemoryStore;

class ImportBridge extends FakeBridge {
  @override
  Future<ParseOutcome> parseSubscription(String text) async {
    if (text == 'unsupported')
      return const ParseOutcome(
          nodes: [
            NodeInfo(
                name: 'usable',
                outboundJson:
                    '{"type":"socks","server":"127.0.0.1","server_port":1080}')
          ],
          profileJson:
              '{"unsupported":["dns.enhanced-mode fake-ip","未知 DNS 参数"],"rule_sets":[]}');
    if (text.trimLeft().startsWith('{')) {
      final v = jsonDecode(text) as Map<String, dynamic>;
      final nodes = (v['outbounds'] as List).map((raw) {
        final n = Map<String, dynamic>.from(raw as Map);
        final name = n.remove('tag') as String? ?? 'custom';
        return NodeInfo(name: name, outboundJson: jsonEncode(n));
      }).toList();
      return ParseOutcome(
          nodes: nodes,
          profileJson: v.containsKey('route')
              ? jsonEncode({
                  'route_rules': (v['route'] as Map)['rules'] ?? [],
                  'rule_sets': [],
                  'final_outbound': (v['route'] as Map)['final'],
                  'unsupported': []
                })
              : null);
    }
    return super.parseSubscription(text);
  }
}

class FixtureIo extends ImportIo {
  const FixtureIo();
  @override
  Future<String?> readClipboard() async =>
      'ss://aes-128-gcm:synthetic@127.0.0.1:8388#clipboard';
  @override
  Future<String?> readQrFile() async =>
      'ss://aes-128-gcm:synthetic@127.0.0.1:8389#qr-image';
  @override
  Future<String?> readClipboardQr() async =>
      'ss://aes-128-gcm:synthetic@127.0.0.1:8390#qr-clipboard';
  @override
  Future<ImportedFile?> readConfigFile() async => const ImportedFile(
      'fixture.json',
      'synthetic-fixture.json',
      '{"outbounds":[{"tag":"file-node","type":"socks","server":"127.0.0.1","server_port":1080}],"route":{"final":"file-node","rules":[]}}');
}

class FailedImportStore extends MemoryStore {
  bool fail = false;
  @override
  Future<void> save(value) async {
    if (fail) throw StateError('synthetic write failure');
    await super.save(value);
  }
}

void main() {
  Future<(MemoryStore, ImportBridge)> mount(WidgetTester t,
      {MemoryStore? store, SubscriptionFetcher? fetcher}) async {
    t.view.physicalSize = const Size(1280, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final s = store ?? MemoryStore();
    s.data.autoConnect = false;
    final bridge = ImportBridge();
    await t.pumpWidget(TokiboshiApp(
        bridge: bridge,
        store: s,
        systemProxy: NoopSystemProxy(),
        fetcher: fetcher ?? FakeFetcher({}),
        importIo: const FixtureIo(),
        allocatePort: (p, r) async => p));
    await t.pumpAndSettle();
    return (s, bridge);
  }

  Future<void> open(WidgetTester t, String method) async {
    await t.tap(find.text('节点').first);
    await t.pumpAndSettle();
    await t.tap(find.text('导入'));
    await t.pumpAndSettle();
    expect(find.text('二维码'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
    expect(find.text('链接'), findsOneWidget);
    expect(find.text('自定义'), findsOneWidget);
    await t.tap(find.text(method));
    await t.pumpAndSettle();
    expect(find.byType(ImportDialog), findsOneWidget);
  }

  Future<void> submit(WidgetTester t) async {
    await t.tap(find.text('导入').last);
    await t.pumpAndSettle();
  }

  testWidgets('clipboard import writes a real manual node and preserves name',
      (t) async {
    final (store, _) = await mount(t);
    await open(t, '剪贴板 / 文本');
    await t.tap(find.text('从剪贴板读取'));
    await t.pumpAndSettle();
    await submit(t);
    expect(store.data.nodes.single.name, 'clipboard');
    expect(store.data.nodes.single.source, '');
    await t.pumpWidget(const SizedBox());
  });
  for (final clip in [false, true]) {
    testWidgets(
        'QR ${clip ? 'clipboard' : 'image'} result reaches the same node persistence',
        (t) async {
      final (store, _) = await mount(t);
      await open(t, '二维码');
      await t.tap(find.text(clip ? '读取剪贴板图片' : '选择二维码图片'));
      await t.pumpAndSettle();
      await submit(t);
      expect(store.data.nodes.single.name, clip ? 'qr-clipboard' : 'qr-image');
      await t.pumpWidget(const SizedBox());
    });
  }
  testWidgets('file JSON keeps routing profile and local source ownership',
      (t) async {
    final (store, _) = await mount(t);
    await open(t, '文件');
    await t.tap(find.text('选择文件'));
    await t.pumpAndSettle();
    await submit(t);
    expect(store.data.subscriptions.single.localPath, 'synthetic-fixture.json');
    expect(store.data.subscriptions.single.profileJson, isNotNull);
    expect(store.data.nodes.single.source, store.data.subscriptions.single.id);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('custom VLESS validates UUID and preserves TLS fields',
      (t) async {
    final (store, _) = await mount(t);
    await open(t, '自定义');
    Future<void> fill(String label, String value) async {
      final field = find.widgetWithText(TextField, label);
      await t.ensureVisible(field);
      await t.enterText(field, value);
    }

    await fill('名称（可选）', 'manual-vless');
    await fill('服务器', 'example.test');
    await fill('UUID', 'invalid');
    await t.tap(find.text('导入').last);
    await t.pumpAndSettle();
    expect(find.text('请填写有效 UUID'), findsOneWidget);
    await fill('UUID', '11111111-2222-3333-4444-555555555555');
    await submit(t);
    expect(store.data.nodes.single.protocol, 'vless');
    expect(store.data.nodes.single.outbound['tls']['enabled'], true);
    expect(store.data.nodes.single.source, '');
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'smart incompatibility requires consent and remembers node-only choice on update',
      (t) async {
    final fetch = FakeFetcher({'https://fixture.example/sub': 'unsupported'});
    final (store, _) = await mount(t, fetcher: fetch);
    await open(t, '链接');
    final fields = find.descendant(
        of: find.byType(ImportDialog), matching: find.byType(TextField));
    await t.enterText(fields.last, '[订阅](https://fixture.example/sub)');
    await t.tap(find.text('导入').last);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('节点可导入，完整规则暂不兼容'), findsOneWidget);
    expect(store.data.nodes, isEmpty);
    await t.tap(find.text('仅导入节点'));
    await t.pumpAndSettle();
    expect(store.data.nodes.single.name, 'usable');
    expect(store.data.subscriptions.single.nodesOnly, true);
    expect(store.data.subscriptions.single.profileJson, isNull);
    expect(fetch.requested.length, 1);
    await t.tap(find.text('订阅').first);
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('更新'));
    await t.pumpAndSettle();
    expect(find.text('节点可导入，完整规则暂不兼容'), findsNothing);
    expect(store.data.nodes.length, 1);
    expect(fetch.requested.length, 2);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('cancelling incompatible profile preserves existing data',
      (t) async {
    final store = MemoryStore();
    store.data.nodes = const [
      NodeInfo(name: 'old', outboundJson: '{"type":"socks"}')
    ];
    store.data.selectedIndex = 0;
    await mount(t,
        store: store,
        fetcher: FakeFetcher({'https://fixture.example/sub': 'unsupported'}));
    await open(t, '链接');
    await t.enterText(
        find
            .descendant(
                of: find.byType(ImportDialog), matching: find.byType(TextField))
            .last,
        'https://fixture.example/sub');
    await t.tap(find.text('导入').last);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.text('取消，保留原配置'));
    await t.pumpAndSettle();
    expect(store.data.nodes.single.name, 'old');
    expect(store.data.subscriptions, isEmpty);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('failed import persistence rolls back nodes and sources',
      (t) async {
    final store = FailedImportStore();
    await mount(t, store: store);
    await open(t, '剪贴板 / 文本');
    await t.tap(find.text('从剪贴板读取'));
    await t.pumpAndSettle();
    store.fail = true;
    await submit(t);
    expect(store.data.nodes, isEmpty);
    expect(store.data.subscriptions, isEmpty);
    expect(find.textContaining('导入保存失败'), findsWidgets);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'in-flight import cancel prevents a late network result from being committed',
      (t) async {
    final fetch = HeldFetcher();
    final (store, _) = await mount(t, fetcher: fetch);
    await open(t, '链接');
    await t.enterText(
        find
            .descendant(
                of: find.byType(ImportDialog), matching: find.byType(TextField))
            .last,
        'https://fixture.example/sub');
    await t.tap(find.text('导入').last);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('取消连接'), findsNothing);
    await t.tap(find.text('取消导入'));
    fetch.complete.complete('ss://aes-128-gcm:synthetic@127.0.0.1:8388#late');
    await t.pumpAndSettle();
    expect(store.data.nodes, isEmpty);
    expect(store.data.subscriptions, isEmpty);
    await t.pumpWidget(const SizedBox());
  });
}

class HeldFetcher implements SubscriptionFetcher {
  final complete = Completer<String>();
  @override
  Future<String> fetch(String url, {String? userAgent}) => complete.future;
}
