/// TCP connect latency probe for a node endpoint.
library;

import 'dart:io';

/// Milliseconds to open a TCP connection to [server]:[port], or null
/// when unreachable within [timeout]. This measures reachability of
/// the node endpoint, not proxy throughput.
Future<int?> tcpLatency(
  String server,
  int port, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  if (server.isEmpty || port <= 0) return null;
  final watch = Stopwatch()..start();
  try {
    final socket = await Socket.connect(server, port, timeout: timeout);
    watch.stop();
    socket.destroy();
    return watch.elapsedMilliseconds;
  } catch (_) {
    return null;
  }
}
