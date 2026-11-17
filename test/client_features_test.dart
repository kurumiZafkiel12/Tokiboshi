import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/services/client_preferences.dart';
import 'package:tokiboshi/services/config_backup.dart';
import 'package:tokiboshi/services/desktop_settings.dart';
import 'package:tokiboshi/services/node_selection.dart';
import 'package:tokiboshi/services/store.dart';
import 'package:tokiboshi/services/clash_api.dart';

NodeInfo node(String name, String password,
        {String source = 's', int port = 1080}) =>
    NodeInfo(
        name: name,
        source: source,
        outboundJson: jsonEncode({
          'type': 'socks',
          'server': '127.0.0.1',
          'server_port': port,
          'password': password
        }));
void main() {
  test(
      'update restores renamed/reordered nodes by content and never by ambiguous names',
      () {
    final old = node('same', 'a');
    expect(
        restoredNodeIndex(
            old, [old], [node('same', 'b', port: 1081), node('renamed', 'a')]),
        1);
    expect(
        restoredNodeIndex(
            old, [old, node('other', 'b')], [node('same', 'rotated')]),
        -1);
    expect(restoredNodeIndex(old, [old], [node('same', 'b', source: 'other')]),
        -1);
    expect(restoredNodeIndex(old, [old], [node('renamed', 'rotated')]), 0);
  });
  test(
      'real store roundtrip preserves refresh failures and desktop routing policies',
      () async {
    final dir = await Directory.systemTemp.createTemp('tkb-client-store-');
    addTearDown(() => dir.delete(recursive: true));
    final data = AppData(nodes: [
      node('fixture', 'synthetic')
    ], subscriptions: [
      const Subscription(
          id: 's',
          name: 'fixture',
          url: 'https://fixture.example/sub',
          refreshMinutes: 360,
          lastError: 'synthetic failure',
          lastAttemptAt: '2026-01-01')
    ]);
    data.client = const ClientPreferences(rules: [
      RoutingRule(kind: 'domain_suffix', value: 'example.com', target: 'reject')
    ], dnsEnabled: true);
    final store = Store(File('${dir.path}/data.json'));
    await store.save(data);
    final loaded = await store.load();
    expect(loaded.subscriptions.single.refreshMinutes, 360);
    expect(loaded.subscriptions.single.lastError, 'synthetic failure');
    expect(loaded.client.rules.single.target, 'reject');
    expect(loaded.client.dnsEnabled, true);
  });
  test('invalid saved routing policies recover the last valid backup',
      () async {
    final dir = await Directory.systemTemp.createTemp('tkb-policy-recovery-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/data.json');
    final data = AppData();
    data.client = const ClientPreferences(rules: [
      RoutingRule(kind: 'domain_suffix', value: 'example.com', target: 'reject')
    ]);
    await File('${file.path}.bak')
        .writeAsString(jsonEncode(Store.encodeData(data)));
    final bad = Store.encodeData(data);
    bad['client'] = {
      'rules': [
        {'kind': 'port', 'value': '70000'}
      ]
    };
    await file.writeAsString(jsonEncode(bad));
    final restored = await Store(file).load();
    expect(restored.client.rules.single.target, 'reject');
    expect(
        Store.decodeData(await file.readAsString())!.client.rules.single.target,
        'reject');
  });
  test(
      'backup restore retains data but never imports executable/startup/session identity',
      () {
    final backup = AppData(
        nodes: [
          node('fixture', 'synthetic')
        ],
        subscriptions: [
          const Subscription(
              id: 's', name: 'fixture', url: 'https://fixture.example/sub')
        ],
        selectedIndex: 0,
        singBoxPath: 'untrusted.exe',
        clashApiSecret: 'foreign',
        resumeConnect: true,
        runningAtExit: true,
        desktop: const DesktopSettings(
            autoRun: true, onDemand: true, launchAtLogin: true));
    final current = AppData(
        singBoxPath: 'local-managed.exe', clashApiSecret: 'local-secret');
    final restored = decodeBackup(encodeBackup(backup), current);
    expect(restored.nodes.single.name, 'fixture');
    expect(restored.singBoxPath, current.singBoxPath);
    expect(restored.clashApiSecret, 'local-secret');
    expect(restored.resumeConnect, false);
    expect(restored.runningAtExit, false);
    expect(restored.desktop.autoRun, false);
    expect(restored.desktop.onDemand, false);
    expect(restored.desktop.launchAtLogin, false);
  });
  test(
      'backup rejects damaged rules, invalid active references and unsupported schemas',
      () {
    final data = AppData(nodes: [
      node('fixture', 'synthetic')
    ], subscriptions: [
      const Subscription(
          id: 's', name: 'fixture', url: 'https://fixture.example/sub')
    ], selectedIndex: 0);
    final root = jsonDecode(encodeBackup(data)) as Map<String, dynamic>;
    root['data']['client']['rules'] = [
      {'kind': 'port', 'value': '70000'}
    ];
    expect(
        () => decodeBackup(jsonEncode(root), AppData()), throwsFormatException);
    root['data']['client']['rules'] = [];
    root['data']['activeProfileId'] = 'missing';
    expect(
        () => decodeBackup(jsonEncode(root), AppData()), throwsFormatException);
    expect(() => decodeBackup('{}', AppData()), throwsFormatException);
  });
  test(
      'custom rules preserve mode precedence and subscriber DNS while template override is explicit',
      () {
    final config = jsonEncode({
      'route': {
        'rules': [
          {'ip_is_private': true, 'outbound': 'direct'},
          {'clash_mode': 'Global', 'outbound': 'proxy'}
        ]
      },
      'dns': {
        'servers': [
          {'type': 'local', 'tag': 'dns-local'},
          {'type': 'https', 'tag': 'dns-remote', 'server': '8.8.8.8'}
        ],
        'rules': [
          {
            'server': 'dns-local',
            'domain_suffix': ['cn']
          }
        ],
        'final': 'dns-remote'
      }
    });
    const prefs = ClientPreferences(rules: [
      RoutingRule(kind: 'ip_cidr', value: '10.0.0.0/8', target: 'reject')
    ], dnsEnabled: true, dnsEndpoint: 'https://dns.google/dns-query');
    final template =
        jsonDecode(applyClientPreferences(config, prefs, hasProfile: false));
    expect(template['route']['rules'][0]['clash_mode'], 'Global');
    expect(template['route']['rules'][1]['action'], 'reject');
    expect(template['dns']['servers'].last['domain_resolver'], 'dns-local');
    expect(template['dns']['rules'], hasLength(1));
    final profile =
        jsonDecode(applyClientPreferences(config, prefs, hasProfile: true));
    expect(profile['dns'], jsonDecode(config)['dns']);
  });
  test('rules reject invalid masks, schemes, ports and header-like input', () {
    for (final r in [
      const RoutingRule(kind: 'ip_cidr', value: '1.2.3.4/33'),
      const RoutingRule(kind: 'port', value: '0'),
      const RoutingRule(kind: 'domain_suffix', value: 'https://example.com'),
      const RoutingRule(kind: 'process_name', value: 'bad\nprocess')
    ]) {
      expect(r.validate, throwsFormatException);
    }
    expect(const ClientPreferences(testUrl: 'file:///tmp/data').validate,
        throwsFormatException);
    expect(
        const ClientPreferences(
                dnsEnabled: true,
                dnsEndpoint: 'https://user:secret@dns.example/query')
            .validate,
        throwsFormatException);
  });
  final binary = Platform.environment['SING_BOX'];
  test('real core validates all four supported custom DNS transports',
      () async {
    final dir = await Directory.systemTemp.createTemp('tkb-dns-check-');
    addTearDown(() => dir.delete(recursive: true));
    final raw = jsonEncode({
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
        {'type': 'direct', 'tag': 'proxy'}
      ],
      'route': {
        'rules': [],
        'final': 'proxy',
        'default_domain_resolver': 'dns-remote'
      },
      'dns': {
        'servers': [
          {'type': 'local', 'tag': 'dns-local'},
          {'type': 'https', 'server': '1.1.1.1', 'tag': 'dns-remote'}
        ],
        'final': 'dns-remote'
      }
    });
    for (final endpoint in [
      'https://dns.example/dns-query',
      'tls://1.1.1.1',
      'tcp://127.0.0.1:5353',
      'udp://127.0.0.1:5353'
    ]) {
      final config = applyClientPreferences(
          raw, ClientPreferences(dnsEnabled: true, dnsEndpoint: endpoint),
          hasProfile: false);
      final file = File('${dir.path}/config.json');
      await file.writeAsString(config);
      final result = await Process.run(binary!, ['check', '-c', file.path]);
      expect(result.exitCode, 0, reason: '$endpoint: ${result.stderr}');
    }
  },
      skip: binary == null
          ? 'Set SING_BOX for actual DNS config validation'
          : false);
  test(
      'real core enforces custom reject before private bypass and Global mode still overrides it',
      () => HttpOverrides.runWithHttpOverrides(() async {
            final directory =
                await Directory.systemTemp.createTemp('tkb-custom-rules-');
            final origin =
                await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            var originRequests = 0;
            origin.listen((r) {
              originRequests++;
              r.response.write('TOKIBOSHI_CUSTOM_DIRECT');
              r.response.close();
            });
            Future<int> port() async {
              final s =
                  await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
              final p = s.port;
              await s.close();
              return p;
            }

            final mixed = await port(), apiPort = await port();
            final raw = jsonEncode({
              'log': {'level': 'error'},
              'inbounds': [
                {
                  'type': 'mixed',
                  'tag': 'mixed-in',
                  'listen': '127.0.0.1',
                  'listen_port': mixed
                }
              ],
              'outbounds': [
                {'type': 'direct', 'tag': 'direct'},
                {'type': 'direct', 'tag': 'proxy'}
              ],
              'route': {
                'rules': [
                  {'clash_mode': 'Direct', 'outbound': 'direct'},
                  {'clash_mode': 'Global', 'outbound': 'proxy'},
                  {'ip_is_private': true, 'outbound': 'direct'}
                ],
                'final': 'proxy'
              },
              'experimental': {
                'clash_api': {
                  'external_controller': '127.0.0.1:$apiPort',
                  'secret': 'synthetic-only'
                }
              }
            });
            final text = applyClientPreferences(
                raw,
                const ClientPreferences(rules: [
                  RoutingRule(
                      kind: 'ip_cidr', value: '127.0.0.1/32', target: 'reject')
                ]),
                hasProfile: false);
            final file = File('${directory.path}/config.json');
            await file.writeAsString(text);
            final check =
                await Process.run(binary!, ['check', '-c', file.path]);
            expect(check.exitCode, 0, reason: '${check.stderr}');
            final process =
                await Process.start(binary, ['run', '-c', file.path]);
            process.stdout.drain<void>();
            process.stderr.drain<void>();
            final api = ClashApiClient(port: apiPort, secret: 'synthetic-only');
            addTearDown(() async {
              api.close();
              process.kill();
              await process.exitCode.timeout(const Duration(seconds: 5));
              await origin.close(force: true);
              await directory.delete(recursive: true);
            });
            var ready = false;
            for (var i = 0; i < 100; i++) {
              try {
                await api.version();
                ready = true;
                break;
              } catch (_) {
                await Future<void>.delayed(const Duration(milliseconds: 40));
              }
            }
            expect(ready, true);
            Future<String> request() async {
              final client = HttpClient()
                ..findProxy = (_) => 'PROXY 127.0.0.1:$mixed';
              try {
                final r = await client.getUrl(
                    Uri.parse('http://127.0.0.1:${origin.port}/fixture'));
                r.persistentConnection = false;
                final response =
                    await r.close().timeout(const Duration(seconds: 3));
                return await response.transform(utf8.decoder).join();
              } catch (_) {
                return 'REJECTED';
              } finally {
                client.close(force: true);
              }
            }

            expect(await request(), isNot(contains('TOKIBOSHI_CUSTOM_DIRECT')));
            expect(originRequests, 0);
            await api.setMode('Global');
            expect(await request(), contains('TOKIBOSHI_CUSTOM_DIRECT'));
            expect(originRequests, 1);
          }, _NativeHttp()),
      skip: binary == null
          ? 'Set SING_BOX for actual core routing validation'
          : false);
}

class _NativeHttp extends HttpOverrides {}
