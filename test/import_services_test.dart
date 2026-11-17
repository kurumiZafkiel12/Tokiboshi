import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/services/import_content.dart';
import 'package:tokiboshi/services/import_io.dart';
import 'package:tokiboshi/services/subscription_fetcher.dart';
import 'package:tokiboshi/services/subscription_resolver.dart';
import 'fake_bridge.dart';

Uint8List qrFixture(String text, {bool inverted = false, int rotate = 0}) {
  final matrix = Encoder.encode(text, ErrorCorrectionLevel.h).matrix!;
  final picture =
      img.Image(width: (matrix.width + 8) * 6, height: (matrix.height + 8) * 6);
  img.fill(picture, color: img.ColorRgb8(255, 255, 255));
  for (var y = 0; y < matrix.height; y++) {
    for (var x = 0; x < matrix.width; x++) {
      if (matrix.get(x, y) == 1)
        for (var dy = 0; dy < 6; dy++) {
          for (var dx = 0; dx < 6; dx++) {
            picture.setPixelRgb((x + 4) * 6 + dx, (y + 4) * 6 + dy, 0, 0, 0);
          }
        }
    }
  }
  var output = rotate == 0 ? picture : img.copyRotate(picture, angle: rotate);
  if (inverted) output = img.invert(output);
  return Uint8List.fromList(img.encodePng(output));
}

class CompatibilityBridge extends FakeBridge {
  @override
  Future<ParseOutcome> parseSubscription(String text) async =>
      const ParseOutcome(
          nodes: [
            NodeInfo(
                name: 'valid-node',
                outboundJson:
                    '{"type":"socks","server":"127.0.0.1","server_port":1080}')
          ],
          profileJson:
              '{"unsupported":["dns.enhanced-mode fake-ip"],"rule_sets":[]}');
}

void main() {
  test(
      'URL normalization handles markdown deep links and Base64 without editing credentials',
      () {
    const url = 'https://sub.example.test/?token=a%2Bb&name=x';
    expect(normalizeImportText(' \uFEFF[$url]($url) '), url);
    expect(
        normalizeImportText(
            'clash://install-config?url=${Uri.encodeComponent(url)}'),
        url);
    expect(
        normalizeImportText(
            'sing-box://import-remote-profile?url=${Uri.encodeComponent(url)}'),
        url);
    expect(
        normalizeImportText('sub://${base64.encode(utf8.encode(url))}'), url);
    const text = '{"outbounds":[{"password":"a\u200Bb"}]}';
    expect(normalizeImportText(text), text);
    var nested = url;
    for (var i = 0; i < 10; i++) {
      nested = 'clash://install-config?url=${Uri.encodeComponent(nested)}';
    }
    expect(() => normalizeImportText(nested), throwsFormatException);
    expect(isSubscriptionUrl('https://example.test/x'), true);
    expect(isSubscriptionUrl('ss://example.test'), false);
  });
  test('real QR decoder reads PNG, rotated and inverted QR payloads', () {
    const value = 'ss://YWVzLTEyOC1nY206c3ludGhldGlj@127.0.0.1:8388#fixture';
    for (final variant in [(false, 0), (false, 90), (true, 180)]) {
      expect(
          decodeQrImage(
              qrFixture(value, inverted: variant.$1, rotate: variant.$2)),
          value);
    }
    expect(() => decodeQrImage(Uint8List.fromList([1, 2, 3])),
        throwsFormatException);
  });
  test(
      'incompatible routing carries usable nodes but requires explicit caller decision',
      () async {
    final resolver = SubscriptionResolver(
        bridge: CompatibilityBridge(),
        fetcher: FakeFetcher({'https://example.test/sub': 'full'}));
    try {
      await resolver.resolve('https://example.test/sub');
      fail('must reject full profile');
    } on ProfileCompatibilityException catch (e) {
      expect(e.nodesOnlyOutcome.nodes.single.name, 'valid-node');
      expect(e.nodesOnlyOutcome.profileJson, isNull);
      expect(e.nodesOnlyOutcome.nodesOnly, true);
    }
    final nodeOnly =
        await resolver.resolve('https://example.test/sub', nodesOnly: true);
    expect(nodeOnly.nodes.length, 1);
    expect(nodeOnly.profileJson, isNull);
    expect(nodeOnly.nodesOnly, true);
    final local = await resolver.resolveContent('full', nodesOnly: true);
    expect(local.nodes.single.name, 'valid-node');
  });
  test(
      'import cancellation after network return does not deliver a committable outcome',
      () async {
    var cancelled = false;
    final resolver = SubscriptionResolver(
        bridge: FakeBridge(),
        fetcher: CancelFetcher(() => cancelled = true),
        isCancelled: () => cancelled);
    await expectLater(resolver.resolve('https://example.test/sub'),
        throwsA(isA<ImportCancelled>()));
  });
}

class CancelFetcher implements SubscriptionFetcher {
  CancelFetcher(this.cancel);
  final void Function() cancel;
  @override
  Future<String> fetch(String url, {String? userAgent}) async {
    cancel();
    return 'ss://aes-128-gcm:synthetic@127.0.0.1:8388#fixture';
  }
}
