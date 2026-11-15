/// Tiny JSON file persistence for the Windows app.
///
/// Data lives in `%APPDATA%\Tokiboshi\data.json`; when APPDATA is not
/// available it falls back to `./tokiboshi-data.json`. The v0.1 format
/// (nodes/settings only) loads unchanged; subscriptions and the
/// system-proxy flag default when absent.
///
/// Writes are atomic (temp file + rename) and the previous good copy
/// is kept as `data.json.bak`, so a crash mid-save or a corrupted
/// file can never silently wipe the user's nodes and subscriptions.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../bridge/core_bridge.dart';

class Subscription {
  const Subscription({
    required this.id,
    required this.name,
    required this.url,
    this.updatedAt,
    this.lastReport,
  });

  final String id;
  final String name;
  final String url;

  /// ISO-8601 time of the last successful update.
  final String? updatedAt;
  final String? lastReport;

  Subscription copyWith({String? name, String? url, String? updatedAt, String? lastReport}) =>
      Subscription(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        updatedAt: updatedAt ?? this.updatedAt,
        lastReport: lastReport ?? this.lastReport,
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'url': url, 'updatedAt': updatedAt, 'lastReport': lastReport};

  factory Subscription.fromJson(Map<String, dynamic> json) => Subscription(
        id: json['id'] as String,
        name: json['name'] as String,
        url: json['url'] as String,
        updatedAt: json['updatedAt'] as String?,
        lastReport: json['lastReport'] as String?,
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
    this.autoConnect = true,
    this.enableTun = false,
    this.blockAds = true,
    this.bypassCn = true,
    String? clashApiSecret,
    this.cleanExit = true,
    this.runningAtExit = false,
  }) : clashApiSecret = clashApiSecret ?? '';

  List<NodeInfo> nodes;
  List<Subscription> subscriptions;
  int selectedIndex;
  int mixedPort;

  /// Port of the sing-box Clash API controller (127.0.0.1:<port>).
  int clashApiPort;

  /// Empty means the managed core (downloaded into the data dir).
  String singBoxPath;
  bool systemProxy;

  /// Start the core with the saved node when the application opens.
  bool autoConnect;

  /// TUN inbound (virtual NIC). Needs an elevated process on
  /// Windows; applied when the core (re)starts.
  bool enableTun;

  /// Route rule options (applied when the core (re)starts).
  bool blockAds;
  bool bypassCn;

  /// Bearer secret for the local Clash API controller; generated once
  /// per installation and injected into the generated core config.
  String clashApiSecret;

  /// True when the previous app run ended through the normal quit
  /// path. False means the last run crashed or was killed — the next
  /// startup then checks for a stale system proxy left pointing at
  /// the dead local port.
  bool cleanExit;

  /// Whether the core was running when the app last quit cleanly.
  /// "自动连接" then means restore that state — never auto-start
  /// after a crash (predictable, FlClash-style semantics).
  bool runningAtExit;

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

  File get _bakFile => File('${_file.path}.bak');
  File get _tmpFile => File('${_file.path}.tmp');

  Future<AppData> load() async {
    final primary = await _tryLoad(_file);
    if (primary != null) return primary;
    // The main file is missing or unreadable: fall back to the last
    // known good copy instead of starting from an empty state.
    final backup = await _tryLoad(_bakFile);
    if (backup != null) {
      // Repair the main copy from the backup right away; otherwise
      // the next save() would rotate the still-corrupt main file
      // into .bak and destroy the only good copy (HF053-11).
      try {
        await _bakFile.copy(_file.path);
      } catch (_) {
        // Repair is best effort; save() will rewrite main anyway.
      }
      return backup;
    }
    // Preserve the broken file for inspection, then start fresh.
    if (await _file.exists()) {
      try {
        await _file.rename('${_file.path}.corrupt');
      } catch (_) {
        // Best effort; a wedged file will be overwritten by save().
      }
    }
    return AppData();
  }

  Future<AppData?> _tryLoad(File file) async {
    try {
      if (!await file.exists()) return null;
      final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final nodes = (map['nodes'] as List<dynamic>? ?? [])
          .map((e) => NodeInfo.fromJson(e as Map<String, dynamic>))
          .toList();
      final subscriptions = (map['subscriptions'] as List<dynamic>? ?? [])
          .map((e) => Subscription.fromJson(e as Map<String, dynamic>))
          .toList();
      final runningAtExitRaw = map['runningAtExit'] as bool?;
      // Migration: data written before the runningAtExit flag existed
      // had autoConnect mean "always auto-start"; keep that behavior
      // instead of silently never auto-starting after an upgrade.
      final migratedRunningAtExit =
          (map['autoConnect'] as bool?) == true;
      return AppData(
        nodes: nodes,
        subscriptions: subscriptions,
        selectedIndex: (map['selectedIndex'] as int?) ?? -1,
        mixedPort: (map['mixedPort'] as int?) ?? 7890,
        clashApiPort: (map['clashApiPort'] as int?) ?? 9090,
        singBoxPath: (map['singBoxPath'] as String?) ?? '',
        systemProxy: (map['systemProxy'] as bool?) ?? true,
        autoConnect: (map['autoConnect'] as bool?) ?? true,
        enableTun: (map['enableTun'] as bool?) ?? false,
        blockAds: (map['blockAds'] as bool?) ?? true,
        bypassCn: (map['bypassCn'] as bool?) ?? true,
        clashApiSecret: (map['clashApiSecret'] as String?) ?? '',
        cleanExit: (map['cleanExit'] as bool?) ?? true,
        runningAtExit: runningAtExitRaw ?? migratedRunningAtExit,
      );
    } catch (_) {
      return null;
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
      'autoConnect': data.autoConnect,
      'enableTun': data.enableTun,
      'blockAds': data.blockAds,
      'bypassCn': data.bypassCn,
      'clashApiSecret': data.clashApiSecret,
      'cleanExit': data.cleanExit,
      'runningAtExit': data.runningAtExit,
    };
    // Atomic rotation: the previous main file BECOMES the backup
    // (rename, not copy — a corrupt main can never pollute .bak,
    // HF053-11), then tmp becomes main. Between the two renames main
    // is briefly absent; load() falls back to the backup for that
    // window, and a failed rotation falls back to a direct rewrite.
    await _tmpFile.writeAsString(jsonEncode(map), flush: true);
    try {
      if (await _bakFile.exists()) {
        await _bakFile.delete();
      }
      if (await _file.exists()) {
        await _file.rename(_bakFile.path);
      }
      await _tmpFile.rename(_file.path);
    } catch (_) {
      // Windows rename can race an indexer; a direct rewrite is still
      // better than losing the data.
      await _file.writeAsString(jsonEncode(map), flush: true);
      if (await _tmpFile.exists()) {
        try {
          await _tmpFile.delete();
        } catch (_) {}
      }
    }
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

/// 32 hex chars from a cryptographically secure RNG — the Clash API
/// bearer secret used by the app, the panel and the core config.
String generateClashSecret() {
  final rng = Random.secure();
  return List.generate(32, (_) => rng.nextInt(16).toRadixString(16)).join();
}

/// Inject the Clash API secret into a generated sing-box config so
/// the controller on 127.0.0.1 requires a bearer token. Done on the
/// Dart side (which owns the secret and writes the runtime config)
/// so the Rust builder signature stays stable. Creates the
/// experimental.clash_api object when absent (test fakes).
String injectClashSecret(String configJson, String secret) {
  final config = jsonDecode(configJson) as Map<String, dynamic>;
  final experimental =
      (config['experimental'] as Map<String, dynamic>?) ?? <String, dynamic>{};
  final clashApi =
      (experimental['clash_api'] as Map<String, dynamic>?) ?? <String, dynamic>{};
  clashApi['secret'] = secret;
  experimental['clash_api'] = clashApi;
  config['experimental'] = experimental;
  return jsonEncode(config);
}

/// True when the current system proxy points at our own dead local
/// port — the signature of a proxy left behind by a crashed previous
/// run. Any other value belongs to the user or another tool and must
/// be left alone.
bool isStaleProxy(String? server, int port) {
  if (server == null) return false;
  final s = server.trim().toLowerCase();
  return s == '127.0.0.1:$port' || s == 'localhost:$port';
}
