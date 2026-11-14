/// Bridge between the Flutter UI and the Rust middle layer.
///
/// The real implementation is [RustCoreBridge], which calls the
/// generated flutter_rust_bridge bindings for `rust/src/api/core.rs`.
/// Tests substitute a fake implementation of this interface.
library;

import 'dart:convert';

class NodeInfo {
  const NodeInfo({
    required this.name,
    required this.outboundJson,
    this.source = '',
    this.group = '',
  });

  final String name;

  /// A single sing-box outbound as JSON text.
  final String outboundJson;

  /// '' for manually imported nodes, otherwise the owning
  /// subscription's id.
  final String source;

  /// Display group for nodes that arrived through a subscription's
  /// Clash `proxy-providers` entry: the provider's name. '' for
  /// inline/manual nodes.
  final String group;

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

  NodeInfo withSource(String source) => NodeInfo(
      name: name, outboundJson: outboundJson, source: source, group: group);

  NodeInfo withGroup(String group) => NodeInfo(
      name: name, outboundJson: outboundJson, source: source, group: group);

  NodeInfo withName(String name) => NodeInfo(
      name: name, outboundJson: outboundJson, source: source, group: group);

  Map<String, dynamic> toJson() => {
        'name': name,
        'outboundJson': outboundJson,
        'source': source,
        'group': group,
      };

  factory NodeInfo.fromJson(Map<String, dynamic> json) => NodeInfo(
        name: json['name'] as String,
        outboundJson: json['outboundJson'] as String,
        source: (json['source'] as String?) ?? '',
        group: (json['group'] as String?) ?? '',
      );
}

/// Result of parsing subscription content: converted nodes plus one
/// "name (type)" note per entry skipped as unsupported.
class ParseOutcome {
  const ParseOutcome({
    required this.nodes,
    this.skipped = const [],
    this.providers = const [],
  });

  final List<NodeInfo> nodes;
  final List<String> skipped;

  /// Clash `proxy-providers` entries the caller should fetch and
  /// parse as further subscriptions (empty for other formats).
  final List<ProviderInfo> providers;
}

/// One Clash YAML `proxy-providers` entry (http type).
class ProviderInfo {
  const ProviderInfo({
    required this.name,
    required this.url,
    this.userAgent,
    this.excludeFilter,
    this.filter,
  });

  final String name;
  final String url;
  final String? userAgent;
  final String? excludeFilter;
  final String? filter;
}

/// One node handed to the config generator.
class NodeSpec {
  const NodeSpec({required this.name, required this.outboundJson});

  final String name;
  final String outboundJson;
}

/// Supervision status of the core process.
class CoreStatus {
  const CoreStatus({required this.running, this.restartCount = 0, this.lastExit});

  final bool running;
  final int restartCount;
  final String? lastExit;
}

/// State of the background core download.
class EnsureState {
  const EnsureState({required this.phase, this.version, this.error});

  /// idle | downloading | done | error
  final String phase;
  final String? version;
  final String? error;
}

abstract class CoreBridge {
  /// Parse one share link into a node.
  Future<NodeInfo> parseShareLink(String link);

  /// Parse subscription content (links, base64 blob, Clash YAML,
  /// sing-box JSON).
  Future<ParseOutcome> parseSubscription(String text);

  /// Build the full GUI-shell sing-box config for all nodes
  /// (selector/urltest groups, route rules, Clash API + zashboard,
  /// cache file).
  Future<String> buildConfig({
    required List<NodeSpec> nodes,
    int mixedPort = 7890,
    int clashApiPort = 9090,
    bool enableTun = false,
    bool blockAds = true,
    bool bypassCn = true,
    String dataDir = '',
    String? selectedName,
  });

  /// Start sing-box (the Rust layer runs `sing-box check` first).
  Future<void> startCore({
    required String singBoxPath,
    required String configPath,
  });

  Future<void> stopCore();

  Future<bool> coreRunning();

  Future<CoreStatus> coreStatus();

  /// Recent core log lines, oldest first.
  Future<List<String>> coreLogs();

  /// `sing-box version` first line for the binary at [binaryPath].
  Future<String> coreVersion(String binaryPath);

  /// Path of the managed (downloaded) sing-box binary.
  Future<String> managedCorePath(String dataDir);

  /// Start downloading the pinned sing-box release in the
  /// background, unless already up to date.
  Future<void> startEnsureCore(String dataDir);

  Future<EnsureState> ensureCoreState();
}
