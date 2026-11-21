import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/pages/network_info.dart';
import 'package:tokiboshi/services/connection_topology.dart';
import 'package:tokiboshi/services/rule_resources.dart';
import 'package:tokiboshi/services/store.dart';
import 'package:tokiboshi/ui/runtime.dart';

Map<String, dynamic> connection(int port, {String group = '代理'}) => {
      'chains': [group, '节点'],
      'rule': 'DOMAIN-SUFFIX',
      'rulePayload': 'fixture.example',
      'metadata': {'sourceIP': '127.0.0.1', 'sourcePort': port},
      'upload': 3,
      'download': 7,
    };

void main() {
  test(
      'topology counts two adjacent shared edges and conserves folded connections',
      () {
    final rows = [for (var i = 0; i < 40; i++) connection(1000 + i)];
    final model = ConnectionTopology(rows, byIp: false);
    expect(model.edges[((0, '代理'), (1, '节点'))]?.count, 40);
    expect(
        model.edges[((1, '节点'), (2, 'DOMAIN-SUFFIX,fixture.example'))]?.count,
        40);
    expect(model.nodes.keys.where((key) => key.$1 == 3), hasLength(24));
    expect(model.nodes[(3, '…+17')]?.upload, 51);
    final byIp = ConnectionTopology(rows, byIp: true);
    expect(byIp.nodes[(3, '127.0.0.1')]?.count, 40);
    expect(byIp.nodes[(3, '127.0.0.1')]?.download, 280);
  });

  testWidgets(
      'compact topology has local details, switching and measured latency',
      (tester) async {
    tester.view.physicalSize = const Size(600, 730);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final monitor = RuntimeMonitor()
      ..available = true
      ..connections = [connection(1000), connection(1001)];
    addTearDown(monitor.dispose);
    var refresh = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: NetworkInfo(
                    monitor: monitor,
                    latency: const [('A', 20), ('B', 40), ('C', null)],
                    refresh: () async {
                      refresh++;
                    })))));
    expect(find.text('1000'), findsOneWidget);
    expect(find.text('平均 30.0 ms'), findsOneWidget);
    expect(find.text('超时'), findsOneWidget);
    await tester.tap(find.text('代理'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 条连接'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('来源 IP'));
    await tester.pumpAndSettle();
    expect(find.text('1000'), findsNothing);
    expect(find.text('127.0.0.1'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('刷新延迟'));
    await tester.tap(find.byTooltip('刷新延迟'));
    await tester.pumpAndSettle();
    expect(refresh, 1);
    expect(tester.takeException(), isNull);
  });

  test(
      'rule resource preferences round trip, validate HTTPS, and throttle at 24 hours',
      () {
    final state = AppData(
        ruleSetAutoUpdate: true,
        routingPreset: 'ai',
        ruleSetUrls: {'geosite-cn': 'https://mirror.example/r.srs'},
        ruleSetLastUpdate: {'geosite-cn': '2026-01-01T00:00:00Z'},
        ruleSetPending: {'geoip-cn'});
    final decoded = Store.decodeData(jsonEncode(Store.encodeData(state)))!;
    expect(decoded.ruleSetUrls, state.ruleSetUrls);
    expect(decoded.ruleSetPending, state.ruleSetPending);
    expect(decoded.ruleSetAutoUpdate, isTrue);
    expect(decoded.routingPreset, 'ai');
    expect(() => validateRuleResourceUrl('http://mirror.example/r.srs'),
        throwsFormatException);
    expect(() => validateRuleResourceUrl('https://user:pass@mirror.example'),
        throwsFormatException);
    validateRuleResourceUrl('');
    final last = decoded.ruleSetLastUpdate['geosite-cn'];
    expect(
        ruleResourceDue(
            downloaded: true,
            pending: false,
            lastUpdate: last,
            now: DateTime.utc(2026, 1, 1, 23)),
        false);
    expect(
        ruleResourceDue(
            downloaded: true,
            pending: false,
            lastUpdate: last,
            now: DateTime.utc(2026, 1, 2)),
        true);
    expect(
        ruleResourceDue(
            downloaded: true,
            pending: true,
            lastUpdate: last,
            now: DateTime.utc(2026, 1, 2)),
        false);
    expect(
        ruleResourceDue(
            downloaded: false,
            pending: false,
            lastUpdate: last,
            now: DateTime.utc(2026, 1, 2)),
        false);
  });

  test('preset references only downloaded local assets after mode rules',
      () async {
    final dir = await Directory.systemTemp.createTemp('tokiboshi-resources-');
    addTearDown(() => dir.delete(recursive: true));
    const downloaded = RuleResource(
        'geosite-netflix', '流媒体', 'https://example.test/netflix.srs');
    const missing =
        RuleResource('geosite-hbo', '流媒体', 'https://example.test/hbo.srs');
    final file = File(downloaded.path(dir.path));
    await file.parent.create();
    await file.writeAsString('fixture');
    const config =
        '{"route":{"rules":[{"clash_mode":"Direct","outbound":"direct"},{"ip_is_private":true,"outbound":"direct"}]}}';
    final result = jsonDecode(applyResourcePreset(
        config, 'streaming', [downloaded, missing], dir.path));
    final route = result['route'];
    expect(route['rule_set'].single['path'], file.path);
    expect(route['rules'][0]['clash_mode'], 'Direct');
    expect(route['rules'][1], {
      'rule_set': ['tokiboshi-resource-geosite-netflix'],
      'outbound': 'proxy'
    });
    expect(route['rules'][2]['ip_is_private'], true);
    expect(
        applyResourcePreset(config, 'streaming', [missing], dir.path), config);
  });
}
