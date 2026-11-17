// Real DLL + pinned core check for frontend-generated LAN/auth settings.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/bridge/rust_core_bridge.dart';
import 'package:tokiboshi/src/rust/frb_generated.dart';
import 'package:tokiboshi/services/desktop_services.dart';
import 'package:tokiboshi/services/desktop_settings.dart';

Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

Future<void> main() async {
  final env = Platform.environment, out = Directory(env['T069_OUT']!);
  await out.create(recursive: true);
  await RustLib.init(externalLibrary: ExternalLibrary.open(env['T069_DLL']!));
  final bridge = RustCoreBridge();
  final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final serving = origin.listen((r) async {
    r.response.write('AUTH_ORIGIN_OK');
    await r.response.close();
  });
  final mixed = await freePort(), api = await freePort();
  final config = await bridge.buildConfig(
      nodes: [
        const NodeSpec(
            name: 'fixture',
            outboundJson:
                '{"type":"socks","server":"127.0.0.1","server_port":1}')
      ],
      mixedPort: mixed,
      clashApiPort: api,
      blockAds: false,
      bypassCn: false,
      dataDir: out.path,
      selectedName: 'fixture');
  final generated = applyNetworkSettings(
      injectClashSecret(config, 'synthetic-controller'),
      const DesktopSettings(
          allowLan: true,
          remoteController: true,
          proxyAuth: true,
          proxyUser: 'fixture',
          proxyPassword: 'synthetic-password'));
  final file = File('${out.path}/network-settings-config.json');
  await file.writeAsString(generated);
  final check = await Process.run(env['SING_BOX']!, ['check', '-c', file.path]);
  if (check.exitCode != 0)
    throw StateError(
        'Network settings config failed core check: ${check.stderr}');
  Future<String> request(bool auth) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, mixed,
        timeout: const Duration(seconds: 5));
    unawaited(
        socket.done.then<void>((_) {}, onError: (Object e, StackTrace s) {}));
    socket.write(
        'GET http://127.0.0.1:${origin.port}/ HTTP/1.1\r\nHost: 127.0.0.1:${origin.port}\r\n${auth ? 'Proxy-Authorization: Basic ${base64.encode(utf8.encode('fixture:synthetic-password'))}\r\n' : ''}Connection: close\r\n\r\n');
    final response = <int>[];
    try {
      try {
        await for (final chunk in socket.timeout(const Duration(seconds: 8))) {
          response.addAll(chunk);
        }
      } on SocketException {
        // sing-box may reset after sending the authentication challenge.
        if (response.isEmpty) rethrow;
      }
      return utf8.decode(response);
    } finally {
      socket.destroy();
    }
  }

  try {
    try {
      await bridge.startCore(
          singBoxPath: env['SING_BOX']!, configPath: file.path);
    } catch (_) {
      await File('${out.path}/network-startup-log.json')
          .writeAsString(jsonEncode(await bridge.coreLogs()));
      rethrow;
    }
    final denied = await request(false);
    final accepted = await request(true);
    if (!denied.startsWith('HTTP/1.1 407') ||
        !accepted.contains('AUTH_ORIGIN_OK'))
      throw StateError('Proxy authentication was not enforced');
    final http = HttpClient();
    Future<int> control(bool auth) async {
      final r = await http.getUrl(Uri.parse('http://127.0.0.1:$api/version'));
      if (auth) r.headers.set('Authorization', 'Bearer synthetic-controller');
      final response = await r.close();
      await response.drain<void>();
      return response.statusCode;
    }

    final blocked = await control(false), authorized = await control(true);
    http.close(force: true);
    if (blocked != 401 || authorized != 200)
      throw StateError(
          'Controller authentication was not enforced: $blocked/$authorized');
    await File('${out.path}/network-settings-results.json')
        .writeAsString(jsonEncode({
      'proxyUnauthenticated': 407,
      'proxyAuthenticatedOrigin': true,
      'controllerUnauthenticated': blocked,
      'controllerAuthenticated': authorized,
      'lanMixedBind': (jsonDecode(generated)['inbounds'] as List)
          .firstWhere((v) => v['type'] == 'mixed')['listen'],
      'passed': true
    }));
  } finally {
    await bridge.stopCore();
    await serving.cancel();
    await origin.close(force: true);
    RustLib.dispose();
  }
}

String injectClashSecret(String configJson, String secret) {
  final config = jsonDecode(configJson) as Map<String, dynamic>;
  final experimental = (config['experimental'] as Map<String, dynamic>?) ?? {};
  final api = (experimental['clash_api'] as Map<String, dynamic>?) ?? {};
  api['secret'] = secret;
  experimental['clash_api'] = api;
  config['experimental'] = experimental;
  return jsonEncode(config);
}
