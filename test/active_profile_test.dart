import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/services/active_profile.dart';
import 'package:tokiboshi/services/store.dart';

void main() {
  const a = Subscription(
      id: 'a', name: 'same', url: 'https://a.example.test', profileJson: '{}');
  const b = Subscription(
      id: 'b', name: 'same', url: 'https://b.example.test', profileJson: '{}');
  const n1 = NodeInfo(name: 'same-node', outboundJson: '{}', source: 'a');
  const n2 = NodeInfo(name: 'same-node', outboundJson: '{}', source: 'b');
  test(
      'legacy unique profile infers only one source; ambiguity never chooses first',
      () {
    final data = AppData(subscriptions: [a], nodes: [n1, n2]);
    expect(activeProfile(data)?.id, 'a');
    expect(profileNodes(data), [n1]);
    data.subscriptions = [a, b];
    expect(() => activeProfile(data), throwsFormatException);
    data.activeProfileId = 'b';
    expect(activeProfile(data)?.id, 'b');
    expect(profileNodes(data), [n2]);
    data.activeProfileId = '';
    expect(activeProfile(data), isNull);
    expect(profileNodes(data), [n1, n2]);
  });
  test(
      'deleted or node-only active source requires explicit selection; snapshot preserves identity',
      () {
    final data = AppData(activeProfileId: 'b', subscriptions: [a, b]);
    final saved = data.copyWith();
    data.subscriptions = [a];
    expect(() => activeProfile(data), throwsFormatException);
    expect(saved.activeProfileId, 'b');
    data.subscriptions = [
      a,
      const Subscription(
          id: 'b', name: 'node-only', url: 'https://b.example.test')
    ];
    expect(() => activeProfile(data), throwsFormatException);
  });
}
