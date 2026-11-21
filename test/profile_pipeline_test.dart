import 'package:tokiboshi/pages/nodes_page.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/main.dart';
import 'package:tokiboshi/ui/import_dialog.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/services/store.dart';
import 'package:tokiboshi/services/subscription_fetcher.dart';
import 'package:tokiboshi/services/subscription_resolver.dart';
import 'package:tokiboshi/services/system_proxy.dart';
import 'fake_bridge.dart';
import 'widget_test.dart' show MemoryStore;

const profile =
    '{"route_rules":[],"rule_sets":[],"final_outbound":"fixture","dns":null,"unsupported":[],"rules_total":1}';
const fixture = NodeInfo(
    name: 'fixture',
    outboundJson: '{"type":"socks","server":"127.0.0.1","server_port":1}');

class ProfileBridge extends FakeBridge {
  String? receivedProfile;
  List<String>? receivedNodes;
  @override
  Future<ParseOutcome> parseSubscription(String text) async => ParseOutcome(
      nodes: const [fixture], profileJson: text == 'full' ? profile : null);
  @override
  Future<String> buildConfig(
      {required List<NodeSpec> nodes,
      int mixedPort = 7890,
      int clashApiPort = 9090,
      bool enableTun = false,
      bool blockAds = true,
      bool bypassCn = true,
      String dataDir = '',
      String? selectedName,
      String profileJson = ''}) {
    receivedProfile = profileJson;
    receivedNodes = nodes.map((n) => n.name).toList();
    return super.buildConfig(
        nodes: nodes,
        mixedPort: mixedPort,
        clashApiPort: clashApiPort,
        enableTun: enableTun,
        blockAds: blockAds,
        bypassCn: bypassCn,
        dataDir: dataDir,
        selectedName: selectedName,
        profileJson: profileJson);
  }
}

class Outcomes extends FakeBridge {
  Outcomes(this.values);
  final Map<String, ParseOutcome> values;
  @override
  Future<ParseOutcome> parseSubscription(String text) async => values[text]!;
}

void main() {
  test('root profile survives expansion; child routing never replaces root',
      () async {
    final b = Outcomes({
      'root': const ParseOutcome(
          nodes: [],
          profileJson: profile,
          providers: [
            ProviderInfo(name: 'nodes', url: 'https://fixture.example/child')
          ]),
      'child': const ParseOutcome(
          nodes: [fixture],
          profileJson: '{"unsupported":["child routing unused"]}')
    });
    final r = await SubscriptionResolver(
        bridge: b,
        fetcher: FakeFetcher({
          'https://fixture.example/root': 'root',
          'https://fixture.example/child': 'child'
        })).resolve('https://fixture.example/root');
    expect(r.profileJson, profile);
    expect(r.nodes.length, 1);
  });
  test('unsupported root rejects update rather than becoming nodes-only',
      () async {
    final b = Outcomes({
      'bad': const ParseOutcome(
          nodes: [fixture], profileJson: '{"unsupported":["dns.fake-ip"]}')
    });
    expect(
        SubscriptionResolver(
                bridge: b,
                fetcher: FakeFetcher({'https://fixture.example/root': 'bad'}))
            .resolve('https://fixture.example/root'),
        throwsFormatException);
  });
  test('profile and profile state survive actual Store save/load', () async {
    final dir =
        await Directory.systemTemp.createTemp('tokiboshi-profile-test-');
    try {
      final store = Store(File('${dir.path}/data.json'));
      await store.save(AppData(subscriptions: [
        Subscription(
            id: 'root',
            name: 'root',
            url: 'https://fixture.example/root',
            profileJson: profile,
            profileState: 'parsed')
      ]));
      final loaded = await store.load();
      expect(loaded.subscriptions.single.profileJson, profile);
      expect(loaded.subscriptions.single.profileState, 'parsed');
    } finally {
      await dir.delete(recursive: true);
    }
  });
  testWidgets(
      'URL add/start runs nodes-only and keeps source isolation across updates',
      (t) async {
    t.view.physicalSize = const Size(1280, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final store = MemoryStore();
    store.data.autoConnect = false;
    store.data.nodes = const [
      NodeInfo(
          name: 'other',
          outboundJson: '{"type":"socks","server":"127.0.0.1","server_port":2}')
    ];
    final bridge = ProfileBridge();
    final fetcher = FakeFetcher({'https://fixture.example/root': 'full'});
    await t.pumpWidget(TokiboshiApp(
        bridge: bridge,
        store: store,
        fetcher: fetcher,
        systemProxy: NoopSystemProxy(),
        allocatePort: (p, r) async => p));
    await t.pumpAndSettle();
    await t.tap(find.text('订阅').first);
    await t.pumpAndSettle();
    await t.tap(find.text('添加订阅'));
    await t.pumpAndSettle();
    await t.tap(find.text('链接'));
    await t.pumpAndSettle();
    final fields = find.descendant(
        of: find.byType(ImportDialog), matching: find.byType(TextField));
    await t.enterText(fields.first, 'root');
    await t.enterText(fields.last, 'https://fixture.example/root');
    await t.tap(find.text('导入').last);
    await t.pumpAndSettle();
    // Nodes-only by design (2026-11-21): subscription rules are never
    // imported, so no profile reaches the bridge on start.
    expect(store.data.subscriptions.single.profileJson, isNull);
    expect(store.data.subscriptions.single.profileState, 'nodes-only');
    await t.tap(find.text('节点').first);
    await t.pumpAndSettle();
    t.widget<NodesPage>(find.byType(NodesPage)).onSelect(store.data.nodes
        .indexWhere((n) => n.source == store.data.subscriptions.single.id));
    await t.pumpAndSettle();
    await t.tap(find.text('连接').first);
    await t.pumpAndSettle();
    await t.tap(find.text('启动代理'));
    await t.pumpAndSettle();
    expect(bridge.receivedProfile, isNot(profile));
    // Nodes-only config carries every node as an outbound, not just
    // the subscription's own source-scoped set.
    expect(bridge.receivedNodes, contains('fixture'));
    expect(bridge.receivedNodes, contains('other'));
    expect(bridge.running, true);
    await t.tap(find.text('停止代理'));
    await t.pumpAndSettle();
    await t.tap(find.text('订阅').first);
    await t.pumpAndSettle();
    fetcher.responses['https://fixture.example/root'] = 'plain';
    await t.tap(find.byTooltip('更新'));
    await t.pumpAndSettle();
    expect(store.data.subscriptions.single.profileJson, isNull);
    expect(store.data.subscriptions.single.profileState, 'nodes-only');
    expect(bridge.running, false);
    await t.pumpWidget(const SizedBox());
  });
}
