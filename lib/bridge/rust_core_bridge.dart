/// [CoreBridge] backed by the Rust middle layer via flutter_rust_bridge.
library;

import '../src/rust/api/core.dart' as rust_api;
import '../src/rust/config.dart' as rust_config;
import 'core_bridge.dart';

class RustCoreBridge implements CoreBridge {
  @override
  Future<NodeInfo> parseShareLink(String link) async {
    final n = await rust_api.parseShareLink(link: link);
    return NodeInfo(name: n.name, outboundJson: n.outboundJson);
  }

  @override
  Future<ParseOutcome> parseSubscription(String text) async {
    final outcome = await rust_api.parseSubscription(text: text);
    return ParseOutcome(
      // T069: profileJson 需 FRB regen 后才有值（Codex 执行 codegen）。
      // pre-regen 恒为 null，功能惰性。
            nodes: outcome.nodes
          .map((n) => NodeInfo(name: n.name, outboundJson: n.outboundJson))
          .toList(),
      skipped: outcome.skipped,
      providers: outcome.providers
          .map((p) => ProviderInfo(
                name: p.name,
                url: p.url,
                userAgent: p.userAgent,
                excludeFilter: p.excludeFilter,
                filter: p.filter,
              ))
          .toList(),
    ,
      profileJson: null,
    );
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
  }) {
    return rust_api.buildConfig(
      nodes: nodes
          .map((n) => rust_config.NodeSpec(
                name: n.name,
                outboundJson: n.outboundJson,
              ))
          .toList(),
      mixedPort: mixedPort,
      clashApiPort: clashApiPort,
      enableTun: enableTun,
      blockAds: blockAds,
      bypassCn: bypassCn,
      dataDir: dataDir,
      selectedName: selectedName,
    
        // T069: profileJson 需 FRB regen 后才能传入（Codex 执行 codegen 时接线）。
        // pre-regen 惰性：订阅自带规则不会进入生成配置。
);
  }

  @override
  Future<void> startCore({
    required String singBoxPath,
    required String configPath,
  }) {
    return rust_api.startCore(binaryPath: singBoxPath, configPath: configPath);
  }

  @override
  Future<void> stopCore() => rust_api.stopCore();

  @override
  Future<bool> coreRunning() => rust_api.coreRunning();

  @override
  Future<CoreStatus> coreStatus() async {
    final s = await rust_api.coreStatus();
    return CoreStatus(
      running: s.running,
      restartCount: s.restartCount,
      lastExit: s.lastExit,
    );
  }

  @override
  Future<List<String>> coreLogs() => rust_api.coreLogs();

  @override
  Future<String> coreVersion(String binaryPath) =>
      rust_api.coreVersion(binaryPath: binaryPath);

  @override
  Future<String> managedCorePath(String dataDir) =>
      rust_api.managedCorePath(dataDir: dataDir);

  @override
  Future<void> startEnsureCore(String dataDir) =>
      rust_api.startEnsureCore(dataDir: dataDir);

  @override
  Future<EnsureState> ensureCoreState() async {
    final s = await rust_api.ensureCoreState();
    return EnsureState(phase: s.phase, version: s.version, error: s.error);
  }
}
