import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/main.dart';
import 'package:tokiboshi/services/store.dart';
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
  Future<AppData> load() async => data;

  @override
  Future<void> save(AppData value) async {
    data = value;
  }

  @override
  Future<File> writeRuntimeConfig(String configJson) async {
    runtimeConfig = configJson;
    return File('memory-config.json');
  }
}

void main() {
  testWidgets('import, subscribe and start/stop flow', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = MemoryStore();
    final bridge = FakeBridge();
    final proxy = NoopSystemProxy();
    final fetcher = FakeFetcher({
      'https://sub.example.com/abc':
          'ss://aes-256-gcm:pw@127.0.0.1:8388#a\n'
              'ss://aes-256-gcm:pw@127.0.0.1:8389#b\n',
    });

    await tester.pumpWidget(
      TokiboshiApp(
        bridge: bridge,
        store: store,
        systemProxy: proxy,
        fetcher: fetcher,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('sing-box 已停止'), findsOneWidget);
    expect(find.text('未选择节点'), findsOneWidget);

    // Import one ss link from the nodes page.
    await tester.tap(find.text('节点').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'ss://aes-256-gcm:pw@127.0.0.1:8388#x',
    );
    await tester.tap(find.text('导入').last);
    await tester.pumpAndSettle();
    expect(find.text('x'), findsOneWidget);
    expect(store.data.nodes, hasLength(1));
    expect(store.data.nodes.single.source, '');

    // Add a subscription by URL from the subscriptions page.
    await tester.tap(find.text('订阅').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加订阅'));
    await tester.pumpAndSettle();
    final dialogFields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogFields.first, 'TestSub');
    await tester.enterText(dialogFields.last, 'https://sub.example.com/abc');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(fetcher.requested, ['https://sub.example.com/abc']);
    expect(find.text('TestSub'), findsOneWidget);
    expect(store.data.subscriptions, hasLength(1));
    expect(store.data.nodes, hasLength(3));
    expect(store.data.nodes.where((n) => n.source.isNotEmpty), hasLength(2));

    // Back on the dashboard: start and stop.
    await tester.tap(find.text('仪表盘').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('启动'));
    await tester.pumpAndSettle();
    expect(find.text('sing-box 运行中'), findsOneWidget);
    expect(bridge.running, isTrue);
    expect(store.runtimeConfig, isNotNull);
    expect(proxy.calls, [(enable: true, port: 7890)]);

    await tester.tap(find.text('停止'));
    await tester.pumpAndSettle();
    expect(find.text('sing-box 已停止'), findsOneWidget);
    expect(bridge.running, isFalse);
    expect(proxy.calls.last, (enable: false, port: 7890));
  });

  testWidgets('pasting a subscription URL in import adds a subscription',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = MemoryStore();
    final fetcher = FakeFetcher({
      'https://sub.example.com/abc':
          'ss://aes-256-gcm:pw@127.0.0.1:8388#a\n',
    });
    await tester.pumpWidget(
      TokiboshiApp(
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
    final dialogFields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogFields.first, 'HubSub');
    await tester.enterText(dialogFields.last, 'https://hub.example.com/sub');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(
      fetcher.requested,
      ['https://hub.example.com/sub', 'https://provider.example/sub'],
    );
    // Inline node + provider node; the 剩余流量 info node is excluded
    // by the provider's exclude-filter.
    expect(store.data.nodes, hasLength(2));
    final providerNode =
        store.data.nodes.singleWhere((n) => n.name == '香港01');
    expect(providerNode.group, '源A');
    expect(providerNode.source, store.data.subscriptions.single.id);
    expect(store.data.nodes.any((n) => n.name.contains('流量')), isFalse);
  });
}
