/// Display/export redaction. Never copy full subscription URLs or share links.
String redactDiagnostics(String input) => input
    .replaceAll(RegExp(r'\x1b\[[0-9;]*[A-Za-z]'), '')
    .replaceAllMapped(RegExp(r'https?://[^\s<>"\x27]+'), (m) {
      final uri = Uri.tryParse(m[0]!);
      return uri == null ? '[地址已隐藏]' : '${uri.scheme}://${uri.host}/[路径与参数已隐藏]';
    })
    .replaceAll(
        RegExp(
            r'(?:ss|ssr|vmess|vless|trojan|hysteria2?|hy2|tuic|anytls|socks5?)://[^\s]+',
            caseSensitive: false),
        '[节点链接已隐藏]')
    .replaceAllMapped(
        RegExp(
            r'("?(?:password|passwd|uuid|token|authorization|secret)"?\s*[:=]\s*)[^,\s}]+',
            caseSensitive: false),
        (m) => '${m[1]}[已隐藏]');
