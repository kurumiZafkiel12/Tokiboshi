import 'dart:convert';
import 'dart:io';
import 'routing_targets.dart';

/// Desktop policies are applied only when the next core configuration is built.
class RoutingRule {
  const RoutingRule({
    required this.kind,
    required this.value,
    this.target = 'proxy',
    this.enabled = true,
  });
  final String kind, value, target;
  final bool enabled;
  static const kinds = {
    'domain': '完整域名',
    'domain_suffix': '域名后缀',
    'domain_keyword': '域名关键词',
    'ip_cidr': 'IP 网段',
    'process_name': '进程名称',
    'port': '目标端口',
  };
  void validate() {
    // target：proxy/direct/reject 或节点名（生成时经 tagByName 映射为 TAG，
    // 用户需求"按软件分流、单独设置出口节点"）。
    if (!kinds.containsKey(kind) ||
        target.trim().isEmpty ||
        target.length > (target.startsWith('node:') ? 4096 : 512) ||
        target.contains(RegExp(r'[\x00-\x1f]')))
      throw const FormatException('不支持的规则类型或出站目标');
    if (value.trim().isEmpty ||
        value.length > 512 ||
        value.contains(RegExp(
            kind == 'process_name' ? r'[\x00-\x1f/\\]' : r'[\s\x00-\x1f]')))
      throw const FormatException('规则内容不能为空或含空白/控制字符');
    if (kind == 'port' &&
        ((int.tryParse(value) ?? 0) < 1 ||
            (int.tryParse(value) ?? 65536) > 65535))
      throw const FormatException('端口范围为 1–65535');
    if (kind == 'ip_cidr') {
      final parts = value.split('/');
      final address = InternetAddress.tryParse(parts.first);
      final prefix = parts.length == 2 ? int.tryParse(parts[1]) : null;
      if (address == null ||
          prefix == null ||
          prefix < 0 ||
          prefix > (address.type == InternetAddressType.IPv4 ? 32 : 128))
        throw const FormatException('请填写有效的 IPv4/IPv6 网段，例如 192.168.1.0/24');
    }
    if (kind.startsWith('domain') &&
        (value.contains('://') || value.contains('/') || value.contains('*')))
      throw const FormatException('请输入域名或后缀，不包含协议、路径或通配符');
  }

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'value': value,
        'target': target,
        'enabled': enabled,
      };
  factory RoutingRule.fromJson(Map value) => RoutingRule(
        kind: value['kind'] as String,
        value: value['value'] as String,
        target: value['target'] as String? ?? 'proxy',
        enabled: value['enabled'] as bool? ?? true,
      );
  Map<String, dynamic> get config {
    validate();
    return {
      kind: [kind == 'port' ? int.parse(value) : value.trim()],
      if (target == 'reject')
        'action': 'reject'
      else ...{
        'action': 'route',
        'outbound': target,
      },
    };
  }
}

class ClientPreferences {
  const ClientPreferences({
    this.rules = const [],
    this.dnsEnabled = false,
    this.dnsEndpoint = 'https://1.1.1.1/dns-query',
    this.dnsViaProxy = true,
    this.testUrl = 'https://www.gstatic.com/generate_204',
    this.testTimeoutMs = 5000,
  });
  final List<RoutingRule> rules;
  final bool dnsEnabled, dnsViaProxy;
  final String dnsEndpoint, testUrl;
  final int testTimeoutMs;
  ClientPreferences withRules(List<RoutingRule> value) => ClientPreferences(
        rules: value,
        dnsEnabled: dnsEnabled,
        dnsEndpoint: dnsEndpoint,
        dnsViaProxy: dnsViaProxy,
        testUrl: testUrl,
        testTimeoutMs: testTimeoutMs,
      );

  void validate() {
    if (rules.length > 500) throw const FormatException('自定义规则最多 500 条');
    for (final rule in rules) {
      rule.validate();
    }
    final test = Uri.tryParse(testUrl);
    if (test == null ||
        !['http', 'https'].contains(test.scheme) ||
        test.host.isEmpty ||
        test.userInfo.isNotEmpty ||
        test.fragment.isNotEmpty)
      throw const FormatException('测速地址需为有效 HTTP(S) 地址');
    if (testTimeoutMs < 1000 || testTimeoutMs > 30000)
      throw const FormatException('测速超时范围为 1000–30000 毫秒');
    if (dnsEnabled) dnsServer();
  }

  Map<String, dynamic> dnsServer() {
    final uri = Uri.tryParse(dnsEndpoint.trim());
    if (uri == null ||
        !['https', 'tls', 'tcp', 'udp'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535)) ||
        (uri.scheme != 'https' && (uri.path.isNotEmpty || uri.hasQuery)))
      throw const FormatException('DNS 地址支持 https://、tls://、tcp://、udp://');
    return {
      'type': uri.scheme,
      'tag': 'dns-remote',
      'server': uri.host,
      if (uri.hasPort) 'server_port': uri.port,
      if (uri.scheme == 'https')
        'path':
            '${uri.path.isEmpty ? '/dns-query' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}',
      if (InternetAddress.tryParse(uri.host) == null)
        'domain_resolver': 'dns-local',
      if (dnsViaProxy) 'detour': 'proxy',
    };
  }

  Map<String, dynamic> toJson() => {
        'rules': rules.map((r) => r.toJson()).toList(),
        'dnsEnabled': dnsEnabled,
        'dnsEndpoint': dnsEndpoint,
        'dnsViaProxy': dnsViaProxy,
        'testUrl': testUrl,
        'testTimeoutMs': testTimeoutMs,
      };
  factory ClientPreferences.fromJson(dynamic raw, {bool strict = false}) {
    if (raw == null) return const ClientPreferences();
    if (raw is! Map) {
      if (strict) throw const FormatException('Invalid client preferences');
      return const ClientPreferences();
    }
    try {
      final value = ClientPreferences(
        rules: (raw['rules'] as List? ?? [])
            .map((r) => RoutingRule.fromJson(r as Map))
            .toList(),
        dnsEnabled: raw['dnsEnabled'] as bool? ?? false,
        dnsEndpoint:
            raw['dnsEndpoint'] as String? ?? 'https://1.1.1.1/dns-query',
        dnsViaProxy: raw['dnsViaProxy'] as bool? ?? true,
        testUrl:
            raw['testUrl'] as String? ?? 'https://www.gstatic.com/generate_204',
        testTimeoutMs: raw['testTimeoutMs'] as int? ?? 5000,
      );
      value.validate();
      return value;
    } catch (_) {
      if (strict) rethrow;
      return const ClientPreferences();
    }
  }
}

String applyClientPreferences(
  String text,
  ClientPreferences preferences, {
  required bool hasProfile,
  Map<String, String> tagByName = const {},
  bool lookupProcesses = false,
}) {
  preferences.validate();
  if (!preferences.rules.any((r) => r.enabled) &&
      !(preferences.dnsEnabled && !hasProfile)) return text;
  final config = jsonDecode(text) as Map<String, dynamic>;
  final route = config['route'] as Map<String, dynamic>;
  final rules = (route['rules'] as List? ?? []).whereType<Map>().toList();
  if (preferences.rules.any((r) => r.enabled)) {
    final outbounds = (config['outbounds'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => row['tag'])
        .whereType<String>()
        .toSet();
    if (lookupProcesses &&
        preferences.rules
            .any((rule) => rule.enabled && rule.kind == 'process_name')) {
      route['find_process'] = true;
    }
    // Preserve mandatory inbound inspection and DNS interception before routing.
    final inboundRules = rules
        .takeWhile((r) => r['action'] == 'sniff' || r['action'] == 'hijack-dns')
        .toList();
    final routingRules = rules.skip(inboundRules.length);
    // Mode overrides precede user rules. User rules precede template/profile rules.
    route['rules'] = [
      ...inboundRules,
      ...routingRules.where((r) => r.containsKey('clash_mode')),
      ...preferences.rules.where((r) => r.enabled).map((r) {
        final rule = Map<String, dynamic>.from(r.config);
        final outbound = rule['outbound'];
        if (outbound is String) {
          applyRouteTarget(rule, outbound, tagByName, outbounds);
        }
        return rule;
      }),
      ...routingRules.where((r) => !r.containsKey('clash_mode')),
    ];
  }
  if (preferences.dnsEnabled && !hasProfile) {
    final dns = config['dns'] as Map<String, dynamic>;
    dns['servers'] = [
      for (final item in dns['servers'] as List)
        if (item['tag'] != 'dns-remote') item,
      preferences.dnsServer(),
    ];
  }
  return jsonEncode(config);
}
