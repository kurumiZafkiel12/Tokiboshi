import 'dart:convert';

/// Accept copied Markdown links and common client install/import deep links.
String normalizeImportText(String value) => _normalize(value, 0);
String _normalize(String value, int depth) {
  if (depth > 8) throw const FormatException('导入链接嵌套超过8层');
  var s = value.trim().replaceFirst(RegExp(r'^[\u200B\uFEFF]+'), '').trim();
  final markdown =
      RegExp(r'^\[[^\]]*\]\((https?://[^\s]+)\)$', caseSensitive: false)
          .firstMatch(s);
  if (markdown != null) s = markdown[1]!;
  if (s.startsWith('<') && s.endsWith('>'))
    s = s.substring(1, s.length - 1).trim();
  final uri = Uri.tryParse(s);
  if (uri != null &&
      [
        'clash',
        'clashmeta',
        'sing-box',
        'singbox',
        'karing',
        'flclash',
        'hiddify'
      ].contains(uri.scheme.toLowerCase())) {
    final embedded =
        uri.queryParameters['url'] ?? uri.queryParameters['config'];
    if (embedded == null || embedded.trim().isEmpty)
      throw const FormatException('导入链接缺少 url 参数');
    return _normalize(embedded, depth + 1);
  }
  if (s.startsWith('sub://')) {
    try {
      final bytes = base64.decode(base64.normalize(s.substring(6)));
      return _normalize(utf8.decode(bytes), depth + 1);
    } catch (_) {
      throw const FormatException('sub:// 订阅包装无效');
    }
  }
  if (uri != null && ['http', 'https'].contains(uri.scheme.toLowerCase()))
    s = uri.replace(scheme: uri.scheme.toLowerCase()).toString();
  return s;
}

bool isSubscriptionUrl(String s) {
  final uri = Uri.tryParse(s);
  return uri != null &&
      ['http', 'https'].contains(uri.scheme.toLowerCase()) &&
      uri.hasAuthority &&
      uri.host.isNotEmpty;
}
