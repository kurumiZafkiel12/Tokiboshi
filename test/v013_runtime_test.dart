import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/services/asn_lookup.dart';
import 'package:tokiboshi/services/client_preferences.dart';
import 'package:tokiboshi/services/connection_topology.dart';
import 'package:tokiboshi/services/desktop_settings.dart';
import 'package:tokiboshi/services/routing_targets.dart';
import 'package:tokiboshi/services/service_audit.dart';

void main() {
  test(
      'application routes resolve independent same-name endpoints and honor mode',
      () {
    const name = '东京 01';
    final targets = RoutingTargets([
      for (final source in ['A', 'B'])
        NodeInfo(
            name: name,
            source: source,
            outboundJson:
                '{"type":"socks","server":"example.test","server_port":443}'),
    ]);
    final second = routeNodeReference(targets.available[1]);
    final config = jsonEncode({
      'outbounds': [
        {'tag': name},
        {'tag': '$name-2'},
        {'tag': 'proxy'}
      ],
      'route': {
        'rules': [
          {'action': 'hijack-dns'},
          {'clash_mode': 'Global', 'outbound': 'proxy'},
        ]
      },
    });
    final result = jsonDecode(applyClientPreferences(
        config,
        ClientPreferences(rules: [
          RoutingRule(
              kind: 'process_name', value: 'Example App.exe', target: second),
          const RoutingRule(
              kind: 'process_name', value: 'Other.exe', target: name),
        ]),
        hasProfile: false,
        tagByName: targets.resolved,
        lookupProcesses: true));
    expect(result['route']['find_process'], true);
    final rules = result['route']['rules'] as List;
    expect(rules[0]['action'], 'hijack-dns');
    expect(rules[1]['clash_mode'], 'Global');
    expect(rules[2]['outbound'], '$name-2');
    expect(rules[3]['action'], 'reject');
    expect(rules[3].containsKey('outbound'), false);
  });

  test(
      'upgraded installations auto-connect until the new preference is changed',
      () {
    expect(DesktopSettings.fromJson({'autoRun': false}).autoRun, true);
    final settings = const DesktopSettings(autoRun: false).toJson();
    expect(DesktopSettings.fromJson(settings).autoRun, false);
  });

  test(
      'closing a connection cannot subtract another connection’s interval bytes',
      () {
    final sampler = ConnectionRateSampler();
    Map<String, dynamic> row(String id, int total) => {
          'id': id,
          'upload': 0,
          'download': total,
          'chains': ['active-outbound', 'proxy'],
          'metadata': {'sourcePort': 5555, 'destinationPort': 443},
        };
    sampler.update([row('A', 5000), row('B', 10)], Duration.zero);
    final next = [row('B', 210)];
    final rates = sampler.update(next, const Duration(seconds: 1));
    final topology = ConnectionTopology(next, byIp: false, deltas: rates);
    expect(topology.rates[(1, 'active-outbound')], (0.0, 200.0));
    expect(sampler.update(next, const Duration(seconds: 2)), rates);
    expect(sampler.update([row('B', 1)], const Duration(seconds: 3)), isEmpty);
  });

  test('ASN excludes private and reserved addresses and handles public IPv6',
      () {
    for (final ip in [
      '10.0.0.1',
      '100.64.0.1',
      '::1',
      'fc00::1',
      '2001:db8::1',
      '192.0.2.1'
    ]) {
      expect(isPublicAsnAddress(ip), false, reason: ip);
    }
    expect(isPublicAsnAddress('2001:4860:4860::8888'), true);
    expect(isPublicAsnAddress('1.1.1.1'), true);
    expect(
        parseAsnOrigins({
          'data': {
            'asns': [
              {'asn': 13335, 'holder': 'Fixture'}
            ]
          }
        }),
        [(13335, 'Fixture')]);
  });

  test(
      'service HTTP success alone does not prove Netflix playback or unblocking',
      () {
    const good = ServiceEvidence(200, '{"isPlayable":true}', 10);
    expect(classifyNetflixCatalog(const ServiceEvidence(200, 'HTML', 10), good),
        '片库未确认');
    expect(classifyNetflixCatalog(good, const ServiceEvidence(404, '', 10)),
        '仅原创样本可用');
    expect(
        classifyService(const ServiceEvidence(200, 'unsupported_country', 10)),
        '地区受限');
    expect(
        classifyService(const ServiceEvidence(403, 'cf-chl-test', 10)), '验证挑战');
    expect(classifyService(const ServiceEvidence(401, '', 10)), '需要登录或 API 密钥');
  });
}
