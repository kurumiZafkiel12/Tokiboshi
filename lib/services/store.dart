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
import '../ui/preferences.dart';
import 'desktop_settings.dart';

/// Thrown when a save cannot be committed to main OR the backup (e.g.
/// a Windows file lock). The newest data survives in the tmp file and
/// is recovered by [Store.load] — but callers must treat the save as
/// FAILED, not silently continue (HV003-01).
class StoreSaveException implements Exception {
  StoreSaveException(this.message);
  final String message;
  @override
  String toString() => message;
}

class Subscription {
  const Subscription({
    required this.id,
    required this.name,
    required this.url,
    this.updatedAt,
    this.lastReport,
    this.profileJson,
    this.profileState,
    this.nodesOnly = false,
    this.localPath,
    this.inlineContent,
  });
  final String id;
  final String name;
  final String url;

  /// ISO-8601 time of the last successful update.
  final String? updatedAt;
  final String? lastReport;

  /// T069: serialized ParsedProfile carried by this subscription
  /// (rules / rule-providers / DNS). Null = 仅节点订阅。
  final String? profileJson;

  /// downloaded / parsed / saved / pending-applied / applied —
  /// persisted so the UI can show an honest lifecycle.
  final String? profileState;
  final bool nodesOnly;
  final String? localPath, inlineContent;
  bool get isRemote => localPath == null && inlineContent == null;

  Subscription copyWith(
          {String? name,
          String? url,
          String? updatedAt,
          String? lastReport,
          String? profileJson,
          String? profileState,
          bool? nodesOnly,
          String? localPath,
          String? inlineContent}) =>
      Subscription(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        updatedAt: updatedAt ?? this.updatedAt,
        lastReport: lastReport ?? this.lastReport,
        profileJson: profileJson ?? this.profileJson,
        profileState: profileState ?? this.profileState,
        nodesOnly: nodesOnly ?? this.nodesOnly,
        localPath: localPath ?? this.localPath,
        inlineContent: inlineContent ?? this.inlineContent,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'updatedAt': updatedAt,
        'lastReport': lastReport,
        'profileJson': profileJson,
        'profileState': profileState,
        'nodesOnly': nodesOnly,
        'localPath': localPath,
        'inlineContent': inlineContent,
      };

  factory Subscription.fromJson(Map<String, dynamic> json) => Subscription(
        id: json['id'] as String,
        name: json['name'] as String,
        url: json['url'] as String,
        updatedAt: json['updatedAt'] as String?,
        lastReport: json['lastReport'] as String?,
        profileJson: json['profileJson'] as String?,
        profileState: json['profileState'] as String?,
        nodesOnly: json['nodesOnly'] as bool? ?? false,
        localPath: json['localPath'] as String?,
        inlineContent: json['inlineContent'] as String?,
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
    this.resumeConnect = false,
    this.ui = const UiPreferences(),
    this.activeProfileId,
    this.desktop = const DesktopSettings(),
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

  /// One-shot connect intent for elevated-restart handoff (CV007-01):
  /// set right before a UAC relaunch so the elevated instance connects
  /// regardless of the autoConnect preference, then consumed on load.
  /// Never set by the daily auto-connect path.
  bool resumeConnect;

  UiPreferences ui;
  DesktopSettings desktop;

  /// null: legacy unique-source inference; empty: explicit built-in template.
  String? activeProfileId;

  NodeInfo? get selected => (selectedIndex >= 0 && selectedIndex < nodes.length)
      ? nodes[selectedIndex]
      : null;

  /// Deep-enough snapshot for the elevated-relaunch rollback: lists
  /// copied, scalars copied (CV007-03/04).
  AppData copyWith() => AppData(
        nodes: List.of(nodes),
        subscriptions: List.of(subscriptions),
        selectedIndex: selectedIndex,
        mixedPort: mixedPort,
        clashApiPort: clashApiPort,
        singBoxPath: singBoxPath,
        systemProxy: systemProxy,
        autoConnect: autoConnect,
        enableTun: enableTun,
        blockAds: blockAds,
        bypassCn: bypassCn,
        clashApiSecret: clashApiSecret,
        cleanExit: cleanExit,
        runningAtExit: runningAtExit,
        resumeConnect: resumeConnect,
        ui: ui,
        desktop: desktop,
        activeProfileId: activeProfileId,
      );
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

  /// True when [a] was modified after [b] (or [b] is unreadable).
  Future<bool> _isNewer(File a, File b) async {
    try {
      final am = await a.lastModified();
      try {
        final bm = await b.lastModified();
        return am.isAfter(bm);
      } catch (_) {
        return true;
      }
    } catch (_) {
      return false;
    }
  }

  Future<AppData> load() async {
    final primary = await _tryLoad(_file);
    // A failed save leaves the newest data in the tmp file (HV003-01):
    // prefer it, but only when it parses AND is newer than main — a
    // stale tmp must not shadow a healthy main (Hermes v0.0.4 check).
    final fromTmp = await _tryLoad(_tmpFile);
    if (fromTmp != null &&
        (primary == null || await _isNewer(_tmpFile, _file))) {
      try {
        await _tmpFile.rename(_file.path);
      } catch (_) {
        try {
          await _tmpFile.copy(_file.path);
        } catch (_) {
          // Recovery is best effort; the parsed tmp data is returned
          // either way and the next successful save rewrites main.
        }
      }
      return fromTmp;
    }
    if (primary != null) return primary;
    // The main file is missing or unreadable: fall back to the last
    // known good copy instead of starting from an empty state.
    final backup = await _tryLoad(_bakFile);
    if (backup != null) {
      // Repair the main copy from the backup right away; otherwise
      // the next save() would rotate the still-corrupt main file
      // into .bak and destroy the only good copy (HF053-11). If the
      // repair fails (e.g. read-only main), save() validates before
      // rotating and quarantines the bad file instead.
      try {
        await _bakFile.copy(_file.path);
      } catch (_) {
        // Repair is best effort; save() validates before rotating.
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
      final migratedRunningAtExit = (map['autoConnect'] as bool?) == true;
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
        resumeConnect: (map['resumeConnect'] as bool?) ?? false,
        ui: UiPreferences.fromJson(map['ui']),
        desktop: DesktopSettings.fromJson(map['desktop']),
        activeProfileId: map['activeProfileId'] is String
            ? map['activeProfileId'] as String
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// Serializes save() calls so two rapid saves cannot interleave
  /// the tmp/rename rotation.
  Future<void> _saveQueue = Future.value();

  /// Validate the current main file. A corrupt main must NEVER be
  /// rotated into the backup (HF053-11: repair-failure scenario).
  Future<bool> _mainIsHealthy() async {
    if (!await _file.exists()) return false;
    return await _tryLoad(_file) != null;
  }

  Future<void> save(AppData data) {
    final next = _saveQueue.then((_) => _saveNow(data));
    _saveQueue = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<void> _saveNow(AppData data) async {
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
      'resumeConnect': data.resumeConnect,
      'ui': data.ui.toJson(),
      'desktop': data.desktop.toJson(),
      'activeProfileId': data.activeProfileId,
    };
    // Rotation: previous main BECOMES the backup (rename, not copy),
    // then tmp becomes main. An unhealthy main is quarantined as
    // .corrupt instead — and the existing good backup is NOT touched
    // before the branch is decided (deleting it up front was exactly
    // the HF053-11 failure mode Hermes reproduced). The tmp write is
    // inside the try: when it fails the direct-rewrite fallback below
    // still runs before the save is reported as failed (HV003-01).
    final mainHealthy = await _mainIsHealthy();
    try {
      await _tmpFile.writeAsString(jsonEncode(map), flush: true);
      if (mainHealthy) {
        // Move the current backup aside BEFORE touching main: if main
        // is locked and its rename fails, the backup is restored and
        // never lost (HV003-01 remainder — the old code deleted .bak
        // first and then failed to move main into place).
        File? movedBak;
        if (await _bakFile.exists()) {
          final oldPath = '${_bakFile.path}.old';
          try {
            await _bakFile.rename(oldPath);
            movedBak = File(oldPath);
          } catch (_) {
            movedBak = null; // stays in place; the rename below may still work
          }
        }
        try {
          if (await _file.exists()) {
            await _file.rename(_bakFile.path);
          }
        } catch (_) {
          // main is locked: put the backup back, then give up on the
          // rotation and use the direct-rewrite fallback with the
          // backup intact.
          if (movedBak != null) {
            try {
              await movedBak.rename(_bakFile.path);
            } catch (_) {
              try {
                await movedBak.copy(_bakFile.path);
              } catch (_) {}
            }
          }
          rethrow;
        }
        if (movedBak != null) {
          try {
            await movedBak.delete();
          } catch (_) {}
        }
      } else if (await _file.exists()) {
        try {
          await _file.rename('${_file.path}.corrupt');
        } catch (_) {
          try {
            await _file.delete();
          } catch (_) {}
        }
      }
      await _tmpFile.rename(_file.path);
    } catch (rotateError) {
      // Fallback: direct rewrite of main. When this ALSO fails (file
      // lock), the save has failed: tell the caller instead of
      // pretending it worked (HV003-01). The new data stays in tmp —
      // load() recovers it before touching the backup.
      try {
        await _file.writeAsString(jsonEncode(map), flush: true);
        if (await _tmpFile.exists()) {
          try {
            await _tmpFile.delete();
          } catch (_) {}
        }
      } catch (writeError) {
        throw StoreSaveException(
          '配置写入失败（主文件与回退路径均不可用）：$writeError（轮换阶段：$rotateError）。'
          '新数据已保留在临时文件，下次启动自动恢复；最后一份有效备份未受影响。',
        );
      }
    }
  }

  /// Write the generated sing-box config next to data.json and return
  /// its file (the Rust layer starts the core with this path).
  Future<File> writeRuntimeConfig(String configJson) async {
    await dir.create(recursive: true);
    final configFile = File('${dir.path}${Platform.pathSeparator}config.json');
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
  final clashApi = (experimental['clash_api'] as Map<String, dynamic>?) ??
      <String, dynamic>{};
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
