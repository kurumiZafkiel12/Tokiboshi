import 'dart:io';

typedef PortAllocator = Future<int> Function(int preferred, Set<int> reserved);

/// Probe a bounded range; never terminate another application's listener.
Future<int> findAvailablePort(int preferred, Set<int> reserved) async {
  for (var offset = 0; offset < 32 && preferred + offset <= 65535; offset++) {
    final port = preferred + offset;
    if (reserved.contains(port)) continue;
    try {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port, shared: false);
      await socket.close();
      return port;
    } on SocketException {
      // An occupied or unavailable port is not an available fallback.
    }
  }
  throw const SocketException('本地端口均不可用，请在设置中修改端口，或关闭占用端口的软件');
}
