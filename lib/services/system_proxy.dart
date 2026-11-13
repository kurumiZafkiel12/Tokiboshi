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
}

class WindowsSystemProxy implements SystemProxy {
  const WindowsSystemProxy();

  @override
  Future<void> apply(bool enable, int port) async {
    if (!Platform.isWindows) return;
    const key =
        r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    await Process.run('reg', [
      'add', 'HKCU\\$key', '/v', 'ProxyEnable', '/t', 'REG_DWORD',
      '/d', enable ? '1' : '0', '/f',
    ]);
    if (enable) {
      await Process.run('reg', [
        'add', 'HKCU\\$key', '/v', 'ProxyServer', '/t', 'REG_SZ',
        '/d', '127.0.0.1:$port', '/f',
      ]);
    }
  }
}

class NoopSystemProxy implements SystemProxy {
  final List<({bool enable, int port})> calls = [];

  @override
  Future<void> apply(bool enable, int port) async {
    calls.add((enable: enable, port: port));
  }
}
