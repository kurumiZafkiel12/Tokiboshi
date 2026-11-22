import 'dart:convert';
import 'dart:io';

class ServiceEvidence {
  const ServiceEvidence(this.code, this.body, this.elapsedMs);
  final int code, elapsedMs;
  final String body;
}

typedef ServiceAuditResult = (String service, String result, String evidence);

const serviceNames = [
  'Netflix',
  'Disney+',
  'YouTube Premium',
  'ChatGPT',
  'OpenAI API',
  'Spotify'
];

Future<ServiceAuditResult> auditService(
    HttpClient client, String service) async {
  Future<ServiceEvidence> get(String url) async {
    final deadline = DateTime.now().add(const Duration(seconds: 9));
    Duration remaining() {
      final left = deadline.difference(DateTime.now());
      return left.isNegative ? Duration.zero : left;
    }

    final watch = Stopwatch()..start();
    final request = await client.getUrl(Uri.parse(url)).timeout(remaining());
    request.followRedirects = false;
    request.headers
        .set(HttpHeaders.userAgentHeader, 'Tokiboshi/0.1.3 service-check');
    final response = await request.close().timeout(remaining());
    final bytes = <int>[];
    await response
        .takeWhile((_) => bytes.length < 1024 * 1024)
        .forEach((chunk) {
      bytes.addAll(chunk.take(1024 * 1024 - bytes.length));
    }).timeout(remaining());
    return ServiceEvidence(response.statusCode,
        utf8.decode(bytes, allowMalformed: true), watch.elapsedMilliseconds);
  }

  try {
    final base = await get(switch (service) {
      'Netflix' => 'https://www.netflix.com/title/80057281',
      'Disney+' => 'https://www.disneyplus.com/',
      'YouTube Premium' => 'https://www.youtube.com/premium?hl=en',
      'ChatGPT' => 'https://chatgpt.com/',
      'OpenAI API' => 'https://api.openai.com/v1/models',
      _ =>
        'https://www.spotify.com/api/content/v1/country-selector?platform=web&format=json',
    });
    var result = classifyService(base);
    final region =
        RegExp(r'"(?:countryCode|country_code|GL)"\s*:\s*"([A-Za-z]{2})"')
            .firstMatch(base.body)
            ?.group(1)
            ?.toUpperCase();
    final evidence = <String>[
      'HTTP ${base.code} · ${base.elapsedMs} ms',
      if (region != null) '页面地区 $region'
    ];
    if (result == '端点可达') {
      if (service == 'Netflix') {
        final licensed = await get('https://www.netflix.com/title/70143836');
        result = classifyNetflixCatalog(base, licensed);
        evidence.add('授权样本 HTTP ${licensed.code}');
      } else if (service == 'Disney+') {
        final permitted = RegExp(r'"inSupportedLocation"\s*:\s*(true|false)')
            .firstMatch(base.body)
            ?.group(1);
        if (permitted == 'true') result = '页面报告地区受支持';
        if (permitted == 'false') result = '地区受限';
      }
    }
    return (service, result, evidence.join(' · '));
  } catch (_) {
    return (service, '探测失败', '代理路径、服务器或请求超时');
  }
}

String classifyService(ServiceEvidence sample) {
  final body = sample.body.toLowerCase();
  if (const [
    'unsupported_country',
    'country_not_supported',
    'not available in your country',
    'not available in your region',
    'geo_restricted',
    'region_not_supported'
  ].any(body.contains)) {
    return '地区受限';
  }
  if (const [
    'cf-chl-',
    'challenge-platform',
    'verify you are human',
    'just a moment...'
  ].any(body.contains)) return '验证挑战';
  if (sample.code == 401) return '需要登录或 API 密钥';
  if (sample.code == 429) return '服务限流';
  if (sample.code == 403) return '服务拒绝';
  if (sample.code >= 500) return '服务异常';
  if (sample.code >= 300 && sample.code < 400) return '重定向，地区未确认';
  if (sample.code >= 200 && sample.code < 300) return '端点可达';
  return '结果待确认';
}

String classifyNetflixCatalog(
    ServiceEvidence original, ServiceEvidence licensed) {
  final playable = RegExp(r'"isPlayable"\s*:\s*true');
  final state = classifyService(original);
  if (state != '端点可达') return state;
  if (!playable.hasMatch(original.body)) return '片库未确认';
  if (licensed.code == 404) return '仅原创样本可用';
  if (classifyService(licensed) == '端点可达' && playable.hasMatch(licensed.body)) {
    return '两类片库样本可用';
  }
  return '片库未确认';
}
