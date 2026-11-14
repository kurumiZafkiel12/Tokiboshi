import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/pages/nodes_page.dart';
import 'package:tokiboshi/services/store.dart';

void main() {
  testWidgets('subscription filter includes providers and drawers collapse', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: NodesPage(
      nodes: const [
        NodeInfo(name: 'inline', outboundJson: '{}', source: 'sub'),
        NodeInfo(name: 'provider-node', outboundJson: '{}', source: 'sub', group: 'airport'),
      ],
      subscriptions: const [Subscription(id: 'sub', name: 'hub', url: 'https://test.example')],
      selectedIndex: -1, running: false, busy: false, latency: const {},
      onSelect: (_) {}, onDelete: (_) {}, onImport: () {}, onMeasureAll: () {},
    ))));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'hub'));
    await tester.pumpAndSettle();
    expect(find.text('inline'), findsOneWidget);
    expect(find.text('provider-node'), findsOneWidget);
    await tester.tap(find.text('hub / airport（1）'));
    await tester.pumpAndSettle();
    expect(find.text('provider-node'), findsNothing);
    await tester.tap(find.text('hub / airport（1）'));
    await tester.pumpAndSettle();
    expect(find.text('provider-node'), findsOneWidget);
  });
}
