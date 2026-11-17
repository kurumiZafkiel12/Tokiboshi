import 'dart:convert';
import 'dart:io';
import 'desktop_settings.dart';

/// Only current-user startup registration, never a service or scheduled admin task.
class WindowsStartup {
  WindowsStartup(
      {Future<ProcessResult> Function(String, List<String>)? runner,
      String? executable})
      : _run = runner ?? ((p, a) => Process.run(p, a)),
        _executable = executable ?? Platform.resolvedExecutable;
  final Future<ProcessResult> Function(String, List<String>) _run;
  final String _executable;
  static const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  Future<void> setEnabled(bool enabled) async {
    final result = await _run(
        'reg',
        enabled
            ? [
                'add',
                key,
                '/v',
                'Tokiboshi',
                '/t',
                'REG_SZ',
                '/d',
                '"$_executable" --autostart',
                '/f'
              ]
            : ['delete', key, '/v', 'Tokiboshi', '/f']);
    if (result.exitCode != 0) {
      if (!enabled && !await isEnabled()) return;
      throw const FileSystemException('自启注册表设置失败');
    }
    if (await isEnabled() != enabled)
      throw const FileSystemException('自启状态未生效');
  }

  Future<bool> isEnabled() async {
    final result = await _run('reg', ['query', key, '/v', 'Tokiboshi']);
    if (result.exitCode == 1) return false;
    if (result.exitCode != 0) throw const FileSystemException('无法读取自启状态');
    final lines = result.stdout.toString();
    return lines.contains('"$_executable" --autostart');
  }
}

/// Local controller stays authenticated for app controls. Remote access is explicit.
String applyNetworkSettings(String config, DesktopSettings prefs) {
  final root = jsonDecode(config) as Map<String, dynamic>;
  if (prefs.proxyAuth &&
      (prefs.proxyUser.trim().isEmpty || prefs.proxyPassword.isEmpty))
    throw const FormatException('代理认证需要用户名和密码');
  for (final raw in root['inbounds'] as List? ?? []) {
    if (raw is Map && raw['type'] == 'mixed') {
      raw['listen'] = prefs.allowLan ? '0.0.0.0' : '127.0.0.1';
      if (prefs.proxyAuth) {
        raw['users'] = [
          {'username': prefs.proxyUser.trim(), 'password': prefs.proxyPassword}
        ];
      } else {
        raw.remove('users');
      }
    }
  }
  final api = (root['experimental'] as Map?)?['clash_api'];
  if (api is Map) {
    final previous = '${api['external_controller'] ?? '127.0.0.1:9090'}';
    final port = previous.split(':').last;
    if (prefs.remoteController && '${api['secret'] ?? ''}'.isEmpty)
      throw const FormatException('开放控制器需要认证密钥');
    api['external_controller'] =
        '${prefs.remoteController ? '0.0.0.0' : '127.0.0.1'}:$port';
  }
  return jsonEncode(root);
}

class ReleaseUpdate {
  const ReleaseUpdate(this.tag, this.url, this.available);
  final String tag, url;
  final bool available;
}

class UpdateClient {
  const UpdateClient();
  Future<ReleaseUpdate> check(String currentTag) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse(
          'https://api.github.com/repos/kurumiZafkiel12/Tokiboshi/releases/latest'));
      request.headers.set(HttpHeaders.userAgentHeader, 'Tokiboshi-update');
      request.headers
          .set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200)
        throw HttpException('更新服务 HTTP ${response.statusCode}');
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
      final data = jsonDecode(text) as Map<String, dynamic>,
          tag = data['tag_name'] as String;
      return ReleaseUpdate(
          tag,
          'https://github.com/kurumiZafkiel12/Tokiboshi/releases/tag/${Uri.encodeComponent(tag)}',
          isNewerTag(tag, currentTag));
    } finally {
      client.close(force: true);
    }
  }
}

bool isNewerTag(String next, String current) {
  List<int>? parts(String value) {
    final match =
        RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:-r(\d+))?$').firstMatch(value);
    if (match == null) return null;
    return [for (var i = 1; i <= 4; i++) int.tryParse(match[i] ?? '0') ?? 0];
  }

  final n = parts(next), c = parts(current);
  if (n == null || c == null) return false;
  for (var i = 0; i < n.length; i++) {
    if (n[i] != c[i]) return n[i] > c[i];
  }
  return false;
}

Future<Set<String>> runningProcessNames() async {
  if (!Platform.isWindows) return {};
  final result = await Process.run('powershell', [
    '-NoProfile',
    '-NonInteractive',
    '-WindowStyle',
    'Hidden',
    '-Command',
    'Get-Process | Select-Object -ExpandProperty ProcessName'
  ]);
  if (result.exitCode != 0) throw const FileSystemException('无法读取运行进程');
  return result.stdout
      .toString()
      .split(RegExp(r'[\r\n]+'))
      .map((s) => s.trim().toLowerCase().replaceFirst(RegExp(r'\.exe$'), ''))
      .where((s) => s.isNotEmpty)
      .toSet();
}

bool matchesDemandProcesses(List<String> watched, Set<String> running) =>
    watched.any((name) => running.contains(
        name.trim().toLowerCase().replaceFirst(RegExp(r'\.exe$'), '')));
