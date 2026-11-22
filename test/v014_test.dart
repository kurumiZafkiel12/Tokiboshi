import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/services/node_selection.dart';
import 'package:tokiboshi/services/quality_history.dart';

void main() {
  const a = NodeInfo(
      name: 'A',
      source: 's',
      outboundJson: '{"type":"http","server":"a","server_port":80}');
  test('diff counts duplicate entries and a unique renamed endpoint', () {
    expect(subscriptionChanges([a, a], [a, a.withName('new')]),
        (added: 0, changed: 1, removed: 0));
    expect(
        subscriptionChanges([a], [a, a]), (added: 1, changed: 0, removed: 0));
  });
  test(
      'completed quality round survives reopening and isolates sources and endpoints',
      () async {
    final dir = Directory.systemTemp.createTempSync();
    addTearDown(() => dir.deleteSync(recursive: true));
    final history = QualityHistory(dir);
    final key = history.key(a, 'https://example.org/test', 5000);
    await history.save(key, [2, null, 4, 5, 1]);
    final reopened = QualityHistory(dir);
    expect(reopened.lookup(key)?.samples, [2, null, 4, 5, 1]);
    expect(
        reopened.lookup(history.key(
            a.withSource('other'), 'https://example.org/test', 5000)),
        isNull);
    expect(reopened.lookup(history.key(a, 'https://example.net/test', 5000)),
        isNull);
  });
}
