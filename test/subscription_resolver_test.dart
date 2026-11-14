import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/services/subscription_fetcher.dart';
import 'package:tokiboshi/services/subscription_resolver.dart';
import 'fake_bridge.dart';

class ContentBridge extends FakeBridge {
  ContentBridge(this.outcomes);
  final Map<String, ParseOutcome> outcomes;
  @override
  Future<ParseOutcome> parseSubscription(String text) async => outcomes[text]!;
}

void main() {
  test('recursive providers preserve same-name nodes beyond former limits', () async {
    final providers = [for (var i = 0; i < 15; i++)
      ProviderInfo(name: 'source$i', url: 'https://test.example/p$i')];
    final fetcher = FakeFetcher({'https://test.example/root': 'root',
      for (var i = 0; i < 15; i++) 'https://test.example/p$i': 'p$i',
      'https://test.example/leaf': 'leaf'});
    final bridge = ContentBridge({
      'root': ParseOutcome(nodes: const [], providers: providers),
      for (var i = 0; i < 15; i++) 'p$i': const ParseOutcome(nodes: [], providers: [
        ProviderInfo(name: 'nested', url: 'https://test.example/leaf')]),
      'leaf': const ParseOutcome(nodes: [NodeInfo(name: 'same', outboundJson: '{}')]),
    });
    final result = await SubscriptionResolver(bridge: bridge, fetcher: fetcher)
        .resolve('https://test.example/root');
    expect(result.nodes, hasLength(15));
    expect(result.nodes.map((n) => n.group).toSet(), hasLength(15));
    expect(fetcher.requested.where((u) => u.endsWith('/leaf')), hasLength(1));
    expect(result.skipped, isEmpty);
  });

  test('cycles, failed sources and invalid filters are visible', () async {
    final fetcher = FakeFetcher({'https://test.example/root': 'root'});
    final bridge = ContentBridge({'root': const ParseOutcome(nodes: [], providers: [
      ProviderInfo(name: 'cycle', url: 'https://test.example/root'),
      ProviderInfo(name: 'missing', url: 'https://test.example/missing'),
      ProviderInfo(name: 'filter', url: 'https://test.example/root', filter: '['),
    ])});
    final result = await SubscriptionResolver(bridge: bridge, fetcher: fetcher)
        .resolve('https://test.example/root');
    expect(result.skipped, hasLength(3));
    expect(result.skipped.join(), contains('循环'));
    expect(result.skipped.join(), contains('拉取失败'));
    expect(result.skipped.join(), contains('过滤规则无效'));
  });
}
