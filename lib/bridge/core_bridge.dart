/// Bridge between the Flutter UI and the Rust middle layer.
///
/// The real implementation is [RustCoreBridge], which calls the
/// generated flutter_rust_bridge bindings for `rust/src/api/core.rs`.
/// Tests substitute a fake implementation of this interface.
library;

import 'dart:convert';

class NodeInfo {
  const NodeInfo({required this.name, required this.outboundJson, this.source = ''});

  final String name;

  /// A single sing-box outbound as JSON text.
  final String outboundJson;

  /// '' for manually imported nodes, otherwise the owning
  /// subscription's id.
  final String source;

  Map<String, dynamic> get _outbound {
    try {
      final v = jsonDecode(outboundJson);
      return v is Map<String, dynamic> ? v : const {};
    } catch (_) {
      return const {};
    }
  }

  String get protocol => (_outbound['type'] as String?) ?? 'unknown';
  String get server => (_outbound['server'] as String?) ?? '';
  int get serverPort => (_outbound['server_port'] as num?)?.toInt() ?? 0;

  NodeInfo withSource(String source) =>
      NodeInfo(name: name, outboundJson: outboundJson, source: source);

  Map<String, dynamic> toJson() =>
      {'name': name, 'outboundJson': outboundJson, 'source': source};

  factory NodeInfo.fromJson(Map<String, dynamic> json) => NodeInfo(
        name: json['name'] as String,
        outboundJson: json['outboundJson'] as String,
        source: (json['source'] as String?) ?? '',
      );
}

/// Result of parsing subscription content: converted nodes plus one
/// "name (type)" note per entry skipped as unsupported.
class ParseOutcome {
  const ParseOutcome({required this.nodes, this.skipped = const []});

  final List<NodeInfo> nodes;
  final List<String> skipped;
}

abstract class CoreBridge {
  /// Parse one share link into a node.
  Future<NodeInfo> parseShareLink(String link);

  /// Parse subscription content (links, base64 blob, Clash YAML,
  /// sing-box JSON).
  Future<ParseOutcome> parseSubscription(String text);

  /// Build a full sing-box config around one outbound JSON object.
  Future<String> buildConfig({
    required String outboundJson,
    int mixedPort = 7890,
    bool enableTun = false,
  });

  /// Start sing-box (the Rust layer runs `sing-box check` first).
  Future<void> startCore({
    required String singBoxPath,
    required String configPath,
  });

  Future<void> stopCore();

  Future<bool> coreRunning();
}
