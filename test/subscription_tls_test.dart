import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/services/subscription_fetcher.dart';

void main() {
  final path = Platform.environment['TOKIBOSHI_TLS_TEST_DIR'];
  test(
      'TLS verification defaults to rejection and explicit disabled mode allows the self-signed fixture',
      () => HttpOverrides.runWithHttpOverrides(() async {
            final context = SecurityContext()
              ..useCertificateChain('$path/cert.pem')
              ..usePrivateKey('$path/key.pem');
            final server = await HttpServer.bindSecure(
                InternetAddress.loopbackIPv4, 0, context);
            final agents = <String?>[];
            final listener = server.listen((request) async {
              agents.add(request.headers.value(HttpHeaders.userAgentHeader));
              request.response.write('fixture-subscription');
              await request.response.close();
            }, onError: (_) {});
            final url = 'https://127.0.0.1:${server.port}/sub';
            try {
              await expectLater(const HttpSubscriptionFetcher().fetch(url),
                  throwsA(isA<HandshakeException>()));
              expect(
                  await const HttpSubscriptionFetcher(
                          verifyTls: false, userAgent: 'Tokiboshi-fixture-UA')
                      .fetch(url),
                  'fixture-subscription');
              expect(agents.last, 'Tokiboshi-fixture-UA');
              expect(
                  await const HttpSubscriptionFetcher(
                          verifyTls: false, userAgent: 'default-fixture')
                      .fetch(url, userAgent: 'provider-specific-UA'),
                  'fixture-subscription');
              expect(agents.last, 'provider-specific-UA');
            } finally {
              await listener.cancel();
              await server.close(force: true);
            }
          }, _NativeHttp()),
      skip: path == null);
}

class _NativeHttp extends HttpOverrides {}
