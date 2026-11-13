import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';

void main() {
  group('LocalCoreBridge (mirrors rust/src/config.rs)', () {
    final bridge = LocalCoreBridge();

    test('rejects invalid JSON', () {
      expect(bridge.validateConfig('{nope'), hasLength(1));
    });

    test('rejects missing outbounds', () {
      expect(
        bridge.validateConfig('{}'),
        contains('missing "outbounds"'),
      );
    });

    test('builds config with proxy and direct', () {
      final text = bridge.buildConfig(
        outboundJson:
            '{"type":"hysteria2","server":"example.com","server_port":443,"password":"x"}',
      );
      expect(bridge.validateConfig(text), isEmpty);
      expect(text, contains('"tag": "proxy"'));
      expect(text, contains('"listen_port": 7890'));
    });

    test('start/stop lifecycle', () async {
      final b = LocalCoreBridge();
      final config = b.buildConfig(outboundJson: '{"type":"direct"}');
      await b.start(config);
      expect(b.state, CoreState.running);
      await expectLater(b.start(config), throwsStateError);
      await b.stop();
      expect(b.state, CoreState.stopped);
    });
  });
}
