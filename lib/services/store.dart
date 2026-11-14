/// Tiny JSON file persistence for the Windows app.
///
/// Data lives in `%APPDATA%\Tokiboshi\data.json`; when APPDATA is not
/// available it falls back to `./tokiboshi-data.json`. The v0.1 format
/// (nodes/settings only) loads unchanged; subscriptions and the
/// system-proxy flag default when absent.
library;

import 'dart:convert';
import 'dart:io';

import '../bridge/core_bridge.dart';

class Subscription {
  const Subscription({
    required this.id,
    required this.name,
    required this.url,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String url;

  /// ISO-8601 time of the last successful update.
  final String? updatedAt;

  Subscription copyWith({String? name, String? url, String? updatedAt}) =>
      Subscription(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'url': url, 'updatedAt': updatedAt};

  factory Subscription.fromJson(Map<String, dynamic> json) => Subscription(
        id: json['id'] as String,
        name: json['name'] as String,
        url: json['url'] as String,
        updatedAt: json['updatedAt'] as String?,
      );
}

class AppData {
  AppData({
    this.nodes = const [],
    this.subscriptions = const [],
    this.selectedIndex = -1,
    this.mixedPort = 7890,
    this.clashApiPort = 9090,
    this.singBoxPath = '',
    this.systemProxy = true,
    this.enableTun = false,
  });

  List<NodeInfo> nodes;
  List<Subscription> subscriptions;
  int selectedIndex;
  int mixedPort;

  /// Port of the sing-box Clash API controller (127.0.0.1:<port>).
  int clashApiPort;

  /// Empty means the managed core (downloaded into the data dir).
  String singBoxPath;
  bool systemProxy;

  /// TUN inbound (virtual NIC). Needs an elevated process on
  /// Windows; applied when the core (re)starts.
  bool enableTun;

  NodeInfo? get selected =>
      (selectedIndex >= 0 && selectedIndex < nodes.length)
          ? nodes[selectedIndex]
          : null;
}

class Store {
  Store([File? file]) : _file = file ?? _defaultFile();

  final File _file;
  File get file => _file;

  static File _defaultFile() {
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      return File('$appData\\Tokiboshi\\data.json');
    }
    return File('tokiboshi-data.json');
  }

  /// Directory that holds data.json; runtime config.json goes here too.
  Directory get dir => _file.parent;

  Future<AppData> load() async {
    try {
      if (!await _file.exists()) return AppData();
      final map = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      final nodes = (map['nodes'] as List<dynamic>? ?? [])
          .map((e) => NodeInfo.fromJson(e as Map<String, dynamic>))
          .toList();
      final subscriptions = (map['subscriptions'] as List<dynamic>? ?? [])
          .map((e) => Subscription.fromJson(e as Map<String, dynamic>))
          .toList();
      return AppData(
        nodes: nodes,
        subscriptions: subscriptions,
        selectedIndex: (map['selectedIndex'] as int?) ?? -1,
        mixedPort: (map['mixedPort'] as int?) ?? 7890,
        clashApiPort: (map['clashApiPort'] as int?) ?? 9090,
        singBoxPath: (map['singBoxPath'] as String?) ?? '',
        systemProxy: (map['systemProxy'] as bool?) ?? true,
        enableTun: (map['enableTun'] as bool?) ?? false,
      );
    } catch (_) {
      return AppData();
    }
  }

  Future<void> save(AppData data) async {
    await dir.create(recursive: true);
    final map = {
      'nodes': data.nodes.map((n) => n.toJson()).toList(),
      'subscriptions': data.subscriptions.map((s) => s.toJson()).toList(),
      'selectedIndex': data.selectedIndex,
      'mixedPort': data.mixedPort,
      'clashApiPort': data.clashApiPort,
      'singBoxPath': data.singBoxPath,
      'systemProxy': data.systemProxy,
      'enableTun': data.enableTun,
    };
    await _file.writeAsString(jsonEncode(map));
  }

  /// Write the generated sing-box config next to data.json and return
  /// its file (the Rust layer starts the core with this path).
  Future<File> writeRuntimeConfig(String configJson) async {
    await dir.create(recursive: true);
    final configFile = File('${dir.path}\\config.json');
    await configFile.writeAsString(configJson);
    return configFile;
  }
}

/// Resolve the sing-box executable: explicit setting, then the
/// managed core in the data dir, then next to the app executable
/// (legacy bundles), then bare name for PATH lookup.
String resolveSingBoxPath(String configured, String dataDir) {
  if (configured.isNotEmpty) return configured;
  final sep = Platform.isWindows ? '\\' : '/';
  final managed = '$dataDir${sep}core${sep}sing-box.exe';
  if (File(managed).existsSync()) return managed;
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final bundled = '$exeDir\\sing-box.exe';
  if (File(bundled).existsSync()) return bundled;
  return 'sing-box.exe';
}
