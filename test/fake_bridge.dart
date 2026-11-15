import 'package:tokiboshi/bridge/core_bridge.dart';

/// In-memory CoreBridge for tests. Parsing accepts only the canned
/// links below; the authoritative parser is the Rust layer.
class FakeBridge implements CoreBridge {
  bool running = false;
  String? lastConfig;

  @override
  Future<NodeInfo> parseShareLink(String link) async {
    if (link.startsWith('ss://')) {
      final frag = link.contains('#') ? link.split('#').last : '';
      return NodeInfo(
        name: frag.isNotEmpty ? frag : 'FakeSS',
        outboundJson: '{"type":"shadowsocks","server":"127.0.0.1",'
            '"server_port":8388,"method":"aes-256-gcm","password":"pw"}',
      );
    }
    throw const FormatException('unsupported link scheme');
  }

  @override
  Future<ParseOutcome> parseSubscription(String text) async {
    if (text.contains('PROVIDERS-DEMO')) {
      return const ParseOutcome(
        nodes: [
          NodeInfo(
            name: 'Inline',
            outboundJson: '{"type":"shadowsocks","server":"127.0.0.1",'
                '"server_port":8388,"method":"aes-256-gcm","password":"pw"}',
          ),
        ],
        providers: [
          ProviderInfo(
            name: '源A',
            url: 'https://provider.example/sub',
            excludeFilter: '流量',
          ),
        ],
      );
    }
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
    required List<NodeSpec> nodes,
    int mixedPort = 7890,
    int clashApiPort = 9090,
    bool enableTun = false,
    bool blockAds = true,
    bool bypassCn = true,
    String dataDir = '',
    String? selectedName,
    String profileJson = '',
  }) async {
    if (nodes.isEmpty) {
      throw const FormatException('no nodes to build a config from');
    }
    lastConfig = '{"outbounds":[${nodes.map((n) => n.outboundJson).join(',')}]'
        ',"listen_port":$mixedPort,"clash_api_port":$clashApiPort}';
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

  @override
  Future<CoreStatus> coreStatus() async =>
      CoreStatus(running: running, restartCount: 0);

  @override
  Future<List<String>> coreLogs() async =>
      running ? const ['fake-core-started'] : const [];

  @override
  Future<String> coreVersion(String binaryPath) async =>
      'sing-box version 1.14.4-fake';

  @override
  Future<String> managedCorePath(String dataDir) async =>
      '$dataDir/core/sing-box.exe';

  @override
  Future<void> startEnsureCore(String dataDir) async {}

  @override
  Future<EnsureState> ensureCoreState() async =>
      const EnsureState(phase: 'done', version: 'sing-box version 1.14.4-fake');
}
