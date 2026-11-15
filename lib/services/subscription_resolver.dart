import 'dart:convert';
import 'dart:io';

import '../bridge/core_bridge.dart';
import 'subscription_fetcher.dart';

/// Expands merged subscriptions and Clash providers, preserving same-name nodes.
/// Limits and failures are reported instead of silently truncating the result.
class SubscriptionResolver {
  SubscriptionResolver({required this.bridge, required this.fetcher});

  final CoreBridge bridge;
  final SubscriptionFetcher fetcher;
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

  Future<ParseOutcome> resolve(String url) async {
    final cache = <String, Future<ParseOutcome>>{};
    var expansions = 0;
    Future<ParseOutcome> expand(String link, String? ua, int depth, Set<String> path) async {
      final uri = Uri.tryParse(link);
      final inline = depth > 0 && uri?.scheme == 'data';
      if (uri == null || (!inline && (!uri.hasAuthority || !['http', 'https'].contains(uri.scheme)))) {
        throw const FormatException('订阅地址必须是有效的 HTTP/HTTPS URL');
      }
      final key = '$ua\n$link';
      if (path.contains(key)) {
        return const ParseOutcome(nodes: [], skipped: ['循环子订阅已跳过']);
      }
      if (++expansions > maxExpansions || depth > maxDepth || (!cache.containsKey(key) && cache.length >= maxRequests)) {
        return const ParseOutcome(nodes: [], skipped: ['订阅展开达到安全上限，部分节点源未拉取']);
      }
      final first = await cache.putIfAbsent(key, () async {
        final content = inline
            ? utf8.decode(uri.data!.contentAsBytes())
            : await fetcher.fetch(link, userAgent: ua);
        return bridge.parseSubscription(content);
      });
      final nodes = first.nodes.take(maxNodes).toList();
      final skipped = [...first.skipped];
      final failedGroups = [...first.failedGroups];
      if (first.nodes.length > maxNodes) skipped.add('节点数量达到安全上限');
      for (final provider in first.providers) {
        try {
          final include = _filter(provider.filter);
          final exclude = _filter(provider.excludeFilter);
          final providerUrl = uri.scheme == 'data' ? provider.url : uri.resolve(provider.url).toString();
          final inner = await expand(providerUrl, provider.userAgent, depth + 1, {...path, key});
          var count = 0;
          for (final node in inner.nodes) {
            if (nodes.length >= maxNodes) {
              skipped.add('节点数量达到安全上限，部分节点未导入');
              break;
            }
            if (include != null && !include.hasMatch(node.name)) continue;
            if (exclude != null && exclude.hasMatch(node.name)) continue;
            nodes.add(provider.name.isEmpty ? node : node.withGroup(
                node.group.isEmpty ? provider.name : '${provider.name} / ${node.group}'));
            count++;
          }
          skipped.addAll(inner.skipped);
          failedGroups.addAll(inner.failedGroups.map((group) =>
              provider.name.isEmpty ? group : group.isEmpty ? provider.name : '${provider.name} / $group'));
          if (count == 0 && inner.nodes.isNotEmpty) {
            skipped.add('节点源「${provider.name}」的节点被过滤规则全部排除');
          }
        } on FormatException {
          skipped.add('节点源「${provider.name}」地址、内容或过滤规则无效');
          failedGroups.add(provider.name);
        } catch (error) {
          final status = error is HttpException ? RegExp(r'HTTP \d{3}').stringMatch(error.message) : null;
          final challenge = error is HttpException && error.message.contains('Cloudflare') ? ' · Cloudflare 验证' : '';
          skipped.add('节点源「${provider.name.isEmpty ? '子订阅' : provider.name}」拉取失败${status == null ? '' : '（$status$challenge）'}');
          failedGroups.add(provider.name);
        }
      }
      return ParseOutcome(nodes: nodes, skipped: skipped, failedGroups: failedGroups);
    }

    return expand(url, null, 0, {});
  }
}


/// Keep old nodes only for failed sources; successful empty/filtered sources
/// intentionally replace their old contents.
List<NodeInfo> retainFailedSourceNodes(List<NodeInfo> previous, List<NodeInfo> fresh, List<String> failedGroups) => [
  for (final node in previous)
    if (failedGroups.any((group) => group.isEmpty || node.group == group || node.group.startsWith('$group / ')) &&
        !fresh.any((n) => n.group == node.group && n.name == node.name)) node,
];
