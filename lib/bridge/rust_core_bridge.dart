/// [CoreBridge] backed by the Rust middle layer via flutter_rust_bridge.
library;

import '../src/rust/api/core.dart' as rust_api;
import 'core_bridge.dart';

class RustCoreBridge implements CoreBridge {
  @override
  Future<NodeInfo> parseShareLink(String link) async {
    final n = await rust_api.parseShareLink(link: link);
    return NodeInfo(name: n.name, outboundJson: n.outboundJson);
  }

  @override
  Future<List<NodeInfo>> parseSubscription(String text) async {
    final nodes = await rust_api.parseSubscription(text: text);
    return nodes
        .map((n) => NodeInfo(name: n.name, outboundJson: n.outboundJson))
        .toList();
  }

  @override
  Future<String> buildConfig({
    required String outboundJson,
    int mixedPort = 7890,
    bool enableTun = false,
  }) {
    return rust_api.buildConfig(
      outboundJson: outboundJson,
      mixedPort: mixedPort,
      enableTun: enableTun,
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
}
