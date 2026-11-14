import 'package:tokiboshi/bridge/core_bridge.dart';

/// In-memory CoreBridge for tests. Parsing accepts only the canned
/// links below; the authoritative parser is the Rust layer.
class FakeBridge implements CoreBridge {
  bool running = false;
  String? lastConfig;

  @override
  Future<NodeInfo> parseShareLink(String link) async {
    if (link.startsWith('ss://')) {
      return const NodeInfo(
        name: 'FakeSS',
        outboundJson: '{"type":"shadowsocks","server":"127.0.0.1",'
            '"server_port":8388,"method":"aes-256-gcm","password":"pw"}',
      );
    }
    throw const FormatException('unsupported link scheme');
  }

  @override
  Future<ParseOutcome> parseSubscription(String text) async {
    final nodes = <NodeInfo>[];
    for (final line in text.split('\n')) {
      if (line.trim().isEmpty) continue;
      nodes.add(await parseShareLink(line.trim()));
    }
    if (nodes.isEmpty) throw const FormatException('no usable links');
    return ParseOutcome(nodes: nodes);
  }

  @override
  Future<String> buildConfig({
    required String outboundJson,
    int mixedPort = 7890,
    bool enableTun = false,
  }) async {
    if (outboundJson.isEmpty) {
      throw const FormatException('outbound missing "type"');
    }
    lastConfig = '{"outbounds":[$outboundJson],"listen_port":$mixedPort}';
    return lastConfig!;
  }

  @override
  Future<void> startCore({
    required String singBoxPath,
    required String configPath,
  }) async {
    if (running) throw StateError('already running');
    running = true;
  }

  @override
  Future<void> stopCore() async {
    running = false;
  }

  @override
  Future<bool> coreRunning() async => running;
}
