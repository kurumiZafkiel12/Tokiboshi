/// Windows system proxy seam.
///
/// The real implementation writes the current user's Internet Settings
/// registry keys via `reg.exe`. Tests substitute a fake: real process
/// IO cannot complete inside the widget-test fake-async zone (this is
/// why the start/stop widget test passed on Linux but hung on Windows,
/// where Platform.isWindows is true).
library;

import 'dart:io';

abstract class SystemProxy {
  Future<void> apply(bool enable, int port);

  /// Current `ProxyServer` registry value (e.g. "127.0.0.1:7890"),
  /// or null when unset/unreadable. Used to detect a proxy left
  /// behind by a crashed previous run.
  Future<String?> readProxyServer();
}

class WindowsSystemProxy implements SystemProxy {
  const WindowsSystemProxy();

  static const _key = r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  @override
  Future<void> apply(bool enable, int port) async {
    if (!Platform.isWindows) return;
    await Process.run('reg', [
      'add', 'HKCU\\$_key', '/v', 'ProxyEnable', '/t', 'REG_DWORD',
      '/d', enable ? '1' : '0', '/f',
    ]);
    if (enable) {
      await Process.run('reg', [
        'add', 'HKCU\\$_key', '/v', 'ProxyServer', '/t', 'REG_SZ',
        '/d', '127.0.0.1:$port', '/f',
      ]);
    }
    // Best effort: ask WinINet to notice the change immediately
    // instead of at next logon; harmless when it fails.
    await Process.run('reg', [
      'add', 'HKCU\\$_key', '/v', 'ProxyOverride', '/t', 'REG_SZ',
      '/d', 'localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>',
      '/f',
    ]);
  }

  @override
  Future<String?> readProxyServer() async {
    if (!Platform.isWindows) return null;
    try {
      final result = await Process.run('reg', [
        'query', 'HKCU\\$_key', '/v', 'ProxyServer',
      ]);
      if (result.exitCode != 0) return null;
      final match = RegExp(r'Reg_SZ\s+(\S+)').firstMatch('${result.stdout}');
      return match?.group(1);
    } catch (_) {
      return null;
    }
  }
}

class NoopSystemProxy implements SystemProxy {
  NoopSystemProxy();

  final List<({bool enable, int port})> calls = [];
  String? proxyServer;

  @override
  Future<void> apply(bool enable, int port) async {
    calls.add((enable: enable, port: port));
    proxyServer = enable ? '127.0.0.1:$port' : null;
  }

  @override
  Future<String?> readProxyServer() async => proxyServer;
}
