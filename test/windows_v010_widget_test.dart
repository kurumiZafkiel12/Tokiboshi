import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/main.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/pages/nodes_page.dart';
import 'package:tokiboshi/services/store.dart';
import 'package:tokiboshi/services/subscription_fetcher.dart';
import 'package:tokiboshi/services/system_proxy.dart';
import 'package:tokiboshi/ui/subscription_editor.dart';
import 'fake_bridge.dart';
import 'import_widget_test.dart' show ImportBridge;
import 'widget_test.dart' show MemoryStore;

void main() {
  void desktop(WidgetTester t) {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
  }

  for (final incompatible in [false, true]) {
    testWidgets(
        'scheduled refresh ${incompatible ? 'preserves old data without consent dialog on incompatibility' : 'commits a due source while stopped'}',
        (t) async {
      desktop(t);
      final store = MemoryStore();
      store.data.autoConnect = false;
      store.data.nodes = const [
        NodeInfo(
            name: 'old-node',
            source: 's',
            outboundJson:
                '{"type":"socks","server":"127.0.0.1","server_port":1080}')
      ];
      store.data.selectedIndex = 0;
      store.data.subscriptions = const [
        Subscription(
            id: 's',
            name: 'fixture',
            url: 'https://fixture.example/sub',
            updatedAt: '2020-01-01',
            refreshMinutes: 60)
      ];
      final fetcher = FakeFetcher({
        'https://fixture.example/sub': incompatible
            ? 'unsupported'
            : 'ss://synthetic@127.0.0.1:8388#fresh-node'
      });
      await t.pumpWidget(TokiboshiApp(
          bridge: ImportBridge(),
          store: store,
          fetcher: fetcher,
          systemProxy: NoopSystemProxy(),
          allocatePort: (p, r) async => p));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 31));
      await t.pumpAndSettle();
      expect(fetcher.requested, hasLength(1));
      expect(store.data.nodes.single.name,
          incompatible ? 'old-node' : 'fresh-node');
      if (incompatible) {
        expect(store.data.subscriptions.single.lastError, isNotNull);
        expect(find.byType(AlertDialog), findsNothing);
      }
      await t.pump(const Duration(seconds: 31));
      await t.pumpAndSettle();
      expect(fetcher.requested, hasLength(1),
          reason: 'failure/success must not cause a 30-second retry storm');
      await t.pumpWidget(const SizedBox());
    });
  }
  testWidgets('live core defers scheduled subscriptions', (t) async {
    desktop(t);
    final store = MemoryStore();
    store.data.autoConnect = false;
    store.data.subscriptions = const [
      Subscription(
          id: 's',
          name: 'fixture',
          url: 'https://fixture.example/sub',
          updatedAt: '2020-01-01',
          refreshMinutes: 60)
    ];
    final fetcher = FakeFetcher({});
    await t.pumpWidget(TokiboshiApp(
        bridge: FakeBridge()..running = true,
        store: store,
        fetcher: fetcher,
        systemProxy: NoopSystemProxy(),
        allocatePort: (p, r) async => p));
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 61));
    await t.pumpAndSettle();
    expect(fetcher.requested, isEmpty);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'editor keeps unsaved draft when persistence fails and confirms discard',
      (t) async {
    desktop(t);
    const source = Subscription(
        id: 's', name: 'old-name', url: 'https://fixture.example/sub');
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (c) => TextButton(
                    onPressed: () => editSubscription(c, source,
                        onSave: (_) async =>
                            throw StateError('synthetic disk failure')),
                    child: const Text('open'))))));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).first, 'edited-name');
    await t.tap(find.text('保存设置'));
    await t.pumpAndSettle();
    expect(find.textContaining('synthetic disk failure'), findsOneWidget);
    expect(find.text('edited-name'), findsOneWidget);
    expect(source.name, 'old-name');
    await t.tap(find.byTooltip('关闭编辑'));
    await t.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await t.tap(find.text('继续编辑'));
    await t.pumpAndSettle();
    expect(find.text('edited-name'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('large node sources build only visible tiles', (t) async {
    desktop(t);
    final nodes = List.generate(
        5000,
        (i) => NodeInfo(
            name: 'fixture-node-$i',
            outboundJson:
                '{"type":"socks","server":"127.0.0.1","server_port":1080}'));
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NodesPage(
                nodes: nodes,
                subscriptions: const [],
                selectedIndex: -1,
                running: false,
                busy: false,
                latency: const {},
                onSelect: (_) {},
                onDelete: (_) {},
                onImport: () {},
                onMeasureAll: () {}))));
    await t.pumpAndSettle();
    expect(find.text('fixture-node-0'), findsOneWidget);
    expect(find.text('fixture-node-4999'), findsNothing);
    expect(
        find.textContaining('fixture-node-').evaluate().length, lessThan(100));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
