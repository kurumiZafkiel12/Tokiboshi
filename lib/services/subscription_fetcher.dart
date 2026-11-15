/// Fetches subscription content over HTTP(S).
///
/// A seam so widget tests can substitute a fake: real network IO
/// cannot run inside the widget-test fake-async zone.
library;

import 'dart:convert';
import 'dart:io';

abstract class SubscriptionFetcher {
  Future<String> fetch(String url, {String? userAgent});
}

class HttpSubscriptionFetcher implements SubscriptionFetcher {
  const HttpSubscriptionFetcher();

  @override
  Future<String> fetch(String url, {String? userAgent}) async {
    final uri = Uri.parse(url);
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const FormatException('订阅链接必须是 http/https');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, userAgent ?? 'Clash.Meta Tokiboshi/0.5.3');
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final challenge = response.headers.value('cf-mitigated') == 'challenge' ? '（Cloudflare 验证）' : '';
        throw HttpException('订阅拉取失败：HTTP ${response.statusCode}$challenge');
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 30));
      if (body.length > 8 * 1024 * 1024) {
        throw const FormatException('订阅内容过大');
      }
      return body;
    } finally {
      client.close(force: true);
    }
  }
}

/// Test double: serves canned content per URL.
class FakeFetcher implements SubscriptionFetcher {
  FakeFetcher(this.responses);

  final Map<String, String> responses;
  final List<String> requested = [];

  @override
  Future<String> fetch(String url, {String? userAgent}) async {
    requested.add(url);
    final body = responses[url];
    if (body == null) throw HttpException('no fake response for $url');
    return body;
  }
}
