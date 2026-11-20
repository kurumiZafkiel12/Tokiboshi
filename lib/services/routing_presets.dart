/// 内置分流细分预设（T090 用户需求：细分、可选细分的软件预设）。
///
/// 预设是一组 sing-box 路由规则片段，插入到生成配置的模式规则之后、
/// 模板规则之前——预设规则因此优先于 ads/CN 模板。目标只使用应用
/// 已有出站（direct / proxy），不引入新身份（T039 未完成前的安全
/// 边界）。均衡预设 = 不注入（沿用 0.1.0 模板）。
library;

class RoutingPreset {
  final String id;
  final String name;
  final String desc;
  final List<Map<String, dynamic>> rules;

  const RoutingPreset(this.id, this.name, this.desc, this.rules);
}

const streamingRules = [
  {
    'domain_suffix': [
      'netflix.com', 'nflxvideo.net', 'disneyplus.com', 'disney-plus.net',
      'hbo.com', 'max.com', 'hulu.com', 'youtube.com', 'ytimg.com',
      'googlevideo.com', 'twitch.tv',
    ],
    'outbound': 'proxy',
  },
];

const aiRules = [
  {
    'domain_suffix': [
      'openai.com', 'oaiusercontent.com', 'anthropic.com', 'claude.ai',
      'gemini.google.com', 'aistudio.google.com', 'perplexity.ai',
      'copilot.microsoft.com', 'x.ai',
    ],
    'outbound': 'proxy',
  },
];

const hardenRules = [
  {
    'domain_suffix': [
      'doubleclick.net', 'googletagmanager.com', 'google-analytics.com',
      'app-measurement.com', 'scorecardresearch.com', 'quantserve.com',
    ],
    'action': 'reject',
  },
];

const RoutingPreset balancedPreset =
    RoutingPreset('balanced', '均衡', '内置 ads/CN 模板（现状默认）', []);
const RoutingPreset streamingPreset = RoutingPreset(
    'streaming', '流媒体优先', '流媒体域名强制走代理（置于模板规则之前）', streamingRules);
const RoutingPreset aiPreset = RoutingPreset(
    'ai', 'AI 服务优先', 'AI 服务域名强制走代理（置于模板规则之前）', aiRules);
const RoutingPreset hardenPreset = RoutingPreset(
    'harden', '净化增强', '跟踪/埋点域名拦截叠加（置于模板规则之前）', hardenRules);

const List<RoutingPreset> routingPresets = [
  balancedPreset,
  streamingPreset,
  aiPreset,
  hardenPreset,
];

RoutingPreset presetById(String id) =>
    routingPresets.firstWhere((p) => p.id == id,
        orElse: () => balancedPreset);

/// Apply a routing preset to a generated sing-box config: preset rules
/// are inserted after the app-owned mode rules (so 私有直连 stays first
/// and 模式切换 keeps working), before the template's ads/CN rules.
/// Unknown preset ids or empty rule sets return the config unchanged.
Map<String, dynamic> applyRoutingPreset(Map<String, dynamic> config, String presetId) {
  final preset = presetById(presetId);
  if (preset.rules.isEmpty) return config;
  final route = (config['route'] as Map<String, dynamic>?);
  if (route == null) return config;
  final rules = (route['rules'] as List<dynamic>? ?? []);
  var idx = 0;
  while (idx < rules.length && (rules[idx] as Map)['clash_mode'] != null) {
    idx++;
  }
  rules.insertAll(idx, preset.rules);
  route['rules'] = rules;
  return config;
}
