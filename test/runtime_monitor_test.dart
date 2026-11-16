import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/services/clash_api.dart';
import 'package:tokiboshi/ui/runtime.dart';
import 'package:tokiboshi/ui/preferences.dart';
import 'package:tokiboshi/ui/diagnostics.dart';

void main() {
  test('appearance validates layout without invalidating legacy settings', () {
    final prefs = UiPreferences.fromJson({
      'order': ['runtime', 'runtime', 'status', 'unknown', 'traffic'],
      'motion': 'bad',
      'light': 'bad'
    });
    expect(prefs.order, ['status', 'runtime', 'traffic', 'profile']);
    expect(prefs.motion, 'full');
    expect(prefs.light, false);
    expect(UiPreferences.fromJson(null).order.first, 'status');
    expect(prefs.copyWith(light: true).toJson()['light'], true);
  });
  test(
      'diagnostic export strips ANSI, URL credentials, share links and named tokens',
      () {
    const text =
        '\x1b[31mERROR https://user:pass@example.test/private?token=fixture-secret password=abc uuid=abcdef vless://credential@server.test:443#name';
    final safe = redactDiagnostics(text);
    for (final secret in [
      'fixture-secret',
      'user:pass',
      'password=abc',
      'abcdef',
      'credential',
      '\x1b'
    ]) {
      expect(safe, isNot(contains(secret)));
    }
    expect(safe, contains('example.test'));
    expect(safe, contains('ERROR'));
  });
  test(
      'controller authenticates, samples real totals, closes connections and resets safely',
      () => HttpOverrides.runWithHttpOverrides(() async {
            final server =
                await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            var download = 1024, upload = 512, deleted = false;
            final auth = <String?>[];
            final serving = server.listen((request) async {
              auth.add(request.headers.value(HttpHeaders.authorizationHeader));
              request.response.headers.contentType = ContentType.json;
              if (request.method == 'DELETE') {
                deleted = true;
                request.response.statusCode = 204;
              } else if (request.uri.path == '/rules') {
                request.response.write(jsonEncode({
                  'rules': [
                    {
                      'type': 'DomainSuffix',
                      'payload': 'example.test',
                      'proxy': 'DIRECT'
                    }
                  ]
                }));
              } else {
                request.response.write(jsonEncode({
                  'downloadTotal': download,
                  'uploadTotal': upload,
                  'connections': deleted
                      ? []
                      : [
                          {
                            'id': 'test-id',
                            'metadata': {'host': 'example.test'}
                          }
                        ]
                }));
              }
              await request.response.close();
            });
            final monitor = RuntimeMonitor();
            final api =
                ClashApiClient(port: server.port, secret: 'synthetic-bearer');
            try {
              final ready = Completer<void>();
              monitor.addListener(() {
                if (monitor.available && !ready.isCompleted) ready.complete();
              });
              monitor.configure(
                  running: true, port: server.port, secret: 'synthetic-bearer');
              await ready.future.timeout(const Duration(seconds: 3));
              expect(monitor.download, 1024);
              expect(monitor.connections.length, 1);
              expect(monitor.downSpeed, 0);
              await Future<void>.delayed(const Duration(milliseconds: 20));
              download += 2048;
              upload += 1024;
              await monitor.sample();
              expect(monitor.downSpeed, greaterThan(0));
              expect(monitor.upSpeed, greaterThan(0));
              expect(monitor.downHistory.length, 2);
              await monitor.closeConnections('test-id');
              expect(deleted, true);
              expect(monitor.connections, isEmpty);
              expect((await api.rules()).single['proxy'], 'DIRECT');
              expect(auth, everyElement('Bearer synthetic-bearer'));
              download = 0;
              upload = 0;
              await monitor.sample();
              expect(monitor.downSpeed, 0);
              monitor.configure(
                  running: false,
                  port: server.port,
                  secret: 'synthetic-bearer');
              expect(monitor.available, false);
              expect(monitor.startedAt, isNull);
              expect(monitor.downSpeed, 0);
            } finally {
              monitor.dispose();
              api.close();
              await serving.cancel();
              await server.close(force: true);
            }
          }, _RealHttp()));
}

class _RealHttp extends HttpOverrides {}
