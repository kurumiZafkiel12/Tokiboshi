import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/main.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/pages/nodes_page.dart';
import 'package:tokiboshi/pages/settings_page.dart';
import 'package:tokiboshi/services/client_preferences.dart';
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
        'scheduled refresh ${incompatible ? 'commits nodes-only when source rules are incompatible' : 'commits a due source while stopped'}',
        (t) async {
      desktop(t);
      final store = MemoryStore();
      store.data.autoConnect = false;
      store.data.desktop = store.data.desktop.copyWith(autoCheckUpdates: false);
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
      // Nodes-only by design (2026-11-21): incompatible rule payloads
      // no longer fail the refresh - fresh nodes still commit.
      expect(
          store.data.nodes.single.name, incompatible ? 'usable' : 'fresh-node');
      expect(find.byType(AlertDialog), findsNothing);
      await t.pump(const Duration(seconds: 31));
      await t.pumpAndSettle();
      expect(fetcher.requested, hasLength(1),
          reason: 'failure/success must not cause a 30-second retry storm');
      await t.pumpWidget(const SizedBox());
    });
  }
  testWidgets('restart respects the persisted failed-refresh cooldown',
      (t) async {
    desktop(t);
    final store = MemoryStore();
    store.data.autoConnect = false;
    store.data.desktop = store.data.desktop.copyWith(autoCheckUpdates: false);
    store.data.subscriptions = [
      Subscription(
          id: 's',
          name: 'fixture',
          url: 'https://fixture.example/sub',
          updatedAt: '2020-01-01',
          refreshMinutes: 60,
          lastAttemptAt: DateTime.now().toIso8601String(),
          lastError: 'synthetic failure')
    ];
    final fetcher = FakeFetcher({});
    await t.pumpWidget(TokiboshiApp(
        bridge: FakeBridge(),
        store: store,
        fetcher: fetcher,
        systemProxy: NoopSystemProxy(),
        allocatePort: (p, r) async => p));
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 61));
    await t.pumpAndSettle();
    expect(fetcher.requested, isEmpty);
    expect(store.data.subscriptions.single.lastError, 'synthetic failure');
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('active proxy defers scheduled subscriptions', (t) async {
    desktop(t);
    final store = MemoryStore();
    store.data.autoConnect = false;
    store.data.desktop = store.data.desktop.copyWith(autoCheckUpdates: false);
    store.data.subscriptions = const [
      Subscription(
          id: 's',
          name: 'fixture',
          url: 'https://fixture.example/sub',
          updatedAt: '2020-01-01',
          refreshMinutes: 60)
    ];
    store.data.nodes = const [
      NodeInfo(
          name: 'fixture',
          outboundJson:
              '{"type":"socks","server":"127.0.0.1","server_port":1}'),
    ];
    store.data.selectedIndex = 0;
    final fetcher = FakeFetcher({});
    await t.pumpWidget(TokiboshiApp(
        bridge: FakeBridge(),
        store: store,
        fetcher: fetcher,
        systemProxy: NoopSystemProxy(),
        allocatePort: (p, r) async => p));
    await t.pumpAndSettle();
    await t.tap(find.text('启动代理'));
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
  testWidgets('starting requires an explicit selected exit', (t) async {
    desktop(t);
    final store = MemoryStore();
    store.data.autoConnect = false;
    store.data.desktop = store.data.desktop.copyWith(autoCheckUpdates: false);
    store.data.nodes = const [
      NodeInfo(
          name: 'unselected',
          outboundJson:
              '{"type":"socks","server":"127.0.0.1","server_port":1080}')
    ];
    final bridge = FakeBridge();
    await t.pumpWidget(TokiboshiApp(
        bridge: bridge,
        store: store,
        systemProxy: NoopSystemProxy(),
        allocatePort: (p, r) async => p));
    await t.pumpAndSettle();
    await t.tap(find.text('启动代理'));
    await t.pumpAndSettle();
    expect(bridge.running, false);
    expect(store.data.selectedIndex, -1);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('failed client policy save restores the entire settings snapshot',
      (t) async {
    desktop(t);
    final store = _FailingStore();
    store.data.autoConnect = false;
    store.data.desktop = store.data.desktop.copyWith(autoCheckUpdates: false);
    const original = ClientPreferences(rules: [
      RoutingRule(
          kind: 'domain_suffix', value: 'example.test', target: 'reject')
    ]);
    store.data.client = original;
    await t.pumpWidget(TokiboshiApp(
        bridge: FakeBridge(),
        store: store,
        systemProxy: NoopSystemProxy(),
        allocatePort: (p, r) async => p));
    await t.pumpAndSettle();
    await t.tap(find.text('设置').first);
    await t.pumpAndSettle();
    store.fail = true;
    final callback =
        t.widget<SettingsPage>(find.byType(SettingsPage)).onClientSave!;
    await expectLater(
        callback(const ClientPreferences(
            dnsEnabled: true, dnsEndpoint: 'udp://127.0.0.1:5353')),
        throwsA(isA<FileSystemException>()));
    await t.pumpAndSettle();
    final settings = t.widget<SettingsPage>(find.byType(SettingsPage));
    expect(settings.client.rules.single.target, 'reject');
    expect(settings.client.dnsEnabled, false);
    expect(store.data.client.rules.single.target, 'reject');
    await t.pumpWidget(const SizedBox());
  });
  for (final failure in ['controller', 'disk', 'unapplied acknowledgement']) {
    final diskFailure = failure == 'disk';
    testWidgets('live selection rolls back on $failure failure', (t) async {
      desktop(t);
      final oldOverrides = HttpOverrides.current;
      HttpOverrides.global = _NativeHttp();
      final server = await t
          .runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0));
      var active = 'old-node';
      final puts = <String>[];
      server!.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/proxies' && request.method == 'GET') {
          request.response.write(jsonEncode({
            'proxies': {
              'proxy': {'now': active}
            }
          }));
        } else if (request.method == 'PUT') {
          final data = jsonDecode(await request
              .cast<List<int>>()
              .transform(utf8.decoder)
              .join()) as Map;
          final name = data['name'] as String;
          puts.add(name);
          if (failure == 'controller' && name == 'new-node') {
            request.response.statusCode = 500;
            request.response.write('{}');
          } else {
            if (failure != 'unapplied acknowledgement' || name != 'new-node') {
              active = name;
            }
            request.response.statusCode = 204;
          }
        } else {
          request.response
              .write('{"connections":[],"downloadTotal":0,"uploadTotal":0}');
        }
        await request.response.close();
      });
      final store = _FailingStore();
      store.data.autoConnect = false;
      store.data.desktop =
          store.data.desktop.copyWith(autoCheckUpdates: false, autoRun: true);
      store.data.clashApiSecret = 'synthetic-only';
      store.data.clashApiPort = server.port;
      store.data.nodes = const [
        NodeInfo(
            name: 'old-node',
            outboundJson:
                '{"type":"socks","server":"127.0.0.1","server_port":1080}'),
        NodeInfo(
            name: 'new-node',
            outboundJson:
                '{"type":"socks","server":"127.0.0.1","server_port":1081}')
      ];
      store.data.selectedIndex = 0;
      try {
        await t.pumpWidget(TokiboshiApp(
            bridge: FakeBridge(),
            store: store,
            systemProxy: NoopSystemProxy(),
            allocatePort: (p, r) async => p));
        await t.pumpAndSettle();
        await t.tap(find.text('节点').first);
        await t.pumpAndSettle();
        store.fail = diskFailure;
        t.widget<NodesPage>(find.byType(NodesPage)).onSelect(1);
        for (var i = 0; i < 20 && puts.length < 2; i++) {
          await t.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)));
          await t.pump();
        }
        await t.pumpAndSettle();
        expect(puts, ['new-node', 'old-node']);
        expect(active, 'old-node');
        expect(store.data.selectedIndex, 0);
        expect(t.widget<NodesPage>(find.byType(NodesPage)).selectedIndex, 0);
      } finally {
        await t.pumpWidget(const SizedBox());
        await t.runAsync(() => server.close(force: true));
        HttpOverrides.global = oldOverrides;
      }
    });
  }
}

class _NativeHttp extends HttpOverrides {}

class _FailingStore extends MemoryStore {
  bool fail = false;
  @override
  Future<void> save(AppData data) async {
    if (fail) throw StateError("synthetic disk failure");
    await super.save(data.copyWith());
  }
}
