import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

class RuleResource {
  const RuleResource(this.tag, this.group, this.url);
  final String tag, group, url;

  String path(String dir) =>
      [dir, 'rules', '$tag.srs'].join(Platform.pathSeparator);

  static Future<List<RuleResource>> load() async {
    final items =
        jsonDecode(await rootBundle.loadString('assets/rule-resources.json'))
            as List;
    return items
        .map((r) => RuleResource(r['tag'], r['group'], r['url']))
        .toList();
  }
}

void validateRuleResourceUrl(String input) {
  if (input.isEmpty) return;
  final uri = Uri.tryParse(input);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      input.contains(RegExp(r'\s'))) {
    throw const FormatException('源地址须为有效的 HTTPS URL，不能含账号或片段');
  }
}

bool ruleResourceDue(
    {required bool downloaded,
    required bool pending,
    required String? lastUpdate,
    required DateTime now}) {
  if (!downloaded || pending) return false;
  final updated = DateTime.tryParse(lastUpdate ?? '');
  return updated == null ||
      now.difference(updated) >= const Duration(hours: 24);
}

const routingPresets = {
  'balanced': '均衡',
  'streaming': '流媒体优先',
  'ai': 'AI 服务优先',
  'harden': '净化增强',
};

String applyResourcePreset(
    String raw, String preset, List<RuleResource> catalog, String dataDir) {
  if (!routingPresets.containsKey(preset) || preset == 'balanced') return raw;
  final config = jsonDecode(raw) as Map<String, dynamic>;
  final route = config['route'] as Map<String, dynamic>?;
  if (route == null) return raw;
  final rules = List.of(route['rules'] as List? ?? []);
  final sets = List.of(route['rule_set'] as List? ?? []);
  final existing = sets.whereType<Map>().map((r) => r['tag']).toSet();
  Map<String, dynamic> rule;
  if (preset == 'harden') {
    rule = {
      'domain_suffix': [
        'doubleclick.net',
        'googletagmanager.com',
        'google-analytics.com',
        'app-measurement.com',
        'scorecardresearch.com',
        'quantserve.com'
      ],
      'action': 'reject',
    };
  } else {
    final group = preset == 'streaming' ? '流媒体' : 'AI';
    final selected = <String>[];
    for (final r in catalog.where((r) => r.group == group)) {
      if (!File(r.path(dataDir)).existsSync()) continue;
      var tag = 'tokiboshi-resource-${r.tag}';
      while (!existing.add(tag)) {
        tag += '-local';
      }
      sets.add({
        'type': 'local',
        'tag': tag,
        'format': 'binary',
        'path': r.path(dataDir)
      });
      selected.add(tag);
    }
    if (selected.isEmpty) return raw;
    route['rule_set'] = sets;
    rule = {'rule_set': selected, 'outbound': 'proxy'};
  }
  final index =
      rules.indexWhere((r) => r is! Map || !r.containsKey('clash_mode'));
  rules.insert(index < 0 ? rules.length : index, rule);
  route['rules'] = rules;
  return jsonEncode(config);
}

/// 用户可配置的内置模板路由（2026-11-21 用户需求"为分流搞开关，能单独
/// 设置出口节点"）：在生成的配置上按 [settings] 改写模板规则。
/// key = 规则 id（ads / cn / private）；value：缺失 = 保持默认（启用）；
/// 'off' = 关闭该条；'reject' = 改为拒绝；'direct' / 'proxy' / 节点名 =
/// 改出站（节点名经 [tagByName] 映射为生成配置中的 TAG）。
/// clash_mode 模式规则与订阅自带规则不受影响。
Map<String, dynamic> applyTemplateRouting(
    Map<String, dynamic> config,
    Map<String, String?> settings,
    Map<String, String> tagByName) {
  final route = config['route'];
  if (route is! Map) return config;
  final rules = route['rules'];
  if (rules is! List) return config;
  String? idOf(Map rule) {
    final rs = rule['rule_set'];
    if (rs is List) {
      if (rs.contains('geosite-category-ads-all')) return 'ads';
      if (rs.contains('geosite-cn')) return 'cn';
    }
    if (rule['ip_is_private'] != null) return 'private';
    return null;
  }

  final out = <dynamic>[];
  for (final raw in rules) {
    if (raw is! Map) {
      out.add(raw);
      continue;
    }
    final rule = Map<String, dynamic>.from(raw);
    final id = idOf(rule);
    if (id == null || !settings.containsKey(id)) {
      out.add(rule);
      continue;
    }
    final setting = settings[id];
    if (setting == 'off') continue; // 用户关闭该条
    if (setting == 'reject') {
      rule.remove('outbound');
      rule['action'] = 'reject';
    } else if (setting.isNotEmpty && setting != 'default') {
      rule.remove('action');
      rule['outbound'] = tagByName[setting] ?? setting;
    }
    out.add(rule);
  }
  route['rules'] = out;
  return config;
}
