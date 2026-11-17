import 'dart:convert';
import 'dart:io';

import '../bridge/core_bridge.dart';
import 'subscription_fetcher.dart';

/// Expands merged subscriptions and Clash providers, preserving same-name nodes.
/// Limits and failures are reported instead of silently truncating the result.
class SubscriptionResolver {
  SubscriptionResolver(
      {required this.bridge, required this.fetcher, this.isCancelled});

  final CoreBridge bridge;
  final SubscriptionFetcher fetcher;
  final bool Function()? isCancelled;
  void _checkCancelled() {
    if (isCancelled?.call() == true) throw const ImportCancelled();
  }

  static const maxDepth = 8;
  static const maxRequests = 64;
  static const maxExpansions = 256;
  static const maxNodes = 100000;

  RegExp? _filter(String? pattern) {
    if (pattern == null || pattern.isEmpty) return null;
    final insensitive = pattern.contains('(?i)');
    // Invalid filters must be visible: ignoring one silently changes node counts.
    return RegExp(pattern.replaceAll('(?i)', ''), caseSensitive: !insensitive);
  }

  Future<ParseOutcome> resolveContent(String text,
          {bool nodesOnly = false, String? baseUrl}) =>
      resolve(baseUrl ?? 'https://local-import.invalid/',
          initialContent: text, nodesOnly: nodesOnly);

  Future<ParseOutcome> resolve(String url,
      {String? initialContent,
      bool nodesOnly = false,
      String? userAgent}) async {
    final cache = <String, Future<ParseOutcome>>{};
    var expansions = 0;
    final ruleCache = <String, Future<String>>{};
    Future<ParseOutcome> expand(
        String link, String? ua, int depth, Set<String> path) async {
      _checkCancelled();
      final uri = Uri.tryParse(link);
      final inline = depth > 0 && uri?.scheme == 'data';
      if (uri == null ||
          (!inline &&
              (!uri.hasAuthority || !['http', 'https'].contains(uri.scheme)))) {
        throw const FormatException('订阅地址必须是有效的 HTTP/HTTPS URL');
      }
      final key = '$ua\n$link';
      if (path.contains(key)) {
        return const ParseOutcome(
            nodes: [], skipped: ['循环子订阅已跳过'], failedGroups: ['']);
      }
      if (++expansions > maxExpansions ||
          depth > maxDepth ||
          (!cache.containsKey(key) && cache.length >= maxRequests)) {
        return const ParseOutcome(
            nodes: [], skipped: ['订阅展开达到安全上限，部分节点源未拉取'], failedGroups: ['']);
      }
      final first = await cache.putIfAbsent(key, () async {
        final content = depth == 0 && initialContent != null
            ? initialContent
            : inline
                ? utf8.decode(uri.data!.contentAsBytes())
                : await fetcher.fetch(link, userAgent: ua);
        return bridge.parseSubscription(content);
      });
      _checkCancelled();
      final nodes = first.nodes.take(maxNodes).toList();
      final skipped = [...first.skipped];
      final failedGroups = [...first.failedGroups];
      if (first.nodes.length > maxNodes) skipped.add('节点数量达到安全上限');
      for (final provider in first.providers) {
        _checkCancelled();
        try {
          final include = _filter(provider.filter);
          final exclude = _filter(provider.excludeFilter);
          if (uri.host == 'local-import.invalid' &&
              !Uri.parse(provider.url).hasScheme) {
            throw const FormatException('本地内容的相对节点源地址没有基准 URL');
          }
          final providerUrl = uri.scheme == 'data'
              ? provider.url
              : uri.resolve(provider.url).toString();
          final inner = await expand(
              providerUrl, provider.userAgent, depth + 1, {...path, key});
          var count = 0;
          for (final node in inner.nodes) {
            // A named proxy-provider imports its server nodes, not that
            // provider response's own top-level strategy configuration.
            if (provider.name.isNotEmpty && node.isPolicy) continue;
            if (nodes.length >= maxNodes) {
              skipped.add('节点数量达到安全上限，部分节点未导入');
              break;
            }
            if (include != null && !include.hasMatch(node.name)) continue;
            if (exclude != null && exclude.hasMatch(node.name)) continue;
            nodes.add(provider.name.isEmpty
                ? node
                : node.withGroup(node.group.isEmpty
                    ? provider.name
                    : '${provider.name} / ${node.group}'));
            count++;
          }
          skipped.addAll(inner.skipped);
          failedGroups
              .addAll(inner.failedGroups.map((group) => provider.name.isEmpty
                  ? group
                  : group.isEmpty
                      ? provider.name
                      : '${provider.name} / $group'));
          if (count == 0 && inner.nodes.isNotEmpty) {
            skipped.add('节点源「${provider.name}」的节点被过滤规则全部排除');
          }
        } on ImportCancelled {
          rethrow;
        } on FormatException {
          skipped.add('节点源「${provider.name}」地址、内容或过滤规则无效');
          failedGroups.add(provider.name);
        } catch (error) {
          final status = error is HttpException
              ? RegExp(r'HTTP \d{3}').stringMatch(error.message)
              : null;
          final challenge =
              error is HttpException && error.message.contains('Cloudflare')
                  ? ' · Cloudflare 验证'
                  : '';
          skipped.add(
              '节点源「${provider.name.isEmpty ? '子订阅' : provider.name}」拉取失败${status == null ? '' : '（$status$challenge）'}');
          failedGroups.add(provider.name);
        }
      }
      // Named node providers cannot replace the root routing profile.
      var profile = first.profileJson;
      if (nodesOnly && depth == 0) {
        return ParseOutcome(
            nodes: nodes,
            skipped: [
              ...skipped,
              if (profile != null) '按用户选择仅导入节点，不应用此来源的规则和 DNS'
            ],
            failedGroups: failedGroups,
            nodesOnly: true);
      }
      if (profile != null && depth == 0) {
        try {
          final parsed = jsonDecode(profile) as Map<String, dynamic>;
          final unsupported = (parsed['unsupported'] as List?) ?? const [];
          if (unsupported.isNotEmpty) {
            throw FormatException('订阅规则不兼容：${unsupported.join('；')}');
          }
          final sets = (parsed['rule_sets'] as List?) ?? const [];
          final converted = <dynamic>[];
          for (final value in sets) {
            final set = Map<String, dynamic>.from(value as Map);
            if (set['__behavior'] == null) {
              converted.add(set);
              continue;
            }
            final link = uri.resolve(set['url'] as String).toString();
            if (!ruleCache.containsKey(link) &&
                cache.length + ruleCache.length >= maxRequests) {
              throw const FormatException('规则集请求达到上限，保留上次配置');
            }
            final content =
                await ruleCache.putIfAbsent(link, () => fetcher.fetch(link));
            _checkCancelled();
            final rules = await bridge.convertRuleProvider(
                text: content,
                behavior: set['__behavior'] as String,
                format: set['__format'] as String? ?? 'yaml');
            converted.add({
              'type': 'inline',
              'tag': set['tag'],
              'rules': jsonDecode(rules)
            });
          }
          parsed['rule_sets'] = converted;
          profile = jsonEncode(parsed);
        } catch (error) {
          if (error is ImportCancelled) rethrow;
          throw ProfileCompatibilityException(
              '完整配置暂不兼容：${error is FormatException ? error.message : error}',
              ParseOutcome(
                  nodes: nodes,
                  skipped: [
                    ...skipped,
                    '未应用订阅规则 / DNS：${error is FormatException ? error.message : '规则集获取或转换失败'}'
                  ],
                  failedGroups: failedGroups,
                  nodesOnly: true));
        }
      }
      return ParseOutcome(
          nodes: nodes,
          skipped: skipped,
          failedGroups: failedGroups,
          profileJson: profile);
    }

    return expand(url, userAgent, 0, {});
  }
}

/// Keep old nodes only for failed sources; successful empty/filtered sources
/// intentionally replace their old contents.
List<NodeInfo> retainFailedSourceNodes(List<NodeInfo> previous,
        List<NodeInfo> fresh, List<String> failedGroups) =>
    [
      for (final node in previous)
        if (failedGroups.any((group) =>
                group.isEmpty ||
                node.group == group ||
                node.group.startsWith('$group / ')) &&
            !fresh.any((n) => n.group == node.group && n.name == node.name))
          node,
    ];

/// Expand imported strategy groups after all sources (including cached sources)
/// are available. Preserve the source declaration for future subscription updates.
List<NodeInfo> resolvePolicyGroups(List<NodeInfo> nodes) => [
      for (final node in nodes)
        if (!node.isPolicy || !node.outbound.containsKey('_clash_proxies'))
          node
        else
          _resolvePolicy(node, nodes),
    ];

NodeInfo _resolvePolicy(NodeInfo node, List<NodeInfo> nodes) {
  final ob = Map<String, dynamic>.from(node.outbound);
  final members = <String>{
    ...((ob['_clash_proxies'] as List?) ?? const []).cast<String>()
  };
  final sources = ((ob['_clash_use'] as List?) ?? const []).cast<String>();
  for (final candidate in nodes) {
    if (!candidate.isPolicy &&
        candidate.source == node.source &&
        sources.any((s) =>
            candidate.group == s || candidate.group.startsWith('$s / '))) {
      members.add(candidate.name);
    }
  }
  RegExp? pattern(String key) {
    final text = ob[key] as String?;
    if (text == null || text.isEmpty) return null;
    return RegExp(text.replaceAll('(?i)', ''),
        caseSensitive: !text.contains('(?i)'));
  }

  final include = pattern('_clash_filter');
  final exclude = pattern('_clash_exclude_filter');
  final filtered = members
      .where((name) =>
          (include == null || include.hasMatch(name)) &&
          (exclude == null || !exclude.hasMatch(name)))
      .toList();
  ob['outbounds'] = filtered.isEmpty ? ['REJECT'] : filtered;
  return NodeInfo(
      name: node.name,
      outboundJson: jsonEncode(ob),
      source: node.source,
      group: node.group);
}

Set<int> policyNodeIndices(List<NodeInfo> nodes, int policyIndex) {
  final seen = <int>{};
  final result = <int>{};
  void visit(int index) {
    if (!seen.add(index)) return;
    final node = nodes[index];
    if (!node.isPolicy) {
      result.add(index);
      return;
    }
    final members =
        ((node.outbound['outbounds'] as List?) ?? const []).cast<String>();
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].source == node.source && members.contains(nodes[i].name))
        visit(i);
    }
  }

  visit(policyIndex);
  return result;
}

/// Carries usable nodes; the caller must ask before omitting routing semantics.
class ProfileCompatibilityException extends FormatException {
  ProfileCompatibilityException(String message, this.nodesOnlyOutcome)
      : super(message);
  final ParseOutcome nodesOnlyOutcome;
}

class ImportCancelled implements Exception {
  const ImportCancelled();
}
