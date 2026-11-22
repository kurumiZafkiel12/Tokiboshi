import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/services/clash_api.dart';
import 'package:tokiboshi/services/client_preferences.dart';
import 'package:tokiboshi/services/routing_targets.dart';

Future<int> freePort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

Future<void> main() async {
  if (!Platform.isWindows)
    throw StateError('This probe uses Windows process lookup');
  final binary = Platform.environment['SING_BOX'];
  if (binary == null) throw StateError('SING_BOX is required');
  final direct = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final routed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final inbound = await freePort();
  final controller = await freePort();
  if (inbound == controller) throw StateError('Fixture ports overlap');
  final directory =
      await Directory.systemTemp.createTemp('tokiboshi-v013-route');
  final log = StringBuffer();
  final nodes = [
    for (final (source, port) in [
      ('first', direct.port),
      ('second', routed.port)
    ])
      NodeInfo(
          name: 'Same name',
          source: source,
          outboundJson: jsonEncode(
              {'type': 'socks', 'server': '127.0.0.1', 'server_port': port})),
  ];
  final tags = RoutingTargets(nodes).resolved;
  String tag(NodeInfo node) => tags[routeNodeReference(node)]!;
  final raw = jsonEncode({
    'log': {'level': 'debug'},
    'inbounds': [
      {
        'type': 'mixed',
        'tag': 'fixture',
        'listen': '127.0.0.1',
        'listen_port': inbound
      }
    ],
    'outbounds': [
      for (final node in nodes) {...node.outbound, 'tag': tag(node)},
      {
        'type': 'selector',
        'tag': 'proxy',
        'outbounds': [tag(nodes[0])]
      },
    ],
    'route': {
      'rules': [
        {'clash_mode': 'Global', 'outbound': 'proxy'}
      ],
      'final': 'proxy'
    },
    'experimental': {
      'clash_api': {
        'external_controller': '127.0.0.1:$controller',
        'secret': 'fixture-admin-test'
      }
    },
  });
  final config = applyClientPreferences(
      raw,
      ClientPreferences(rules: [
        RoutingRule(
            kind: 'process_name',
            value: 'CURL.EXE',
            target: routeNodeReference(nodes[1])),
      ]),
      hasProfile: false,
      lookupProcesses: true,
      tagByName: tags);
  final path = '${directory.path}${Platform.pathSeparator}config.json';
  await File(path).writeAsString(config);
  final check = await Process.run(binary, ['check', '-c', path]);
  if (check.exitCode != 0) throw StateError(check.stderr.toString());
  final process = await Process.start(binary, ['run', '-c', path]);
  process.stdout.transform(utf8.decoder).listen(log.write);
  process.stderr.transform(utf8.decoder).listen(log.write);
  final api = ClashApiClient(port: controller, secret: 'fixture-admin-test');

  Future<void> exercise(ServerSocket expected) async {
    final greeting = Completer<void>();
    final listener = expected.listen((socket) {
      socket.first.then((packet) {
        if (packet.isNotEmpty && packet.first == 5) {
          if (!greeting.isCompleted) greeting.complete();
        }
        socket.destroy();
      }, onError: (Object _) {
        socket.destroy();
      });
    });
    final curl = await Process.start('curl.exe', [
      '--silent',
      '--max-time',
      '4',
      '--noproxy',
      '',
      '--proxy',
      'http://127.0.0.1:$inbound',
      'https://routing-fixture.invalid/',
    ]);
    unawaited(curl.stdout.drain<void>());
    unawaited(curl.stderr.drain<void>());
    try {
      await greeting.future.timeout(const Duration(seconds: 6));
    } finally {
      curl.kill();
      await curl.exitCode;
      await listener.cancel();
    }
  }

  try {
    for (var attempt = 0; attempt < 25; attempt++) {
      try {
        await api.mode();
        break;
      } catch (_) {
        if (attempt == 24) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    await exercise(routed);
    stdout.writeln(
        'Rule mode: curl.exe matched the case-insensitive process selector and reached the second same-name endpoint.');
    await api.setMode('Global');
    await exercise(direct);
    stdout.writeln(
        'Global mode: explicit mode retained precedence and used the first endpoint.');
  } catch (_) {
    stderr.writeln(log);
    rethrow;
  } finally {
    api.close();
    process.kill();
    await process.exitCode;
    await direct.close();
    await routed.close();
    await directory.delete(recursive: true);
  }
}
