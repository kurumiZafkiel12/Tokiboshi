/// Client for sing-box's Clash API (experimental.clash_api).
///
/// Every call to the local controller goes through this one module;
/// the UI never talks to 127.0.0.1:<clashApiPort> directly.
library;

import 'dart:convert';
import 'dart:io';

class ClashApiException implements Exception {
  ClashApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ClashApiClient {
  ClashApiClient({this.port = 9090, this.secret = '', HttpClient? httpClient})
      : _http = httpClient ?? HttpClient();

  final int port;

  /// Bearer secret of the local controller (see Store.injectClashSecret);
  /// empty means the core config predates the secret feature.
  final String secret;

  final HttpClient _http;

  String get _base => 'http://127.0.0.1:$port';

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      final req = await _http
          .openUrl(method, Uri.parse('$_base$path'))
          .timeout(timeout);
      if (secret.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
      }
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final resp = await req.close().timeout(timeout);
      final text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw ClashApiException(
          'Clash API $method $path → HTTP ${resp.statusCode}'
          '${text.isEmpty ? '' : '：$text'}',
        );
      }
      if (text.isEmpty) return null;
      return jsonDecode(text);
    } on ClashApiException {
      rethrow;
    } catch (e) {
      throw ClashApiException('Clash API 不可达（$path）：$e');
    }
  }

  /// {"version": "sing-box 1.14.4", ...}
  Future<Map<String, dynamic>> version() async =>
      (await _request('GET', '/version')) as Map<String, dynamic>;

  /// All proxy groups and nodes, keyed by tag.
  Future<Map<String, dynamic>> proxies() async {
    final v = await _request('GET', '/proxies');
    return (v as Map<String, dynamic>)['proxies'] as Map<String, dynamic>;
  }

  /// Currently selected member of a group (e.g. "proxy").
  Future<String?> selectedOf(String group) async {
    final all = await proxies();
    final g = all[group];
    return g is Map<String, dynamic> ? g['now'] as String? : null;
  }

  Future<void> select(String group, String name) => _request(
        'PUT',
        '/proxies/${Uri.encodeComponent(group)}',
        body: {'name': name},
      );

  /// Delay for one node or group in milliseconds; null on failure.
  Future<int?> delay(
    String name, {
    String url = 'https://www.gstatic.com/generate_204',
    int timeoutMs = 5000,
  }) async {
    try {
      final v = await _request(
        'GET',
        '/proxies/${Uri.encodeComponent(name)}/delay'
            '?url=${Uri.encodeComponent(url)}&timeout=$timeoutMs',
        timeout: Duration(milliseconds: timeoutMs + 2000),
      );
      if (v is Map<String, dynamic>) return (v['delay'] as num?)?.toInt();
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Current Clash mode ("Rule" / "Global" / "Direct").
  Future<String?> mode() async {
    final v = await _request('GET', '/configs');
    return (v as Map<String, dynamic>)['mode'] as String?;
  }

  Future<void> setMode(String mode) =>
      _request('PATCH', '/configs', body: {'mode': mode});
  Future<Map<String, dynamic>> connections() async =>
      (await _request('GET', '/connections')) as Map<String, dynamic>;

  Future<List<Map<String, dynamic>>> rules() async {
    final v = await _request('GET', '/rules');
    return ((v as Map<String, dynamic>)['rules'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  Future<void> closeConnections([String? id]) => _request('DELETE',
      id == null ? '/connections' : '/connections/${Uri.encodeComponent(id)}');

  void close() => _http.close(force: true);
}
