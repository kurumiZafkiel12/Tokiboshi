/// Tiny JSON file persistence for the Windows app (v0.1).
///
/// Data lives in `%APPDATA%\Tokiboshi\data.json`; when APPDATA is not
/// available it falls back to `./tokiboshi-data.json`.
library;

import 'dart:convert';
import 'dart:io';

import '../bridge/core_bridge.dart';

class AppData {
  AppData({
    this.nodes = const [],
    this.selectedIndex = -1,
    this.mixedPort = 7890,
    this.singBoxPath = '',
  });

  List<NodeInfo> nodes;
  int selectedIndex;
  int mixedPort;

  /// Empty means "sing-box.exe next to Tokiboshi.exe, else PATH".
  String singBoxPath;

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
      return AppData(
        nodes: nodes,
        selectedIndex: (map['selectedIndex'] as int?) ?? -1,
        mixedPort: (map['mixedPort'] as int?) ?? 7890,
        singBoxPath: (map['singBoxPath'] as String?) ?? '',
      );
    } catch (_) {
      return AppData();
    }
  }

  Future<void> save(AppData data) async {
    await dir.create(recursive: true);
    final map = {
      'nodes': data.nodes.map((n) => n.toJson()).toList(),
      'selectedIndex': data.selectedIndex,
      'mixedPort': data.mixedPort,
      'singBoxPath': data.singBoxPath,
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

/// Resolve the sing-box executable: explicit setting, then next to the
/// app executable (the release bundle ships it there), then bare name
/// for PATH lookup.
String resolveSingBoxPath(String configured) {
  if (configured.isNotEmpty) return configured;
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final bundled = '$exeDir\\sing-box.exe';
  if (File(bundled).existsSync()) return bundled;
  return 'sing-box.exe';
}
