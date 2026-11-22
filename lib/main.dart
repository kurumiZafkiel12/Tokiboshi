import 'dart:convert';
import 'package:flutter/material.dart';

import 'dart:async';
import 'package:file_selector/file_selector.dart';
import 'services/client_preferences.dart';
import 'services/config_backup.dart';
import 'services/node_selection.dart';
import 'ui/subscription_editor.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'ui/preferences.dart';
import 'ui/design.dart';
import 'ui/runtime.dart';
import 'ui/node_widgets.dart';
import 'ui/shell_widgets.dart';
import 'pages/rules_page.dart';
import 'pages/toolbox_page.dart';
import 'pages/network_info.dart';
import 'pages/rule_resource_panel.dart';
import 'services/rule_resources.dart';
import 'pages/connections_page.dart';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app_version.dart';
import 'mobile/android_app.dart';
import 'bridge/core_bridge.dart';
import 'bridge/rust_core_bridge.dart';
import 'pages/dashboard_page.dart';
import 'pages/logs_page.dart';
import 'pages/nodes_page.dart';
import 'pages/panel_page.dart';
import 'pages/settings_page.dart';
import 'pages/subscriptions_page.dart';
import 'services/clash_api.dart';
import 'services/active_profile.dart';
import 'services/import_content.dart';
import 'services/import_io.dart';
import 'services/desktop_settings.dart';
import 'services/desktop_services.dart';
import 'ui/import_dialog.dart';
import 'ui/diagnostics.dart';
import 'services/latency.dart';
import 'services/local_ports.dart';
import 'services/elevated_handoff.dart';
import 'services/node_tags.dart';
import 'services/routing_targets.dart';
import 'services/proxy_chain.dart';
import 'services/store.dart';
import 'services/subscription_fetcher.dart';
import 'services/subscription_resolver.dart';
import 'services/system_proxy.dart';
import 'src/rust/frb_generated.dart';

/// Loopback port used as the single-instance lock. A second launch
/// finds the port taken, pokes the primary ("show"), and exits.
const int kInstanceLockPort = 46513;

/// The primary's lock listener. Closed EARLY during quit so a new
/// instance started while we exit can bind and take over instead of
/// acking against a dying primary and exiting itself (CV007-02).
ServerSocket? _instanceLock;

void _releaseInstanceLock() {
  try {
    _instanceLock?.close();
  } catch (_) {}
  _instanceLock = null;
}

/// Actions offered when the user enables/starts with TUN while the
/// app is not elevated.
enum _TunAction { relaunch, disableTun, cancel }

/// Windows elevation check: `net session` requires an elevated token
/// (exit 0 = admin). Cheap, no extra dependencies. Non-Windows is
/// always treated as elevated.
Future<bool> _isElevated() async {
  if (!Platform.isWindows ||
      Platform.environment['TOKIBOSHI_ELEVATED_RUNNER'] == '1') return true;
  try {
    final r = await Process.run('net', ['session']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<void> main(List<String> args) async {
  final handoff = args.where((a) => a.startsWith('--wait-parent=')).toList();
  if (handoff.isNotEmpty) {
    final parent = handoff.length == 1
        ? int.tryParse(handoff.single.split('=').last)
        : null;
    if (parent == null || !await waitForParentExit(parent)) {
      stderr.writeln('提权交接未完成：原实例尚未退出');
      exitCode = 1;
      return;
    }
  }
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    await RustLib.init();
    runApp(await AndroidApp.create());
    return;
  }
  if (Platform.isWindows) {
    // Single instance (user report: two copies could run at once and
    // fight over the same kernel/ports). The lock is a dedicated
    // loopback port — no files, no races.
    ServerSocket? lock;
    try {
      lock = await ServerSocket.bind(
          InternetAddress.loopbackIPv4, kInstanceLockPort);
    } catch (_) {
      lock = null;
    }
    if (lock != null) {
      _instanceLock = lock;
      // Primary instance: only answer a signed poke (HV001-03) — an
      // unrelated service may hold some other port, so the second
      // instance requires an ack before it exits.
      lock.listen((socket) {
        socket.listen((data) async {
          if (String.fromCharCodes(data).contains('tokiboshi-show')) {
            socket.write('tokiboshi-ok');
            try {
              await socket.flush();
              // Give the peer a moment to read the ack before the
              // socket goes away.
              await Future<void>.delayed(const Duration(milliseconds: 120));
            } catch (_) {}
            socket.destroy();
            windowManager.show().catchError((_) {});
            windowManager.focus().catchError((_) {});
          }
        }, onDone: socket.destroy);
      });
    } else {
      var woke = false;
      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          kInstanceLockPort,
          timeout: const Duration(milliseconds: 800),
        );
        try {
          socket.write('tokiboshi-show');
          final ack =
              await socket.first.timeout(const Duration(milliseconds: 800));
          woke = String.fromCharCodes(ack).contains('tokiboshi-ok');
        } finally {
          // Always release the probe socket, even on ack timeout —
          // leaving it open kept a test event loop alive (Hermes
          // v0.0.2 recheck observation).
          socket.destroy();
        }
      } catch (_) {
        // No valid ack: the port is held by something that is not
        // Tokiboshi. Start unlocked rather than refusing to run.
      }
      if (woke) {
        exit(0);
      }
    }
  }
  try {
    await windowManager.ensureInitialized();
    if (Platform.isWindows) {
      await windowManager.setTitle('Tokiboshi · 時の星');
      await windowManager.setMinimumSize(const Size(800, 600));
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden,
          windowButtonVisibility: false);
    }
  } catch (_) {
    // Window/tray niceties are optional; never block startup.
  }
  await RustLib.init();
  runApp(TokiboshiApp(
      bridge: RustCoreBridge(), launchedAtLogin: args.contains('--autostart')));
}

class TokiboshiApp extends StatefulWidget {
  const TokiboshiApp({
    super.key,
    required this.bridge,
    this.store,
    this.systemProxy,
    this.fetcher,
    this.allocatePort = findAvailablePort,
    this.importIo = const ImportIo(),
    this.launchedAtLogin = false,
    this.startup,
    this.updateClient = const UpdateClient(),
    this.processProbe,
  });

  final CoreBridge bridge;
  final Store? store;
  final SystemProxy? systemProxy;
  final SubscriptionFetcher? fetcher;
  final PortAllocator allocatePort;
  final ImportIo importIo;
  final bool launchedAtLogin;
  final WindowsStartup? startup;
  final UpdateClient updateClient;
  final Future<Set<String>> Function()? processProbe;

  @override
  State<TokiboshiApp> createState() => _TokiboshiAppState();
}

class _TokiboshiAppState extends State<TokiboshiApp> {
  final _appearance = ValueNotifier(const UiPreferences());
  late final Store _store = widget.store ?? Store();
  late final SystemProxy _systemProxy =
      widget.systemProxy ?? const WindowsSystemProxy();
  late final SubscriptionFetcher _fetcher =
      widget.fetcher ?? const HttpSubscriptionFetcher();
  bool get _reduceMotion =>
      _appearance.value.motion == 'reduced' ||
      (_appearance.value.followSystem &&
          WidgetsBinding.instance.platformDispatcher.accessibilityFeatures
              .disableAnimations);
  @override
  void dispose() {
    _appearance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: _appearance,
      builder: (context, _) => UiScope(
          controller: _appearance,
          onChanged: (v) => _appearance.value = v,
          child: MaterialApp(
              debugShowCheckedModeBanner: false,
              title: 'Tokiboshi',
              themeAnimationDuration: _reduceMotion
                  ? Duration.zero
                  : Duration(
                      milliseconds:
                          _appearance.value.motion == 'standard' ? 140 : 220),
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: _reduceMotion),
                  child: child!),
              theme: workbenchTheme(_appearance.value),
              home: ShellPage(
                  bridge: widget.bridge,
                  allocatePort: widget.allocatePort,
                  store: _store,
                  systemProxy: _systemProxy,
                  fetcher: _fetcher,
                  appearance: _appearance,
                  importIo: widget.importIo,
                  launchedAtLogin: widget.launchedAtLogin,
                  startup: widget.startup,
                  updateClient: widget.updateClient,
                  processProbe: widget.processProbe))));
}

class ShellPage extends StatefulWidget {
  const ShellPage({
    super.key,
    required this.bridge,
    required this.store,
    required this.systemProxy,
    required this.fetcher,
    required this.allocatePort,
    required this.appearance,
    this.importIo = const ImportIo(),
    this.launchedAtLogin = false,
    this.startup,
    this.updateClient = const UpdateClient(),
    this.processProbe,
  });

  final CoreBridge bridge;
  final Store store;
  final SystemProxy systemProxy;
  final SubscriptionFetcher fetcher;
  final PortAllocator allocatePort;
  final ValueNotifier<UiPreferences> appearance;
  final ImportIo importIo;
  final bool launchedAtLogin;
  final WindowsStartup? startup;
  final UpdateClient updateClient;
  final Future<Set<String>> Function()? processProbe;

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage>
    with WindowListener, TrayListener {
  AppData _data = AppData();
  final RuntimeMonitor _monitor = RuntimeMonitor();
  bool _updatingAll = false;
  bool _cancelConnect = false;
  bool _profileChanging = false;
  int _sourceSequence = 0;
  bool _coreBusy = false,
      _importing = false,
      _importCancelling = false,
      _importCommitting = false;
  bool _settingsBusy = false,
      _loaded = false,
      _checkingUpdate = false,
      _demandPolling = false,
      _demandOwned = false,
      _demandSuppressed = false,
      _demandMatch = false,
      _quitting = false;
  String? _updateStatus;
  ReleaseUpdate? _update;
  Timer? _demandTimer;
  late final WindowsStartup _startup = widget.startup ?? WindowsStartup(requestElevation: true);
  bool _running = false;
  bool _busy = false;
  bool _measuring = false;
  int _page = 0;
  int _settingsSection = 0;
  bool _navCollapsed = false;
  String? _message;
  String? _coreVersion;
  int _restartCount = 0;
  String? _lastExit;
  String? _clashMode;
  Timer? _statusTimer;
  Timer? _subscriptionTimer;
  bool _scheduledBusy = false;
  bool _resourcesBusy = false;
  List<RuleResource> _ruleResources = const [];
  final Map<String, DateTime> _lastSourceAttempt = {};
  final Map<NodeInfo, int?> _latency = {};

  DateTime? _coreDownSince;

  /// Set while a user-initiated stop is in effect, so the status
  /// poller cannot mistake a stopped core for a crashed one (and
  /// vice versa for recovery).
  bool _userStopped = false;

  String get _dataDir => widget.store.dir.path;
  ClashApiClient? _controller;
  ClashApiClient get _clash {
    if (_controller?.port != _data.clashApiPort ||
        _controller?.secret != _data.clashApiSecret) {
      _controller?.close();
      _controller = ClashApiClient(
          port: _data.clashApiPort, secret: _data.clashApiSecret);
    }
    return _controller!;
  }

  @override
  void initState() {
    super.initState();
    widget.appearance.addListener(_appearanceChanged);
    _load();
    _initTray();
    _statusTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _syncCoreStatus());
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _subscriptionTimer?.cancel();
    widget.appearance.removeListener(_appearanceChanged);
    _demandTimer?.cancel();
    _monitor.dispose();
    _controller?.close();
    super.dispose();
  }

  void _appearanceChanged() {
    if (!mounted) return;
    setState(() => _data.ui = widget.appearance.value);
    _persist();
  }

  Future<void> _load() async {
    _subscriptionTimer ??= Timer.periodic(
        const Duration(seconds: 30), (_) => unawaited(_scheduledUpdates()));
    final data = await widget.store.load();
    final running = await widget.bridge.coreRunning();
    if (!mounted) return;
    var changed = false;
    // Snapshot how the PREVIOUS run ended before mutating anything:
    // the auto-connect decision below must not rely on this run's
    // in-progress flags (HV001-01).
    final previousCleanExit = data.cleanExit;
    // First run (or pre-secret data): mint the controller secret.
    if (data.clashApiSecret.isEmpty) {
      data.clashApiSecret = generateClashSecret();
      changed = true;
    }
    // A previous run that did not quit cleanly may have left the
    // system proxy pointing at its dead local port ("no internet").
    // Clear it only when it matches OUR port; anything else belongs
    // to the user or another tool.
    if (!previousCleanExit) {
      try {
        final server = await widget.systemProxy.readProxyServer();
        if (isStaleProxy(server, data.mixedPort)) {
          await widget.systemProxy.apply(false, data.mixedPort);
          _message = _compose('检测到上次异常退出遗留的系统代理，已自动关闭');
        }
      } catch (_) {
        // Best effort; the core startup path reports real failures.
      }
    }
    // From here until a clean quit this run counts as unclean.
    if (data.cleanExit) changed = true;
    data.cleanExit = false;
    if (changed) await widget.store.save(data);
    if (!mounted) return;
    setState(() {
      _data = data;
      _running = running;
      _loaded = true;
    });
    widget.appearance.value = data.ui;
    if (data.desktop.launchAtLogin && Platform.isWindows && widget.startup == null) {
      unawaited(_migrateLoginStartup());
    }
    unawaited(_loadRuleResources());
    // Rule-set upkeep is decoupled from the core download (HF053-02):
    // the bundled core must never skip it. Fire-and-forget; the Rust
    // side reports progress through the Logs page.
    unawaited(_ensureCoreAndRules());
    await _refreshCoreVersion();
    // 自动连接 = 上一次正常退出且内核在运行（崩溃后不自启，HV001-01）。
    // TUN 开着但应用非管理员时跳过自动连接：提权需要用户在点「启动」
    // 时确认（启动时弹 UAC 不适合在自动连接里静默触发）。
    // resumeConnect 是提权重启的一次性意图（CV007-01）：无视
    // autoConnect 偏好恢复连接，用后即清。
    final tunBlocked = _data.enableTun && !await _isElevated();
    final resumeRequested = _data.resumeConnect;
    if (_data.resumeConnect) {
      _data.resumeConnect = false;
      if (!await _persist()) return;
    }
    if (mounted &&
        !_running &&
        _data.nodes.isNotEmpty &&
        (_data.desktop.autoRun ||
            (previousCleanExit && _data.autoConnect && _data.runningAtExit) ||
            resumeRequested)) {
      if (tunBlocked) {
        _setMessage('自动连接已跳过：虚拟网卡需要管理员权限，请点「启动」并选择「以管理员身份重启」');
        // Persist the consumption so the next load does not retry the
        // same blocked auto-connect (CV007-01 remainder).
        await _persist();
      } else {
        await _toggleCore();
      }
    }
    _configureDemand();
    _hideForSilentStartup();
    if (Platform.isWindows && _data.desktop.autoCheckUpdates)
      unawaited(_checkUpdates(automatic: true));
  }

  Future<void> _refreshCoreVersion() async {
    try {
      final path = resolveSingBoxPath(_data.singBoxPath, _dataDir);
      final v = await widget.bridge.coreVersion(path);
      if (mounted) setState(() => _coreVersion = v);
    } catch (_) {
      if (mounted) setState(() => _coreVersion = null);
    }
  }

  /// Keep the UI truthful about the supervised core (unified state
  /// machine, HF053-05): a restart blip is tolerated for a few
  /// seconds, an auto-restart recovers the UI and system proxy, and
  /// only a sustained stop (or a user stop) tears the proxy down.
  bool _handoffInProgress = false;

  Future<void> _syncCoreStatus() async {
    if (_handoffInProgress) return;
    try {
      final status = await widget.bridge.coreStatus();
      if (!mounted) return;
      var changed =
          status.restartCount != _restartCount || status.lastExit != _lastExit;
      if (_running && !status.running) {
        // The supervisor may restart the core within seconds; do not
        // tear the proxy down on the first blip.
        _coreDownSince ??= DateTime.now();
        final downFor = DateTime.now().difference(_coreDownSince!);
        if (_userStopped || downFor > const Duration(seconds: 8)) {
          _running = false;
          _latency.clear();
          _clashMode = null;
          _coreDownSince = null;
          changed = true;
          await widget.systemProxy.apply(false, _data.mixedPort);
          _message = _compose(
              status.lastExit != null ? '内核已退出：${status.lastExit}' : '内核已停止');
        }
      } else if (status.running && !_running && !_userStopped) {
        // Supervisor restarted the core on its own: recover the UI
        // and the system proxy instead of staying stuck on "stopped".
        _running = true;
        _coreDownSince = null;
        changed = true;
        if (_data.systemProxy) {
          await widget.systemProxy.apply(true, _data.mixedPort);
        }
        _message = _compose('内核已自动重启，代理已恢复');
      } else if (status.running && _running) {
        _coreDownSince = null;
      }
      if (changed) {
        setState(() {
          _restartCount = status.restartCount;
          _lastExit = status.lastExit;
        });
        _refreshTray();
      }
      if (_running && status.running) {
        try {
          final mode = await _clash.mode();
          if (mounted && mode != null && mode != _clashMode) {
            setState(() => _clashMode = mode);
            _refreshTray();
          }
        } catch (_) {
          // Clash API not up yet (UI download can take a while).
        }
      }
    } catch (_) {
      // Status polling is best-effort.
    }
  }

  /// True while the last persist attempt failed. Appended to every
  /// status message so a save failure is never masked by a later
  /// success message (HV003-01 UI subitem).
  bool _saveFailed = false;

  /// Compose a status message with the save-failure warning when the
  /// last write failed.
  String _compose(String text) =>
      text + (_saveFailed ? '（⚠ 配置保存失败，重启后设置将回退）' : '');

  /// Persist [AppData]. Returns false (and surfaces the error on the
  /// status bar) when the write failed — callers compose their
  /// runtime-applied messages with this result so "runtime applied"
  /// and "settings saved" are presented separately (HV003-01).
  Future<bool> _persist() async {
    try {
      await widget.store.save(_data);
      if (_saveFailed) {
        _saveFailed = false;
        if (mounted) setState(() {});
      }
      return true;
    } catch (e) {
      _saveFailed = true;
      _setMessage('配置保存失败：$e');
      return false;
    }
  }

  void _setMessage(String? text) {
    if (mounted) {
      setState(() => _message = text == null ? null : _compose(text));
      if (widget.launchedAtLogin &&
          _data.desktop.silentStart &&
          text?.contains('失败') == true) windowManager.show().catchError((_) {});
    }
  }

  // ---- import / subscriptions ----

  /// 当前活跃连接的进程名（去重；内核未启用进程识别时为空列表）。
  List<String> _activeProcesses() {
    final names = <String>{};
    for (final row in _monitor.connections) {
      final meta = row['metadata'];
      if (meta is! Map) continue;
      for (final key in ['processName', 'process_path', 'processPath']) {
        final v = meta[key];
        if (v is String && v.isNotEmpty) {
          names.add(v.split(Platform.pathSeparator).last);
          break;
        }
      }
    }
    return names.toList()..sort();
  }

  Future<void> _addProcessRule(String process, String target) async {
    if (_busy || _profileChanging || _settingsBusy) return;
    final before = _data.copyWith();
    final name = process.trim();
    try {
      final rule = RoutingRule(kind: 'process_name', value: name, target: target);
      if (target.isNotEmpty) rule.validate();
      final updated = _data.client.withRules([
        ..._data.client.rules.where((current) =>
            current.kind != 'process_name' ||
            current.value.toLowerCase() != name.toLowerCase()),
        if (target.isNotEmpty) rule,
      ]);
      updated.validate();
      setState(() {
        _settingsBusy = true;
        _data.client = updated;
      });
      if (await _persistImport(before)) {
        _setMessage('「$name」分流已保存，${_running ? '应用配置后生效' : '下次启动生效'}');
      }
    } catch (e) {
      _setMessage('保存分流失败：${redactDiagnostics('$e')}');
    } finally {
      if (mounted) setState(() => _settingsBusy = false);
    }
  }

  /// 内置分流模板规则的用户配置（开关 + 每条独立出站）。
  /// value：'off' = 关闭；'' = 启用+默认出站；'reject' / 'direct' /
  /// 'proxy' / 节点名 = 启用+指定出站。
  Future<void> _setTemplateRouting(String id, String value) async {
    if (_busy || _settingsBusy || _profileChanging) return;
    final before = _data.copyWith();
    setState(() {
      _settingsBusy = true;
      _data.templateRouting = {..._data.templateRouting, id: value};
    });
    try {
      if (await _persistImport(before)) {
        _setMessage('分流模板已保存，${_running ? '应用配置后生效' : '下次启动生效'}');
      }
    } finally {
      if (mounted) setState(() => _settingsBusy = false);
    }
  }

  Future<void> _importDialog({String initialMethod = 'link'}) async {
    if (_busy || _profileChanging || _settingsBusy) return;
    final request = await showDialog<ImportRequest>(
        context: context,
        builder: (context) =>
            ImportDialog(io: widget.importIo, initialMethod: initialMethod));
    if (request == null || !mounted || _busy || _settingsBusy || _profileChanging) return;
    final text = normalizeImportText(request.text);
    final lines = text
        .split('\n')
        .map((v) => normalizeImportText(v))
        .where((v) => v.isNotEmpty)
        .toList();
    final isLinkList = lines.isNotEmpty &&
        lines.every((v) => RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(v));
    if (isLinkList) {
      final remaining = <String>[];
      for (final line in lines) {
        if (isSubscriptionUrl(line)) {
          await _addSubscription(
              request.name.isEmpty ? Uri.parse(line).host : request.name, line);
          if (_importCancelling || !mounted) return;
        } else {
          remaining.add(line);
        }
      }
      if (remaining.isNotEmpty)
        await _addSubscription(request.name.isEmpty ? '本地导入' : request.name, '',
            content: remaining.join('\n'),
            manual: true);
    } else {
      await _addSubscription(request.name.isEmpty ? '本地导入' : request.name, '',
          content: text,
          localPath: request.localPath,
          manual: request.manual);
    }
  }

  Future<ParseOutcome> _fetchParseExpand(String url,
      {String? content,
      bool nodesOnly = false,
      bool interactive = true}) async {
    final fetcher = widget.fetcher is HttpSubscriptionFetcher
        ? HttpSubscriptionFetcher(
            verifyTls: _data.desktop.verifyTls,
            userAgent: _data.desktop.userAgent)
        : widget.fetcher;
    final resolver = SubscriptionResolver(
        bridge: widget.bridge,
        fetcher: fetcher,
        isCancelled: () => _importCancelling);
    try {
      final outcome = content == null
          ? await resolver.resolve(url, nodesOnly: nodesOnly)
          : await resolver.resolveContent(content, nodesOnly: nodesOnly);
      if (!outcome.nodes.any((n) => !n.isPolicy))
        throw const FormatException('没有识别到可用节点，请检查内容和来源诊断');
      return outcome;
    } on ProfileCompatibilityException catch (e) {
      if (!interactive) rethrow;
      if (!e.nodesOnlyOutcome.nodes.any((n) => !n.isPolicy)) rethrow;
      if (!mounted) rethrow;
      final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: const Text('节点可导入，完整规则暂不兼容'),
                  content: SizedBox(
                      width: 600,
                      child: SingleChildScrollView(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                            Text(
                                '已识别 ${e.nodesOnlyOutcome.nodes.where((n) => !n.isPolicy).length} 个节点。可以仅导入节点，使用应用内置规则；此来源的规则与 DNS 不会被应用。选择会保存，后续更新沿用。'),
                            const SizedBox(height: 16),
                            Text(redactDiagnostics(e.message),
                                style: Theme.of(context).textTheme.bodySmall)
                          ]))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消，保留原配置')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('仅导入节点'))
                  ]));
      if (accepted == true) return e.nodesOnlyOutcome;
      throw const ImportCancelled();
    }
  }

  Future<void> _createChainDialog() async {
    if (_running || _busy || _data.nodes.length < 2) return;
    var entry = 0;
    var exit = 1;
    String? error;
    final name = TextEditingController(text: '链式代理');
    final result = await showDialog<List<NodeInfo>>(
      context: context,
      builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
                title: const Text('添加链式代理'),
                content: SizedBox(
                    width: 460,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text(
                          '连接顺序：本机 → 前置节点 → 落地节点 → 目标网站。保存独立副本，不随原订阅更新。'),
                      const SizedBox(height: 12),
                      TextField(
                          controller: name,
                          decoration: const InputDecoration(labelText: '链名称')),
                      DropdownButtonFormField<int>(
                        initialValue: entry,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: '前置节点'),
                        items: [
                          for (var i = 0; i < _data.nodes.length; i++)
                            DropdownMenuItem(
                                value: i,
                                child: Text(_data.nodes[i].name,
                                    overflow: TextOverflow.ellipsis))
                        ],
                        onChanged: (value) =>
                            update(() => entry = value ?? entry),
                      ),
                      DropdownButtonFormField<int>(
                        initialValue: exit,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: '落地节点'),
                        items: [
                          for (var i = 0; i < _data.nodes.length; i++)
                            DropdownMenuItem(
                                value: i,
                                child: Text(_data.nodes[i].name,
                                    overflow: TextOverflow.ellipsis))
                        ],
                        onChanged: (value) =>
                            update(() => exit = value ?? exit),
                      ),
                      if (error != null)
                        Text(error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () {
                        try {
                          Navigator.pop(
                              context,
                              createProxyChain(
                                  _data.nodes, entry, exit, name.text));
                        } on FormatException catch (e) {
                          update(() => error = e.message);
                        }
                      },
                      child: const Text('添加')),
                ],
              )),
    );
    name.dispose();
    if (result == null || !mounted) return;
    setState(() {
      _data.nodes = [..._data.nodes, ...result];
      _data.selectedIndex = _data.nodes.length - 1;
      _message = _compose('链式代理已添加，已选择落地节点；请保留同组前置节点');
    });
    await _persist();
  }

  /// "；另有 N 个暂不支持已跳过（wireguard ×1）" or '' when none.
  String _skippedNote(List<String> skipped) {
    if (skipped.isEmpty) return '';
    return '；跳过/未完成 ${skipped.length} 项：${skipped.take(5).join('；')}'
        '${skipped.length > 5 ? '；其余 ${skipped.length - 5} 项' : ''}';
  }

  Future<void> _addSubscriptionDialog() => _importDialog();

  String _subscriptionReport(ParseOutcome outcome) {
    final counts = <String, int>{};
    for (final node in outcome.nodes) {
      if (node.isPolicy) continue;
      final group = node.group.isEmpty ? '内联节点' : node.group;
      counts[group] = (counts[group] ?? 0) + 1;
    }
    return [
      '策略组：${outcome.nodes.where((n) => n.isPolicy).length} 个',
      for (final entry in counts.entries) '${entry.key}：${entry.value} 个',
      ...outcome.skipped
    ].join('\n');
  }

  Future<bool> _persistImport(AppData before) async {
    final saved = await _persist();
    if (saved) return true;
    if (!mounted) return false;
    // Restore the entire snapshot: this transaction also protects client policies
    // and backup restoration, not only node/source imports.
    setState(() => _data = before);
    await _persist();
    _setMessage('导入保存失败，已恢复原节点与来源');
    return false;
  }

  Future<void> _addSubscription(String name, String url,
      {String? content, String? localPath, bool manual = false}) async {
    final before = _data.copyWith();
    setState(() {
      _busy = true;
      _importing = true;
      _importCancelling = false;
      _importCommitting = false;
    });
    _setMessage('正在读取并解析来源…');
    try {
      // 用户设定（2026-11-21）：订阅只导入节点，不再尝试识别来源规则 / DNS。
      final outcome =
          await _fetchParseExpand(url, content: content, nodesOnly: true);
      if (manual && outcome.profileJson == null) {
        if (_importCancelling) throw const ImportCancelled();
        _importCommitting = true;
        final nodes = resolvePolicyGroups(outcome.nodes);
        setState(() {
          _data.nodes = [..._data.nodes, ...nodes];
          if (_data.selectedIndex < 0) _data.selectedIndex = 0;
        });
        final saved = await _persistImport(before);
        if (!saved) return;
        _setMessage(
            '已导入 ${nodes.where((n) => !n.isPolicy).length} 个节点${saved ? '' : '（尚未保存）'}${_skippedNote(outcome.skipped)}${_running ? '；应用配置后可切换新节点' : ''}');
        return;
      }
      if (_importCancelling) throw const ImportCancelled();
      _importCommitting = true;
      final id =
          'sub-${DateTime.now().microsecondsSinceEpoch}-${_sourceSequence++}';
      final nodes = resolvePolicyGroups(
          outcome.nodes.map((n) => n.withSource(id)).toList());
      setState(() {
        _data.subscriptions = [
          ..._data.subscriptions,
          Subscription(
            id: id,
            name: name,
            url: url,
            nodesOnly: outcome.nodesOnly,
            localPath: localPath,
            inlineContent:
                content != null && localPath == null ? content : null,
            updatedAt: DateTime.now().toIso8601String(),
            lastReport: _subscriptionReport(outcome),
            profileJson: outcome.profileJson,
            profileState: outcome.profileJson == null ? 'nodes-only' : 'parsed',
          ),
        ];
        _data.nodes = [..._data.nodes, ...nodes];
        if (_data.selectedIndex < 0 && _data.nodes.isNotEmpty) {
          _data.selectedIndex = 0;
        }
        _message = _compose('正在保存订阅「$name」…');
      });
      if (!await _persistImport(before)) return;
      _setMessage(
          '订阅「$name」已添加：${nodes.where((n) => !n.isPolicy).length} 个节点${_skippedNote(outcome.skipped)}${_running ? '；应用配置后可切换新节点' : ''}');
    } on ImportCancelled {
      _importCancelling = true;
      _setMessage('已取消导入，原配置保留');
    } catch (e) {
      _setMessage('订阅添加失败：${redactDiagnostics('$e')}');
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _importing = false;
          _importCommitting = false;
        });
    }
  }

  Future<void> _updateSubscription(Subscription sub,
      {bool retryFull = false, bool automatic = false}) async {
    if (_busy || _profileChanging || _settingsBusy || _running) return;
    _lastSourceAttempt[sub.id] = DateTime.now();
    final before = _data.copyWith();
    setState(() {
      _busy = true;
      _importing = true;
      _importCancelling = false;
      _importCommitting = false;
    });
    _setMessage('正在读取并解析来源…');
    try {
      String? content = sub.inlineContent;
      if (sub.localPath != null) {
        final file = File(sub.localPath!);
        if (await file.length() > 8 * 1024 * 1024)
          throw const FormatException('配置文件过大');
        content = await file.readAsString();
      }
      // 仅节点设定：更新同样只取节点，不再尝试来源规则 / DNS。
      final outcome = await _fetchParseExpand(sub.url,
          content: content, nodesOnly: true, interactive: !automatic);
      String? previousActive;
      try {
        previousActive = activeProfile(_data)?.id;
      } catch (_) {}

      if (_importCancelling) throw const ImportCancelled();
      _importCommitting = true;
      final selected = _data.selected;
      final selectedFromSub = selected != null && selected.source == sub.id;
      var fresh = outcome.nodes.map((n) => n.withSource(sub.id)).toList();
      final retained = retainFailedSourceNodes(
          _data.nodes.where((n) => n.source == sub.id).toList(),
          fresh,
          outcome.failedGroups);
      fresh.addAll(retained);
      fresh = resolvePolicyGroups(fresh);
      setState(() {
        if (previousActive == sub.id && outcome.profileJson == null)
          _data.activeProfileId = '';
        _data.nodes = [
          for (final n in _data.nodes)
            if (n.source != sub.id) n,
          ...fresh,
        ];
        _data.subscriptions = [
          for (final s in _data.subscriptions)
            if (s.id == sub.id)
              Subscription(
                  id: s.id,
                  name: s.name,
                  url: s.url,
                  nodesOnly: outcome.nodesOnly,
                  localPath: s.localPath,
                  inlineContent: s.inlineContent,
                  refreshMinutes: s.refreshMinutes,
                  lastError: null,
                  lastAttemptAt: DateTime.now().toIso8601String(),
                  profileJson: outcome.profileJson,
                  profileState:
                      outcome.profileJson == null ? 'nodes-only' : 'parsed',
                  updatedAt: DateTime.now().toIso8601String(),
                  lastReport:
                      '${_subscriptionReport(outcome)}${retained.isEmpty ? '' : '\n保留上次成功获取的 ${retained.length} 个节点（相关来源更新失败）'}')
            else
              s,
        ];
        if (selected != null && !selectedFromSub) {
          _data.selectedIndex = _data.nodes.indexOf(selected);
        } else if (selectedFromSub) {
          final idx = restoredNodeIndex(selected,
              before.nodes.where((n) => n.source == sub.id).toList(), fresh);
          _data.selectedIndex = idx < 0 ? -1 : _data.nodes.indexOf(fresh[idx]);
        }
        _message = _compose('正在保存订阅「${sub.name}」…');
      });
      if (!await _persistImport(before)) return;
      _setMessage(
          '订阅「${sub.name}」已更新：${fresh.where((n) => !n.isPolicy).length} 个节点${_skippedNote(outcome.skipped)}${selectedFromSub && _data.selectedIndex < 0 ? '；原出口已变化或存在歧义，请重新选择节点' : ''}');
    } on ImportCancelled {
      _importCancelling = true;
      _setMessage('已取消更新，原配置保留');
    } catch (e) {
      final failure = redactDiagnostics('$e');
      if (mounted) {
        setState(() => _data.subscriptions = [
              for (final source in before.subscriptions)
                if (source.id == sub.id)
                  source.copyWith(
                      lastError: failure,
                      lastAttemptAt: DateTime.now().toIso8601String())
                else
                  source
            ]);
        await _persistImport(before);
      }
      _setMessage('订阅更新失败，保留上次有效配置：$failure');
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _importing = false;
          _importCommitting = false;
        });
    }
  }

  Future<void> _deleteSubscription(Subscription sub) async {
    if (_busy || _running || _profileChanging || _settingsBusy) return;
    final before = _data.copyWith();
    final selected = _data.selected;
    setState(() {
      _data.subscriptions = [
        for (final s in _data.subscriptions)
          if (s.id != sub.id) s,
      ];
      _data.nodes = [
        for (final n in _data.nodes)
          if (n.source != sub.id) n,
      ];
      _data.selectedIndex = selected == null || selected.source == sub.id
          ? (_data.nodes.isEmpty ? -1 : 0)
          : _data.nodes.indexOf(selected);
      _message = _compose('订阅「${sub.name}」已删除');
    });
    await _persistImport(before);
  }

  // ---- nodes ----

  String _nodeTag(NodeInfo node) {
    final nodes = profileNodes(_data);
    final index = nodes.indexOf(node);
    if (index < 0) throw const FormatException('节点不属于激活配置');
    return assignNodeTags(nodes.map((n) => n.name))[index];
  }

  Future<void> _selectNode(int index) async {
    if (_busy ||
        _profileChanging ||
        _settingsBusy ||
        index < 0 ||
        index >= _data.nodes.length) return;
    final before = _data.copyWith();
    final node = _data.nodes[index];
    try {
      if (!profileNodes(_data).contains(node)) {
        _setMessage('该节点不属于当前完整配置，请先在工作台切换配置');
        return;
      }
    } on FormatException catch (e) {
      _setMessage(e.message);
      return;
    }
    String? previousTag;
    bool attempted = false;
    final live = _running;
    setState(() => _settingsBusy = true);
    Future<void> rollbackLive() async {
      if (!live || !attempted || previousTag == null) return;
      attempted = false;
      try {
        await _clash.select('proxy', previousTag);
      } catch (_) {
        await widget.bridge.stopCore();
        await widget.systemProxy.apply(false, _data.mixedPort);
        if (mounted) setState(() => _running = false);
        throw StateError('无法回滚出口，已停止代理，请重新连接');
      }
    }

    try {
      if (live) {
        previousTag = await _clash.selectedOf('proxy');
        if (previousTag == null) throw const FormatException('无法确认当前出口');
        final target = _nodeTag(node);
        final group = (await _clash.proxies())['proxy'];
        if (group is Map && group['all'] is List && !(group['all'] as List).contains(target)) {
          _setMessage('此节点已保存。请在分流页应用配置后再切换。');
          return;
        }
        attempted = true;
        await _clash.select('proxy', target);
      }
      if (!mounted) return;
      setState(() => _data.selectedIndex = index);
      if (!await _persistImport(before)) {
        await rollbackLive();
        return;
      }
      if (live) {
        // sing-box 只把新连接路由到新 selector 成员；既有连接继续走
        // 旧出站（用户看到"还是上个节点"）。断开全部活动连接强制重连。
        try {
          await _clash.closeConnections();
        } catch (_) {
          // 连接清理失败不阻断切换本身
        }
      }
      _setMessage(
          live ? '已切换到 ${node.name}，旧连接已断开' : '已选择 ${node.name}');
      _refreshTray();
    } catch (e) {
      if (mounted) setState(() => _data = before);
      try {
        await rollbackLive();
      } catch (rollbackError) {
        _setMessage('切换失败：${redactDiagnostics('$rollbackError')}');
        return;
      }
      _setMessage('切换失败，原出口保留：${redactDiagnostics('$e')}');
    } finally {
      if (mounted) setState(() => _settingsBusy = false);
    }
  }

  Future<void> _deleteNode(int index) async {
    if (_busy ||
        _running ||
        _profileChanging ||
        _settingsBusy ||
        index < 0 ||
        index >= _data.nodes.length) return;
    final before = _data.copyWith();
    setState(() {
      _data.nodes = [..._data.nodes]..removeAt(index);
      if (_data.selectedIndex == index) {
        _data.selectedIndex = _data.nodes.isEmpty ? -1 : 0;
      } else if (_data.selectedIndex > index) {
        _data.selectedIndex -= 1;
      }
    });
    await _persistImport(before);
  }

  static const _udpProtocols = {'hysteria', 'hysteria2', 'tuic'};

  /// While the core runs, measure through the Clash API delay
  /// endpoint (the real outbound). While stopped, only TCP-based
  /// protocols can be probed honestly — a TCP connect to a UDP
  /// (hy2/tuic) port says nothing, so those are skipped instead of
  /// being reported as failures.
  Future<void> _migrateLoginStartup() async {
    try {
      if (!await _startup.isEnabled() && _data.desktop.launchAtLogin) {
        await _startup.setEnabled(true);
      }
    } catch (_) {
      _setMessage('无法迁移登录自启，请在常规设置重新启用');
    }
  }

  Future<int?> _sampleNodeQuality(NodeInfo node) async {
    if (!_running || !_data.nodes.contains(node)) return null;
    final port = _data.clashApiPort;
    final generation = _monitor.startedAt;
    final ms = await _clash.delay(_nodeTag(node),
        url: _data.client.testUrl, timeoutMs: _data.client.testTimeoutMs);
    if (!mounted || !_running || port != _data.clashApiPort ||
        generation != _monitor.startedAt) return null;
    return ms;
  }

  Future<void> _measureNode(NodeInfo node) async {
    if (_measuring) return;
    if (_running && !profileNodes(_data).contains(node)) {
      _setMessage('该节点不属于当前激活配置，无法通过运行内核测试');
      return;
    }
    if (!_running && _udpProtocols.contains(node.protocol)) {
      _setMessage('内核未启动：${node.protocol} 是 UDP 协议，测速需先启动内核');
      return;
    }
    _measuring = true;
    final ms = _running
        ? await _clash.delay(_nodeTag(node),
            url: _data.client.testUrl, timeoutMs: _data.client.testTimeoutMs)
        : await tcpLatency(node.server, node.serverPort);
    _measuring = false;
    if (mounted) setState(() => _latency[node] = ms);
  }

  Future<void> _measureAll({bool liveOnly = false}) async {
    if (_measuring || (liveOnly && !_running)) return;
    final session = _monitor.startedAt;
    _measuring = true;
    var skipped = 0;
    for (final node in List.of(_data.nodes)) {
      if (node.isPolicy && !liveOnly) continue;
      if (liveOnly && (!_running || _monitor.startedAt != session)) break;
      if (_running && !profileNodes(_data).contains(node)) continue;
      if (!_running && _udpProtocols.contains(node.protocol)) {
        skipped++;
        continue;
      }
      final ms = _running
          ? await _clash.delay(_nodeTag(node),
              url: _data.client.testUrl, timeoutMs: _data.client.testTimeoutMs)
          : await tcpLatency(node.server, node.serverPort);
      if (!mounted) {
        _measuring = false;
        return;
      }
      if (liveOnly && (!_running || _monitor.startedAt != session)) break;
      setState(() => _latency[node] = ms);
    }
    _measuring = false;
    if (skipped > 0) {
      _setMessage('已跳过 $skipped 个 UDP 协议节点（内核未启动时测不准），启动内核后可测全部');
    }
  }

  Future<void> _openExternalPanel() async {
    final url = panelUrl(_data.clashApiPort, _data.clashApiSecret);
    try {
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', url]);
      }
    } catch (e) {
      _setMessage('打开浏览器失败：$e（可手动访问 $url）');
    }
  }

  // ---- tray (Windows) ----

  bool _trayReady = false;

  Future<void> _initTray() async {
    if (!Platform.isWindows) return;
    try {
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);
      trayManager.addListener(this);
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final iconFile = File('$exeDir\\icon.ico');
      await trayManager.setIcon(
        iconFile.existsSync() ? iconFile.path : 'assets/icon.ico',
      );
      await trayManager.setToolTip('Tokiboshi');
      _trayReady = true;
      _hideForSilentStartup();
      await _refreshTray();
    } catch (_) {
      // Tray is a convenience only; ignore failures.
    }
  }

  Future<void> _refreshTray() async {
    if (!_trayReady) return;
    try {
      final selected = _data.selected;
      final items = <MenuItem>[
        MenuItem(
          label: _running
              ? '运行中${selected == null ? '' : ' · ${selected.name}'}'
              : '内核已停止',
          disabled: true,
        ),
        MenuItem.separator(),
        MenuItem(key: 'toggle', label: _running ? '停止内核' : '启动内核'),
        MenuItem.separator(),
        MenuItem(
            key: 'mode_rule',
            label: '规则模式',
            checked: _clashMode != 'Global' && _clashMode != 'Direct',
            disabled: !_running),
        MenuItem(
            key: 'mode_global',
            label: '全局模式',
            checked: _clashMode == 'Global',
            disabled: !_running),
        MenuItem(
            key: 'mode_direct',
            label: '直连模式',
            checked: _clashMode == 'Direct',
            disabled: !_running),
        MenuItem.separator(),
        for (var i = 0; i < _data.nodes.length && i < 15; i++)
          MenuItem(
            key: 'node_$i',
            label: _data.nodes[i].name,
            checked: i == _data.selectedIndex,
          ),
        if (_data.nodes.isNotEmpty) MenuItem.separator(),
        MenuItem(key: 'sysproxy', label: '系统代理', checked: _data.systemProxy),
        MenuItem.separator(),
        MenuItem(key: 'show', label: '显示主窗口'),
        MenuItem(key: 'quit', label: '退出 Tokiboshi'),
      ];
      await trayManager.setContextMenu(Menu(items: items));
    } catch (_) {}
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final key = menuItem.key ?? '';
    if (key == 'toggle') {
      _toggleCore();
    } else if (key == 'mode_rule') {
      _setMode('Rule');
    } else if (key == 'mode_global') {
      _setMode('Global');
    } else if (key == 'mode_direct') {
      _setMode('Direct');
    } else if (key.startsWith('node_')) {
      final i = int.tryParse(key.substring(5));
      if (i != null && i >= 0 && i < _data.nodes.length) _selectNode(i);
    } else if (key == 'sysproxy') {
      _setSystemProxy(!_data.systemProxy);
    } else if (key == 'show') {
      windowManager.show();
      windowManager.focus();
    } else if (key == 'quit') {
      _quitApp();
    }
  }

  @override
  void onWindowClose() {
    // Close button hides to the tray instead of quitting.
    if (_data.ui.closeToTray) {
      windowManager.hide();
    } else {
      _quitApp();
    }
  }

  Future<void> _quitApp() async {
    _quitting = true;
    _demandTimer?.cancel();
    try {
      // Release the single-instance lock first (CV007-02): a new
      // instance launched during our teardown must take over instead
      // of acking against a dying primary.
      _releaseInstanceLock();
      if (_running) {
        await widget.bridge.stopCore();
        if (_data.systemProxy) {
          await widget.systemProxy.apply(false, _data.mixedPort);
        }
      }
      _data.cleanExit = true;
      _data.runningAtExit = _running;
      await _persist();
      await trayManager.destroy();
    } catch (_) {}
    await windowManager.destroy();
  }

  // ---- core ----

  /// Resolve the core binary, downloading the pinned sing-box
  /// release first when the managed core is missing. Returns null
  /// (with a message set) when no binary can be provided.
  Future<String?> _ensureCoreBinary() async {
    if (_data.singBoxPath.isNotEmpty) return _data.singBoxPath;
    final managed = await widget.bridge.managedCorePath(_dataDir);
    try {
      final v = await widget.bridge.coreVersion(managed);
      if (v.isNotEmpty) return managed;
    } catch (_) {
      // Managed core not installed yet — download it below.
    }
    final bundled = resolveSingBoxPath('', _dataDir);
    if (bundled != managed && bundled != 'sing-box.exe') {
      try {
        if ((await widget.bridge.coreVersion(bundled)).isNotEmpty)
          return bundled;
      } catch (_) {
        // Repair an absent/unusable installation via the managed download.
      }
    }
    _setMessage('正在下载 sing-box 内核（首次启动需要）…');
    await _ensureCoreAndRules();
    for (var i = 0; i < 200; i++) {
      _checkConnectCancelled();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final state = await widget.bridge.ensureCoreState();
      if (state.phase == 'done') {
        await _refreshCoreVersion();
        return managed;
      }
      if (state.phase == 'error') {
        _setMessage('内核下载失败：${state.error ?? '未知错误'}');
        return null;
      }
    }
    _setMessage('内核下载超时，请检查网络后重试');
    return null;
  }

  void _checkConnectCancelled() {
    if (_cancelConnect) throw const _ConnectCancelled();
  }

  void _requestCancelConnect() {
    if (_busy && !_running) {
      _cancelConnect = true;
      _setMessage('正在取消连接…');
    }
  }

  Future<void> _toggleCore({bool automaticDemand = false}) async {
    if (_busy || _profileChanging || _settingsBusy || _quitting) return;
    if (!automaticDemand) {
      _demandOwned = false;
      if (_running && _data.desktop.onDemand)
        _demandSuppressed = true;
      else if (!_running) _demandSuppressed = false;
    }
    _cancelConnect = false;
    setState(() {
      _busy = true;
      _coreBusy = true;
    });
    var started = false;
    try {
      if (_running) {
        _userStopped = true;
        _coreDownSince = null;
        await widget.bridge.stopCore();
        await widget.systemProxy.apply(false, _data.mixedPort);
        setState(() {
          _running = false;
          _latency.clear();
          _clashMode = null;
          _message = '已停止';
        });
        return;
      }
      if (_data.nodes.isEmpty) {
        _setMessage('先导入节点');
        return;
      }
      // TUN needs an elevated token; offer a one-click elevated
      // restart instead of letting the core FATAL later (user
      // request: 不能启动默认请求管理员吗 → 按需 UAC).
      if (_data.enableTun && !await _isElevated()) {
        final action = await showDialog<_TunAction>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('需要管理员权限'),
            content: const Text('虚拟网卡（TUN）需要以管理员身份运行才能接管全局流量。\n\n'
                '「以管理员身份重启」会弹出 UAC 授权并重启应用，重启后自动连接并启用 TUN。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, _TunAction.cancel),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, _TunAction.disableTun),
                child: const Text('关闭虚拟网卡并继续'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, _TunAction.relaunch),
                child: const Text('以管理员身份重启'),
              ),
            ],
          ),
        );
        if (!mounted) return;
        if (action == _TunAction.relaunch) {
          await _relaunchElevated();
          return;
        }
        if (action == _TunAction.disableTun) {
          setState(() => _data.enableTun = false);
          await _persist();
        } else {
          return; // cancel
        }
      }
      // A stop may have silently failed or the supervisor may have
      // just revived the core: adopt it instead of failing later with
      // "already running".
      if (await widget.bridge.coreRunning()) {
        setState(() {
          _running = true;
          _userStopped = false;
          _coreDownSince = null;
          _message = '内核已在运行，已恢复界面状态';
        });
        return;
      }
      final binary = await _ensureCoreBinary();
      _checkConnectCancelled();
      if (binary == null) return;
      final oldMixedPort = _data.mixedPort;
      final oldApiPort = _data.clashApiPort;
      final mixedPort = await widget.allocatePort(oldMixedPort, {});
      final apiPort = await widget.allocatePort(oldApiPort, {mixedPort});
      _data.mixedPort = mixedPort;
      _data.clashApiPort = apiPort;
      await _persist();
      final portsChanged = mixedPort != oldMixedPort || apiPort != oldApiPort;
      final selected = _data.selected;
      final profile = activeProfile(_data);
      final configNodes = profileNodes(_data);
      if (selected == null) {
        throw const FormatException('请先选择激活配置中的出口节点');
      }
      if (profile != null && selected.source != profile.id) {
        throw const FormatException('当前节点不属于规则订阅，请选择该订阅的节点或策略组');
      }
      final nodeTags = assignNodeTags(configNodes.map((n) => n.name));
      final routeTargets = RoutingTargets(configNodes).resolved;
      final config = await widget.bridge.buildConfig(
        nodes: configNodes
            .map((n) => NodeSpec(name: n.name, outboundJson: n.outboundJson))
            .toList(),
        mixedPort: _data.mixedPort,
        clashApiPort: _data.clashApiPort,
        enableTun: _data.enableTun,
        blockAds: switch (_data.templateRouting['ads']) {
          'off' => false, null => _data.blockAds, _ => true,
        },
        bypassCn: switch (_data.templateRouting['cn']) {
          'off' => false, null => _data.bypassCn, _ => true,
        },
        dataDir: _dataDir,
        selectedName:
            nodeTags[configNodes.indexOf(selected)],
        profileJson: profile?.profileJson ?? '',
      );
      if ((_data.routingPreset != 'balanced' || _data.templateRouting.keys.any(serviceRuleNames.containsKey)) && _ruleResources.isEmpty) {
        await _loadRuleResources();
        _checkConnectCancelled();
      }
      final preset = applyResourcePreset(config, _data.routingPreset, _ruleResources, _dataDir);
      final template = applyTemplateRouting(preset,
          profile == null ? _data.templateRouting : const {}, routeTargets);
      final services = applyServiceRouting(
          template, _data.templateRouting, routeTargets, _ruleResources, _dataDir);
      final network = applyNetworkSettings(
          injectClashSecret(services, _data.clashApiSecret), _data.desktop);
      final configFile = await widget.store.writeRuntimeConfig(
          applyClientPreferences(network, _data.client, hasProfile: profile != null,
            tagByName: routeTargets, lookupProcesses: Platform.isWindows));
      _checkConnectCancelled();
      // Rule-set downloads run in the background after app start; if
      // they have not landed yet this config carries no 分流 rules.
      // The warning is appended to the RUNNING status message so it
      // survives the start (HF053-02: transient _setMessage loses it).
      final rulesDir = Directory('$_dataDir\\rules');
      final rulesPending = !const [
        'geosite-category-ads-all.srs',
        'geosite-cn.srs',
        'geoip-cn.srs',
      ].every((f) => File('${rulesDir.path}\\$f').existsSync());
      await widget.bridge.startCore(
        singBoxPath: binary,
        configPath: configFile.path,
      );
      started = true;
      _checkConnectCancelled();
      _demandOwned = automaticDemand;
      // A fresh start invalidates the stop flag: without this, the
      // next supervisor restart blip would tear the proxy down again
      // (HF053-05 remainder).
      _userStopped = false;
      _coreDownSince = null;
      if (_data.systemProxy) {
        await widget.systemProxy.apply(true, _data.mixedPort);
      }
      setState(() {
        _running = true;
        _latency.clear();
        _restartCount = 0;
        _lastExit = null;
        _message = _compose(
            '运行中：${_data.nodes.where((n) => !n.isPolicy).length} 个节点 · mixed 127.0.0.1:${_data.mixedPort}'
            ' · 面板 127.0.0.1:${_data.clashApiPort}/ui'
            ' · 分流：${profile == null ? '仅节点订阅/内置模板' : '订阅自带规则'}'
            '${_data.systemProxy ? ' · 系统代理已开启' : ''}'
            '${portsChanged ? ' · 原端口被占用，已自动更换并保存端口' : ''}'
            '${profile == null && rulesPending ? ' · ⚠ 规则集未就绪，重启内核后分流生效' : ''}');
      });
      if (_data.ruleSetAutoUpdate) {
        unawaited(_refreshRuleResources(binary: binary));
      }
    } catch (e) {
      if (started) {
        try {
          await widget.bridge.stopCore();
        } catch (_) {}
        try {
          await widget.systemProxy.apply(false, _data.mixedPort);
        } catch (_) {}
        if (mounted) setState(() => _running = false);
      }
      _setMessage(e is _ConnectCancelled ? '已取消连接，节点选择已保留' : '启动失败：$e');
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _coreBusy = false;
        });
    }
  }

  Future<void> _restartCore() async {
    if (_busy || !_running) return;
    await widget.bridge.stopCore();
    await widget.systemProxy.apply(false, _data.mixedPort);
    if (mounted) {
      setState(() {
        _running = false;
        _clashMode = null;
      });
    }
    await _toggleCore(automaticDemand: _demandOwned);
  }

  Future<void> _ensureFromSettings() async {
    _setMessage('正在检查/下载 sing-box 内核…');
    await _ensureCoreAndRules();
    for (var i = 0; i < 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final state = await widget.bridge.ensureCoreState();
      if (state.phase == 'done') {
        _setMessage('内核就绪：${state.version ?? ''}');
        await _refreshCoreVersion();
        return;
      }
      if (state.phase == 'error') {
        _setMessage('内核下载失败：${state.error ?? '未知错误'}');
        return;
      }
      if (!mounted) return;
    }
    _setMessage('内核下载超时，请检查网络后重试');
  }

  Future<void> _saveSettings(
      int port, int clashApiPort, String singBoxPath) async {
    setState(() {
      _data.mixedPort = port;
      _data.clashApiPort = clashApiPort;
      _data.singBoxPath = singBoxPath;
    });
    final saved = await _persist();
    _setMessage(saved ? '设置已保存' : '设置保存失败（见上方错误）');
  }

  Future<void> _setSystemProxy(bool value) async {
    setState(() {
      _data.systemProxy = value;
    });
    final saved = await _persist();
    if (_running) {
      await widget.systemProxy.apply(value, _data.mixedPort);
      // 运行时已应用 ≠ 已持久化：分开呈现（HV003-01）。
      _setMessage(
          '${value ? '系统代理已开启' : '系统代理已关闭'}${saved ? '' : '（⚠ 配置未保存）'}');
    }
  }

  Future<void> _setTun(bool value) async {
    if (_busy || _handoffInProgress) return;
    final beforeToggle = _data.copyWith();
    setState(() {
      _data.enableTun = value;
    });
    // Enabling TUN while the core is running requires an elevated
    // restart — offer it instead of restarting into a FATAL.
    if (value && _running && !await _isElevated()) {
      final relaunch = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('需要管理员权限'),
          content: const Text(
              '虚拟网卡（TUN）需要以管理员身份运行。\n\n「以管理员身份重启」会弹出 UAC 授权并重启应用，重启后自动连接并启用 TUN。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消（恢复关闭）'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('以管理员身份重启'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (relaunch == true) {
        await _relaunchElevated(rollback: beforeToggle);
        return;
      }
      setState(() {
        _data.enableTun = false;
        _message = _compose('已取消：虚拟网卡需要管理员权限，开关已恢复为关闭');
      });
      return;
    }
    final saved = await _persist();
    if (_running) {
      _setMessage(
          '${value ? '虚拟网卡已开启，正在重启内核…' : '虚拟网卡已关闭，正在重启内核…'}${saved ? '' : '（⚠ 配置保存失败）'}');
      await _restartCore();
    } else {
      _setMessage(
          '${value ? '虚拟网卡已开启（下次启动生效）' : '虚拟网卡已关闭'}${saved ? '' : '（⚠ 配置未保存）'}');
    }
  }

  /// Stop everything cleanly, persist handoff intent (one-shot
  /// resumeConnect + cleanExit + runningAtExit), THEN trigger UAC.
  /// Nothing is torn down before the user accepts the UAC prompt:
  /// cancelling leaves the app exactly as it was (CV007-03), and a
  /// failed persist aborts the relaunch (CV007-04). On success the
  /// lock is released so the elevated instance can take over
  /// (CV007-02).
  Future<void> _relaunchElevated({AppData? rollback}) async {
    // Full snapshot of everything this attempt mutates: ANY exit path
    // that does not end in a successful UAC launch restores it (Codex
    // CV007-01/03/04 remainders).
    final snapshot = rollback ?? _data.copyWith();
    _handoffInProgress = true;
    try {
      _data.cleanExit = true;
      _data.runningAtExit = _running;
      _data.resumeConnect = true;
      if (!await _persist()) {
        // CV007-04: handoff state could not be written - abort with
        // the in-memory state restored to the pre-attempt snapshot.
        if (mounted) setState(() => _data = snapshot);
        await _persist(); // Replace any recoverable tmp handoff intent too.
        _setMessage('配置保存失败，已取消提权重启（应用保持当前状态）');
        return;
      }
      final exe = Platform.resolvedExecutable;
      final quotedExe = exe.replaceAll("'", "''");
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "Start-Process -FilePath '$quotedExe' -ArgumentList '--wait-parent=$pid' -Verb RunAs -ErrorAction Stop",
      ]);
      if (result.exitCode != 0) {
        // UAC declined: restore the pre-attempt state exactly
        // (CV007-03) - core, proxy, tray and flags all unchanged.
        if (mounted) setState(() => _data = snapshot);
        await widget.store.save(_data);
        _setMessage('已取消管理员授权（未重启，连接保持原状）');
        return;
      }
      // Accepted: the elevated instance is launching. Release the
      // single-instance lock FIRST so it can bind even while our
      // teardown runs (CV007-02), then stop core/proxy and exit.
      _releaseInstanceLock();
      if (_running) {
        await widget.bridge.stopCore();
        if (_data.systemProxy) {
          await widget.systemProxy.apply(false, _data.mixedPort);
        }
      }
      await trayManager.destroy();
      await windowManager.destroy();
      exit(0);
    } catch (e) {
      if (mounted) setState(() => _data = snapshot);
      await _persist();
      _setMessage('提权重启失败：$e');
    } finally {
      _handoffInProgress = false;
    }
  }

  Future<void> _setMode(String mode) async {
    try {
      await _clash.setMode(mode);
      // Never claim success from the status code alone: read the
      // controller back and surface a mismatch (HF053-01 follow-up).
      String? actual;
      try {
        actual = await _clash.mode();
      } catch (_) {}
      if (mounted) setState(() => _clashMode = actual ?? mode);
      if (actual != null && actual.toLowerCase() != mode.toLowerCase()) {
        _setMessage('模式切换未生效（控制器仍为 $actual）');
      }
      _refreshTray();
    } catch (e) {
      _setMessage('切换模式失败：$e');
    }
  }

  Future<void> _setRuleOption({bool? blockAds, bool? bypassCn}) async {
    setState(() {
      if (blockAds != null) _data.blockAds = blockAds;
      if (bypassCn != null) _data.bypassCn = bypassCn;
    });
    await _persist();
    if (_running) {
      _setMessage('分流规则已更新，正在重启内核…');
      await _restartCore();
    } else {
      _setMessage('分流规则已更新（下次启动生效）');
    }
  }

  void _hideForSilentStartup() {
    if (_loaded &&
        _trayReady &&
        widget.launchedAtLogin &&
        _data.desktop.silentStart &&
        !_saveFailed &&
        _message?.contains('失败') != true)
      windowManager.hide().catchError((_) {});
  }

  Future<void> _setDesktopSettings(DesktopSettings value) async {
    if (_settingsBusy || _busy || _profileChanging) return;
    if (value.userAgent.contains(RegExp(r'[\r\n]')) ||
        value.userAgent.length > 512 ||
        value.userAgent.codeUnits.any((v) => v > 255)) {
      _setMessage('User-Agent 需要单行 HTTP 字符，最长512字符');
      return;
    }
    if (value.proxyAuth &&
        (value.proxyUser.trim().isEmpty || value.proxyPassword.isEmpty)) {
      _setMessage('启用认证前请填写用户名和密码');
      return;
    }
    final old = _data.desktop;
    setState(() {
      _settingsBusy = true;
      _message = _compose('正在应用常规设置…');
    });
    var startupApplied = false, committed = false;
    try {
      if (old.launchAtLogin != value.launchAtLogin) {
        if (!Platform.isWindows && widget.startup == null)
          throw const FormatException('当前平台不支持 Windows 自启设置');
        await _startup.setEnabled(value.launchAtLogin);
        startupApplied = true;
      }
      _data.desktop = value;
      if (!await _persist()) {
        _data.desktop = old;
        await _persist();
        if (startupApplied) await _startup.setEnabled(old.launchAtLogin);
        _setMessage('设置保存失败，已恢复先前设置');
        return;
      }
      committed = true;
      _demandSuppressed = false;
      _configureDemand();
      final networkChanged = old.allowLan != value.allowLan ||
          old.remoteController != value.remoteController ||
          old.proxyAuth != value.proxyAuth ||
          old.proxyUser != value.proxyUser ||
          old.proxyPassword != value.proxyPassword;
      _setMessage(
          '常规设置已保存${networkChanged && _running ? '，正在重启内核应用接入设置' : ''}');
      setState(() => _settingsBusy = false);
      if (networkChanged && _running) await _restartCore();
    } catch (e) {
      if (!committed) {
        _data.desktop = old;
        await _persist();
        if (startupApplied) {
          try {
            await _startup.setEnabled(old.launchAtLogin);
          } catch (_) {}
        }
      }
      _setMessage('设置应用失败：${redactDiagnostics('$e')}');
    } finally {
      if (mounted) setState(() => _settingsBusy = false);
    }
  }

  Future<void> _checkUpdates({bool automatic = false}) async {
    if (_checkingUpdate) return;
    if (mounted) setState(() => _checkingUpdate = true);
    try {
      final result = await widget.updateClient.check(kReleaseTag);
      if (!mounted) return;
      setState(() {
        _update = result;
        _updateStatus = result.available
            ? '发现 ${result.tag}，可打开下载页更新'
            : '当前修订版已是最新（远端 ${result.tag}）';
      });
      if (!automatic || result.available && _message == null)
        _setMessage(_updateStatus);
    } catch (_) {
      if (mounted) setState(() => _updateStatus = '检查失败，请检查网络或稍后重试');
      if (!automatic) _setMessage('检查更新失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  Future<void> _openUpdatePage() async {
    final url = _update?.url ??
        'https://github.com/kurumiZafkiel12/Tokiboshi/releases/latest';
    try {
      await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
    } catch (_) {
      _setMessage('打开下载页失败，请从项目发布页下载');
    }
  }

  void _configureDemand() {
    _demandTimer?.cancel();
    _demandTimer = null;
    if ((Platform.isWindows || widget.processProbe != null) &&
        _data.desktop.onDemand) {
      _demandTimer =
          Timer.periodic(const Duration(seconds: 8), (_) => _pollDemand());
      unawaited(_pollDemand());
    }
  }

  Future<void> _pollDemand() async {
    if (!mounted ||
        _quitting ||
        _demandPolling ||
        _busy ||
        _profileChanging ||
        _settingsBusy ||
        _handoffInProgress ||
        !_data.desktop.onDemand) return;
    _demandPolling = true;
    try {
      final preferences = _data.desktop;
      final names = await (widget.processProbe ?? runningProcessNames)();
      if (!mounted ||
          _quitting ||
          _busy ||
          _profileChanging ||
          _settingsBusy ||
          _handoffInProgress ||
          !identical(preferences, _data.desktop)) return;
      _demandMatch = matchesDemandProcesses(_data.desktop.processes, names);
      if (!_demandMatch) {
        _demandSuppressed = false;
        if (_demandOwned && _running) await _toggleCore(automaticDemand: true);
        _demandOwned = false;
        return;
      }
      if (!_running && !_demandSuppressed && _data.selected != null) {
        if (_data.enableTun && !await _isElevated()) {
          _demandSuppressed = true;
          _setMessage('按需连接等待管理员权限，请手动启动并授权');
          return;
        }
        await _toggleCore(automaticDemand: true);
        if (!_running) _demandSuppressed = true;
      }
    } catch (_) {
      /* Keep current connection on process probe failures. */
    } finally {
      _demandPolling = false;
    }
  }

  Map<String, String> _routingOptions() {
    List<NodeInfo> nodes;
    try {
      nodes = profileNodes(_data);
    } on FormatException {
      return const {};
    }
    return {
      for (final node in RoutingTargets(nodes).available)
        routeNodeReference(node): '${node.name} · ${[
          for (final sub in _data.subscriptions)
            if (sub.id == node.source) sub.name,
          if (node.source.isEmpty) '本地节点',
          if (node.group.isNotEmpty) node.group,
          if (node.server.isNotEmpty) '${node.server}:${node.serverPort}',
        ].join(' / ')}',
    };
  }

  // ---- layout ----

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _data.selected;
    final nodeCounts = <String, int>{};
    for (final n in _data.nodes) {
      if (n.source.isNotEmpty && !n.isPolicy) {
        nodeCounts[n.source] = (nodeCounts[n.source] ?? 0) + 1;
      }
    }
    final Widget page;
    switch (_page) {
      case 1:
        page = PanelPage(
          running: _running,
          clashApiPort: _data.clashApiPort,
          clashApiSecret: _data.clashApiSecret,
          onStart: _toggleCore,
          onOpenExternal: _openExternalPanel,
        );
      case 2:
        page = NodesPage(
          nodes: _data.nodes,
          subscriptions: _data.subscriptions,
          selectedIndex: _data.selectedIndex,
          running: _running,
          busy: _busy || _profileChanging || _settingsBusy,
          latency: _latency,
          onSelect: _selectNode,
          onDelete: _deleteNode,
          onImport: _importDialog,
          onImportMethod: (method) => _importDialog(initialMethod: method),
          onMeasureAll: _measureAll,
          onCreateChain: _createChainDialog,
          onMeasureNode: _measureNode,
          onQualitySample: _sampleNodeQuality,
        );
      case 3:
        page = SubscriptionsPage(
          subscriptions: _data.subscriptions,
          nodeCounts: nodeCounts,
          running: _running,
          busy: _busy || _profileChanging || _settingsBusy,
          onAdd: _addSubscriptionDialog,
          onImportMethod: (method) => _importDialog(initialMethod: method),
          onRetryFull: (sub) => _updateSubscription(sub, retryFull: true),
          onUpdate: _updateSubscription,
          onDelete: _deleteSubscription,
          onUpdateAll: _updateAllSubscriptions,
          onEdit: _editSubscription,
          activeProfileId: _effectiveProfileId,
          onActivate: _activateProfile,
        );
      case 4:
        page = LogsPage(
            fetchLogs: widget.bridge.coreLogs,
            onExport: (text) async {
              final dir = Directory(
                  '${widget.store.dir.path}${Platform.pathSeparator}exports');
              await dir.create(recursive: true);
              final file = File(
                  '${dir.path}${Platform.pathSeparator}tokiboshi-${DateTime.now().millisecondsSinceEpoch}.log');
              await file.writeAsString(text, flush: true);
              return file.path;
            });
      case 6:
        page = RulesPage(
            activeProfileId: _effectiveProfileId,
            customRules: _data.client.rules,
            onEdit: () => setState(() {
                  _settingsSection = 2;
                  _page = 5;
                }),
            subscriptions: _data.subscriptions,
            running: _running,
            busy: _busy || _profileChanging || _settingsBusy,
            api: _clash,
            dataDir: _dataDir,
            onApply: _running ? _restartCore : _toggleCore,
            onSources: () => setState(() => _page = 3),
            blockAds: _data.blockAds,
            bypassCn: _data.bypassCn,
            templateRouting: _data.templateRouting,
            targets: _routingOptions(),
            ruleResources: _ruleResources,
            onResources: () => setState(() => _page = 8),
            onTemplateRouting: _setTemplateRouting,
            activeProcesses: _activeProcesses(),
            onAddProcessRule: _addProcessRule);
      case 8:
        page = ToolboxPage(
          running: _running,
          mixedPort: _data.mixedPort,
          session: selected,
          onStart: _toggleCore,
          systemProxy: widget.systemProxy,
          proxyCredentials: _data.desktop.proxyAuth
              ? (_data.desktop.proxyUser, _data.desktop.proxyPassword)
              : null,
          networkInfo: NetworkInfo(
              monitor: _monitor,
              refresh: () => _measureAll(liveOnly: true),
              latency: [
                for (final n in profileNodes(_data))
                  if (_latency.containsKey(n)) (n.name, _latency[n]),
              ]),
          resources: RuleResourcePanel(
              catalog: _ruleResources,
              data: _data,
              dataDir: _dataDir,
              busy: _resourcesBusy || _settingsBusy || _busy,
              onSettings: _saveRuleResourcePrefs,
              onUpdate: (item) => _refreshRuleResources(item: item)),
        );
      case 7:
        page = ConnectionsPage(monitor: _monitor, running: _running);
      case 5:
        page = SettingsPage(
          initialSection: _settingsSection,
          mixedPort: _data.mixedPort,
          clashApiPort: _data.clashApiPort,
          singBoxPath: _data.singBoxPath,
          client: _data.client,
          onClientSave: _saveClientPreferences,
          onBackup: _exportBackup,
          onRestore: _restoreBackup,
          systemProxy: _data.systemProxy,
          autoConnect: _data.autoConnect,
          onAutoConnectChanged: (value) {
            setState(() => _data.autoConnect = value);
            _persist();
          },
          running: _running,
          dataFilePath: widget.store.file.path,
          coreVersion: _coreVersion,
          onSave: _saveSettings,
          onSystemProxyChanged: _setSystemProxy,
          onEnsureCore: _ensureFromSettings,
          blockAds: _data.blockAds,
          bypassCn: _data.bypassCn,
          onBlockAdsChanged: (v) => _setRuleOption(blockAds: v),
          onBypassCnChanged: (v) => _setRuleOption(bypassCn: v),
          desktop: _data.desktop,
          onDesktopChanged: _setDesktopSettings,
          settingsBusy: _busy || _profileChanging || _settingsBusy,
          onCheckUpdate: () => _checkUpdates(),
          onOpenUpdate: _update?.available == true ? _openUpdatePage : null,
          updateStatus: _updateStatus,
          checkingUpdate: _checkingUpdate,
          onCopyControllerSecret: () async {
            await Clipboard.setData(ClipboardData(text: _data.clashApiSecret));
            _setMessage('控制器密钥已复制到剪贴板');
          },
        );
      default:
        page = DashboardPage(
          running: _running,
          busy: _coreBusy,
          profileBusy: _profileChanging,
          selected: selected,
          monitor: _monitor,
          subscriptions: _data.subscriptions,
          onSubscriptions: () => setState(() => _page = 3),
          onLogs: () => setState(() => _page = 4),
          onUpdate: _updateSubscription,
          activeProfileId: _effectiveProfileId,
          onActivateProfile: _activateProfile,
          failure: _message?.contains('启动失败') == true
              ? _message
              : (_userStopped ? null : _lastExit),
          nodeCount: _data.nodes.where((n) => !n.isPolicy).length,
          subscriptionCount: _data.subscriptions.length,
          mixedPort: _data.mixedPort,
          systemProxy: _data.systemProxy,
          selectedLatency: selected == null ? null : _latency[selected],
          selectedMeasured: selected != null && _latency.containsKey(selected),
          coreVersion: _coreVersion,
          restartCount: _restartCount,
          lastExit: _lastExit,
          clashMode: _clashMode,
          tun: _data.enableTun,
          onToggle: _toggleCore,
          onRestart: _restartCore,
          onPickNode: _showNodePicker,
          onCancelConnect: _requestCancelConnect,
          controlsBlocked: _profileChanging || _settingsBusy || (_busy && !_coreBusy),
          onOpenPanel: () => setState(() => _page = 1),
          onTunChanged: _setTun,
          onSystemProxyChanged: _busy ? null : _setSystemProxy,
          onModeChanged: _setMode,
          onMeasureSelected: () {
            final node = _data.selected;
            if (node != null) _measureNode(node);
          },
        );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted)
        _monitor.configure(
            running: _running,
            port: _data.clashApiPort,
            secret: _data.clashApiSecret);
    });
    final ui = UiScope.of(context);
    const names = {
      0: '连接',
      1: '面板',
      2: '节点',
      3: '订阅',
      4: '运行日志',
      5: '设置',
      6: '分流规则',
      7: '请求',
      8: '工具箱'
    };
    return Shortcuts(
        shortcuts: {
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyK):
              const _FindNodeIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyI):
              const _ImportIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.comma):
              const _SettingsIntent()
        },
        child: Actions(
            actions: {
              _ImportIntent: CallbackAction<_ImportIntent>(onInvoke: (_) {
                _importDialog();
                return null;
              }),
              _SettingsIntent: CallbackAction<_SettingsIntent>(onInvoke: (_) {
                setState(() {
                  _settingsSection = 0;
                  _page = 5;
                });
                return null;
              }),
              _FindNodeIntent: CallbackAction<_FindNodeIntent>(onInvoke: (_) {
                _showNodePicker();
                return null;
              })
            },
            child: Focus(
                autofocus: true,
                child: Scaffold(
                    body: Column(children: [
                  Container(
                      height: 32,
                      decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          border: Border(
                              bottom: BorderSide(color: scheme.outline))),
                      child: Platform.isWindows
                          ? WindowCaption(
                              brightness: scheme.brightness,
                              backgroundColor: scheme.surfaceContainerLow,
                              title: DefaultTextStyle.merge(
                                  // WindowCaption resets DefaultTextStyle, including its font family.
                                  style: Theme.of(context).textTheme.bodySmall!,
                                  child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (ui.character) ...[
                                          const Ribbon(size: 16),
                                          const SizedBox(width: 10)
                                        ],
                                        const Text('Tokiboshi · 時の星',
                                            style: TextStyle(fontSize: 11)),
                                        const SizedBox(width: 10),
                                        const Tag('v$kAppVersion')
                                      ])))
                          : Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 15),
                              child: Row(children: [
                                if (ui.character) ...[
                                  const Ribbon(size: 16),
                                  const SizedBox(width: 10)
                                ],
                                const Text('Tokiboshi · 時の星',
                                    style: TextStyle(fontSize: 11)),
                                const SizedBox(width: 10),
                                const Tag('v$kAppVersion'),
                                const Spacer(),
                                Text('WINDOWS CLIENT',
                                    style: mono.copyWith(
                                        fontSize: 9,
                                        color: scheme.onSurfaceVariant))
                              ]))),
                  Expanded(
                      child: LayoutBuilder(builder: (context, constraints) {
                    final collapsed =
                        _navCollapsed || constraints.maxWidth < 900;
                    return Row(children: [
                      AnimatedContainer(
                          duration: UiScope.duration(context),
                          width: collapsed ? 68 : 220,
                          decoration: BoxDecoration(
                              color: scheme.surfaceContainerLow,
                              border: Border(
                                  right: BorderSide(color: scheme.outline))),
                          child: Column(children: [
                            Padding(
                                padding: EdgeInsets.fromLTRB(
                                    collapsed ? 14 : 18,
                                    23,
                                    collapsed ? 14 : 16,
                                    24),
                                child: Row(children: [
                                  Container(
                                      padding: const EdgeInsets.all(2),
                                      decoration: BoxDecoration(
                                          border: Border.all(
                                              color: ui.character
                                                  ? gold.withValues(alpha: .35)
                                                  : scheme.outline),
                                          borderRadius:
                                              BorderRadius.circular(7)),
                                      child: Image.asset('assets/icon.png',
                                          width: 30, height: 30)),
                                  if (!collapsed) ...[
                                    const SizedBox(width: 8),
                                    const Expanded(
                                        child: Text('Tokiboshi',
                                            style: TextStyle(
                                                fontSize: 19,
                                                fontWeight: FontWeight.w700,
                                                letterSpacing: -.7)))
                                  ]
                                ])),
                            if (!collapsed)
                              Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(22, 0, 0, 8),
                                  child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text('WORKSPACE',
                                          style: mono.copyWith(
                                              fontSize: 9,
                                              color:
                                                  scheme.onSurfaceVariant)))),
                            Expanded(
                                child: SingleChildScrollView(
                                    child: Column(children: [
                              _navItem(
                                  0, Icons.grid_view_outlined, '连接', collapsed),
                              _navItem(2, Icons.dns_outlined, '节点', collapsed,
                                  count: _data.nodes
                                      .where((n) => !n.isPolicy)
                                      .length),
                              _navItem(3, Icons.inventory_2_outlined, '订阅',
                                  collapsed),
                              _navItem(
                                  6, Icons.route_outlined, '分流规则', collapsed),
                              _navItem(7, Icons.monitor_heart_outlined, '请求',
                                  collapsed),
                              _navItem(8, Icons.construction_outlined, '工具箱',
                                  collapsed),
                              _navItem(4, Icons.terminal_outlined, '运行日志',
                                  collapsed),
                              _navItem(
                                  1, Icons.web_asset_outlined, '面板', collapsed),
                              _navItem(
                                  5, Icons.settings_outlined, '设置', collapsed),
                            ]))),
                            if (!collapsed)
                              Padding(
                                  padding: const EdgeInsets.all(11),
                                  child: Panel(
                                      padding: const EdgeInsets.all(11),
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            StatusDot('当前配置',
                                                color: scheme.primary),
                                            const SizedBox(height: 8),
                                            Text(_profileName,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                    fontSize: 12)),
                                            const SizedBox(height: 8),
                                            Row(children: [
                                              Text(
                                                  _data.subscriptions.any((s) =>
                                                          s.profileJson != null)
                                                      ? '订阅规则'
                                                      : '内置模板',
                                                  style: const TextStyle(
                                                      fontSize: 10)),
                                              const Spacer(),
                                              Text(_running ? '运行中' : '未运行',
                                                  style: const TextStyle(
                                                      fontSize: 10))
                                            ])
                                          ]))),
                            Padding(
                                padding: EdgeInsets.fromLTRB(collapsed ? 4 : 10,
                                    1, collapsed ? 4 : 10, 12),
                                child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      if (!collapsed) ...[
                                        Container(
                                            width: 28,
                                            height: 28,
                                            alignment: Alignment.center,
                                            decoration: BoxDecoration(
                                                border: Border.all(
                                                    color: scheme.primary
                                                        .withValues(alpha: .3)),
                                                borderRadius:
                                                    BorderRadius.circular(5)),
                                            child: const Text('K',
                                                style:
                                                    TextStyle(fontSize: 11))),
                                        const SizedBox(width: 8),
                                        Expanded(
                                            child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                              const Text('本地空间',
                                                  style:
                                                      TextStyle(fontSize: 11)),
                                              Text('v$kAppVersion',
                                                  style: mono.copyWith(
                                                      fontSize: 9,
                                                      color: scheme
                                                          .onSurfaceVariant))
                                            ]))
                                      ],
                                      IconButton(
                                          tooltip: collapsed ? '展开侧栏' : '收起侧栏',
                                          onPressed: () => setState(() =>
                                              _navCollapsed = !_navCollapsed),
                                          icon: Icon(
                                              collapsed
                                                  ? Icons
                                                      .keyboard_double_arrow_right
                                                  : Icons
                                                      .space_dashboard_outlined,
                                              size: 17))
                                    ])),
                          ])),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                            Container(
                                height: 54,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 22),
                                decoration: BoxDecoration(
                                    border: Border(
                                        bottom: BorderSide(
                                            color: scheme.outlineVariant))),
                                child: Row(children: [
                                  const Icon(Icons.grid_view_outlined,
                                      size: 16),
                                  const SizedBox(width: 10),
                                  Text(names[_page] ?? '连接',
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600)),
                                  const Spacer(),
                                  if (constraints.maxWidth > 1000)
                                    OutlinedButton.icon(
                                        onPressed: _showNodePicker,
                                        icon:
                                            const Icon(Icons.search, size: 14),
                                        label: const Text('查找节点    Ctrl K',
                                            style: TextStyle(fontSize: 10))),
                                  const SizedBox(width: 10),
                                  if (constraints.maxWidth > 1100)
                                    OutlinedButton.icon(
                                        onPressed: () => UiScope.change(
                                            context,
                                            ui.copyWith(
                                                motion: ui.motion == 'reduced'
                                                    ? ui.previousMotion
                                                    : 'reduced')),
                                        icon: Icon(
                                            ui.motion == 'reduced'
                                                ? Icons
                                                    .motion_photos_off_outlined
                                                : Icons
                                                    .motion_photos_on_outlined,
                                            size: 14),
                                        label: Text(ui.motion == 'reduced' ? '动效关' : '动效开',
                                            style:
                                                const TextStyle(fontSize: 10)))
                                  else
                                    IconButton(
                                        tooltip: '切换动态效果',
                                        onPressed: () =>
                                            UiScope.change(context, ui.copyWith(motion: ui.motion == 'reduced' ? ui.previousMotion : 'reduced')),
                                        icon: Icon(ui.motion == 'reduced' ? Icons.motion_photos_off_outlined : Icons.motion_photos_on_outlined, size: 17)),
                                  IconButton(
                                      tooltip: '连接光流',
                                      onPressed: () => UiScope.change(
                                          context, ui.copyWith(flow: !ui.flow)),
                                      icon: Icon(Icons.waves_outlined,
                                          size: 17,
                                          color: ui.flow
                                              ? gold
                                              : scheme.onSurfaceVariant)),
                                  StatusDot(
                                      _coreBusy
                                          ? '正在连接'
                                          : _running
                                              ? '内核运行'
                                              : '内核停止',
                                      color: _running
                                          ? good
                                          : scheme.onSurfaceVariant),
                                  const SizedBox(width: 9),
                                  IconButton(
                                      tooltip: ui.light ? '切换深色' : '切换浅色',
                                      onPressed: () => UiScope.change(context,
                                          ui.copyWith(light: !ui.light)),
                                      icon: Icon(
                                          ui.light
                                              ? Icons.dark_mode_outlined
                                              : Icons.light_mode_outlined,
                                          size: 17)),
                                  IconButton(
                                      tooltip: '运行通知',
                                      onPressed: () => showDialog<void>(
                                          context: context,
                                          builder: (context) =>
                                              AlertDialog(
                                                  title: const Text('运行通知'),
                                                  content:
                                                      SingleChildScrollView(
                                                          child: SelectableText(
                                                              _message ??
                                                                  '暂无运行通知')),
                                                  actions: [
                                                    TextButton(
                                                        onPressed: () =>
                                                            Navigator.pop(
                                                                context),
                                                        child: const Text('关闭'))
                                                  ])),
                                      icon: Badge(
                                          isLabelVisible: _message != null,
                                          smallSize: 5,
                                          child: const Icon(
                                              Icons.notifications_none_outlined,
                                              size: 17)))
                                ])),
                            if (_message != null && !_message!.startsWith('运行中：')) _messageBanner(context),
                            if (_busy || _profileChanging || _settingsBusy)
                              const LinearProgressIndicator(minHeight: 2),
                            Expanded(
                                child: AnimatedSwitcher(
                                    duration: UiScope.duration(context),
                                    switchInCurve: Curves.easeOutCubic,
                                    layoutBuilder: (current, previous) =>
                                        Stack(fit: StackFit.expand, children: [
                                          for (final old in previous)
                                            IgnorePointer(
                                                child: ExcludeSemantics(
                                                    child: TickerMode(
                                                        enabled: false,
                                                        child: old))),
                                          if (current != null) current
                                        ]),
                                    transitionBuilder: (child, animation) =>
                                        FadeTransition(
                                            opacity: animation,
                                            child: SlideTransition(
                                                position: Tween(
                                                        begin: const Offset(
                                                            0, .015),
                                                        end: Offset.zero)
                                                    .animate(animation),
                                                child: child)),
                                    child: KeyedSubtree(
                                        key: ValueKey(_loaded ? _page : -1),
                                        child: _loaded ? page : Center(
                                          child: Panel(accent: true,
                                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                                              const Icon(Icons.hourglass_top_rounded, size: 30),
                                              const SizedBox(height: 10),
                                              Text('正在恢复工作区', style: Theme.of(context).textTheme.titleLarge),
                                              const SizedBox(height: 8),
                                              if (UiScope.duration(context) != Duration.zero)
                                                const SizedBox(width: 158, child: LinearProgressIndicator(minHeight: 2)),
                                            ])),
                                        )))),
                            if (_page != 0) ConnectionDock(
                                node: selected,
                                subscriptions: _data.subscriptions,
                                latency: _latency,
                                running: _running,
                                busy: _coreBusy,
                                blocked: _profileChanging ||
                                    _settingsBusy ||
                                    (_busy && !_coreBusy),
                                onPick: _showNodePicker,
                                onCancel: _requestCancelConnect,
                                onToggle: _toggleCore,
                                onProbe: () {
                                  if (selected != null) _measureNode(selected);
                                },
                                onRestart: _restartCore,
                                monitor: _monitor),
                          ]))
                    ]);
                  })),
                ])))));
  }

  String? get _effectiveProfileId {
    try {
      return activeProfile(_data)?.id ?? '';
    } catch (_) {
      return null;
    }
  }

  String get _profileName {
    try {
      return activeProfile(_data)?.name ?? '内置分流模板';
    } catch (_) {
      return '配置冲突，待选择';
    }
  }

  Future<void> _activateProfile(String id) async {
    if (_busy || _running || _profileChanging || _settingsBusy) {
      return;
    }
    final snapshot = _data.copyWith();
    setState(() => _profileChanging = true);
    void restoreSelection() {
      _data.activeProfileId = snapshot.activeProfileId;
      _data.selectedIndex = snapshot.selectedIndex;
    }

    try {
      _data.activeProfileId = id;
      final nodes = profileNodes(_data);
      if (_data.selected != null && !nodes.contains(_data.selected))
        _data.selectedIndex = -1;
      setState(() {});
      final saved = await _persist();
      if (!mounted) return;
      if (!saved) {
        setState(restoreSelection);
        await _persist();
        _setMessage('配置选择保存失败，已恢复先前选择');
        return;
      }
      _setMessage(
          '已选择「$_profileName」，启动后应用${_data.selected == null ? '；请先选择该配置的出口节点' : ''}');
      if (_data.selected == null && mounted) _showNodePicker();
    } catch (e) {
      if (mounted) setState(restoreSelection);
      _setMessage('切换配置失败：$e');
    } finally {
      if (mounted) setState(() => _profileChanging = false);
    }
  }

  Widget _messageBanner(BuildContext context) {
    final error = _saveFailed || _message!.contains('失败');
    final color = error
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    return Container(
        margin: const EdgeInsets.fromLTRB(20, 10, 20, 0),
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: BoxDecoration(
            color: color.withValues(alpha: .06),
            border: Border.all(color: color.withValues(alpha: .3)),
            borderRadius: BorderRadius.circular(6)),
        child: Row(children: [
          Icon(error ? Icons.error_outline : Icons.info_outline,
              size: 17, color: color),
          const SizedBox(width: 10),
          Expanded(
              child: Text(_message!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11))),
          if (_importing && !_importCommitting)
            TextButton(
                onPressed: _importCancelling
                    ? null
                    : () {
                        setState(() => _importCancelling = true);
                        _setMessage('正在取消导入，等待当前网络请求结束…');
                      },
                child: Text(_importCancelling ? '取消中…' : '取消导入')),
          IconButton(
              tooltip: '查看完整提示',
              onPressed: () => showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                          title: const Text('运行提示'),
                          content: SingleChildScrollView(
                              child: SelectableText(_message!)),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('关闭'))
                          ])),
              icon: const Icon(Icons.open_in_full, size: 14)),
          if (!_saveFailed)
            IconButton(
                tooltip: '收起提示',
                onPressed: () => setState(() => _message = null),
                icon: const Icon(Icons.close, size: 15))
        ]));
  }

  void _showNodePicker() {
    showDialog<void>(
        context: context,
        builder: (context) => NodePicker(
            nodes: _data.nodes,
            subscriptions: _data.subscriptions,
            selectedIndex: _data.selectedIndex,
            latency: _latency,
            requiredSource: _effectiveProfileId?.isNotEmpty == true
                ? _effectiveProfileId
                : null,
            busy: _busy || _profileChanging || _settingsBusy,
            onSelect: _selectNode,
            onManage: () => setState(() => _page = 2),
            onMeasure: _measureAll));
  }

  Future<void> _scheduledUpdates() async {
    if (!_loaded ||
        !mounted ||
        _scheduledBusy ||
        _busy ||
        _running ||
        _settingsBusy ||
        _profileChanging ||
        _quitting) return;
    _scheduledBusy = true;
    try {
      for (final source in List.of(_data.subscriptions)) {
        if (!mounted || _running || _busy || _settingsBusy || _profileChanging)
          break;
        if (source.refreshMinutes <= 0) continue;
        final last = _lastSourceAttempt[source.id] ??
            DateTime.tryParse(source.lastAttemptAt ?? '') ??
            DateTime.tryParse(source.updatedAt ?? '');
        if (last != null &&
            DateTime.now().difference(last).inMinutes < source.refreshMinutes)
          continue;
        await _updateSubscription(source, automatic: true);
      }
    } finally {
      _scheduledBusy = false;
    }
  }

  Future<void> _editSubscription(Subscription source) async {
    if (_busy || _running || _settingsBusy || _profileChanging) return;
    setState(() => _profileChanging = true);
    try {
      await editSubscription(context, source, onSave: (next) async {
        if (!mounted) throw StateError('窗口已关闭');
        final before = _data.copyWith();
        setState(() => _data.subscriptions = [
              for (final sub in _data.subscriptions)
                if (sub.id == next.id) next else sub
            ]);
        if (!await _persistImport(before))
          throw const FileSystemException('保存失败，原配置保留，请重试');
        _lastSourceAttempt[next.id] = DateTime.now();
        _setMessage('订阅设置已保存，节点保留；更新后读取新来源');
      });
    } finally {
      if (mounted) setState(() => _profileChanging = false);
    }
  }

  Future<void> _loadRuleResources() async {
    try {
      final resources = await RuleResource.load();
      if (mounted) setState(() => _ruleResources = resources);
    } catch (_) {
      _setMessage('无法读取内置规则集目录');
    }
  }

  Future<void> _ensureCoreAndRules() {
    final bridge = widget.bridge;
    if (bridge is RustCoreBridge) {
      return bridge.startEnsureCoreWithRuleUrls(
          _dataDir,
          jsonEncode({
            for (final entry in _data.ruleSetUrls.entries)
              if (!_data.ruleSetPending.contains(entry.key))
                entry.key: entry.value,
          }));
    }
    return bridge.startEnsureCore(_dataDir);
  }

  Future<void> _saveRuleResourcePrefs(AppData Function(AppData) apply) async {
    if (_resourcesBusy || _settingsBusy || _busy) return;
    final previous = _data.copyWith();
    setState(() {
      _settingsBusy = true;
      _data = apply(_data.copyWith());
    });
    try {
      if (await _persistImport(previous)) _setMessage('规则集设置已保存');
    } finally {
      if (mounted) setState(() => _settingsBusy = false);
    }
  }

  Future<void> _refreshRuleResources(
      {RuleResource? item, String? binary}) async {
    final bridge = widget.bridge;
    if (_resourcesBusy || _settingsBusy || bridge is! RustCoreBridge) return;
    final now = DateTime.now();
    final due = item != null
        ? [item]
        : _ruleResources
            .where((resource) => ruleResourceDue(
                downloaded: File(resource.path(_dataDir)).existsSync(),
                pending: _data.ruleSetPending.contains(resource.tag),
                lastUpdate: _data.ruleSetLastUpdate[resource.tag],
                now: now))
            .toList();
    if (due.isEmpty) return;
    final executable =
        binary ?? resolveSingBoxPath(_data.singBoxPath, _dataDir);
    final urls = Map.of(_data.ruleSetUrls);
    setState(() => _resourcesBusy = true);
    final results = <String, String>{};
    try {
      for (var i = 0; i < due.length; i += 3) {
        await Future.wait(due.skip(i).take(3).map((resource) async {
          try {
            var url = urls[resource.tag] ?? '';
            validateRuleResourceUrl(url);
            try {
              await bridge.updateRuleResource(
                  _dataDir, resource.tag, url, executable);
            } catch (primaryError) {
              // GitHub raw is unreachable from many direct connections:
              // retry once per jsDelivr mirror before giving up.
              final base = url.isEmpty ? resource.url : url;
              Object? lastError = primaryError;
              for (final mirror in mirrorUrls(base)) {
                try {
                  await bridge.updateRuleResource(
                      _dataDir, resource.tag, mirror, executable);
                  lastError = null;
                  break;
                } catch (e) {
                  lastError = e;
                }
              }
              if (lastError != null) throw lastError;
            }
            results[resource.tag] = '';
          } catch (e) {
            results[resource.tag] = redactDiagnostics('$e');
          }
        }));
        if (!mounted) return;
      }
      final previous = _data.copyWith();
      setState(() {
        _data.ruleSetLastUpdate = Map.of(_data.ruleSetLastUpdate);
        _data.ruleSetPending = Set.of(_data.ruleSetPending);
        for (final resource in due) {
          if (results[resource.tag] != '') continue;
          _data.ruleSetLastUpdate[resource.tag] =
              DateTime.now().toIso8601String();
          _data.ruleSetPending.remove(resource.tag);
        }
      });
      final saved = await _persistImport(previous);
      if (!mounted) return;
      _setMessage([
        for (final resource in due)
          '${resource.tag}：${results[resource.tag]!.isEmpty ? '已更新' : results[resource.tag]}',
        if (!saved) '文件已提交，但更新记录保存失败',
        if (_running && results.containsValue('')) '重启内核后应用',
      ].join('；'));
    } finally {
      if (mounted) setState(() => _resourcesBusy = false);
    }
  }

  Future<void> _saveClientPreferences(ClientPreferences value) async {
    if (_busy || _profileChanging || _settingsBusy)
      throw StateError('其他操作正在进行，请稍后保存');
    value.validate();
    final before = _data.copyWith();
    setState(() {
      _settingsBusy = true;
      _data.client = value;
    });
    try {
      if (!await _persistImport(before))
        throw const FileSystemException('设置保存失败，原配置保留');
      _setMessage('分流、DNS 与测速设置已保存；分流和 DNS 在下次启动时应用');
    } finally {
      if (mounted) setState(() => _settingsBusy = false);
    }
  }

  Future<void> _exportBackup() async {
    if (_busy || _profileChanging || _settingsBusy) return;
    setState(() => _settingsBusy = true);
    File? temporary;
    try {
      final location = await getSaveLocation(
          suggestedName:
              'Tokiboshi-backup-${DateTime.now().toIso8601String().split('T').first}.json',
          acceptedTypeGroups: [
            const XTypeGroup(label: 'Tokiboshi 备份', extensions: ['json'])
          ]);
      if (location == null || !mounted) return;
      final destination = File(location.path);
      final path = destination.absolute.path.toLowerCase();
      if ([
        widget.store.file.absolute.path.toLowerCase(),
        '${widget.store.file.absolute.path}.bak'.toLowerCase(),
        '${widget.store.file.absolute.path}.tmp'.toLowerCase()
      ].contains(path)) throw const FormatException('请另选备份文件，不能覆盖应用数据文件');
      temporary = File(
          '${destination.path}.tokiboshi-export-${DateTime.now().microsecondsSinceEpoch}');
      await temporary.writeAsString(encodeBackup(_data), flush: true);
      await temporary.rename(destination.path);
      temporary = null;
      _setMessage('本地备份已导出。文件包含订阅和节点凭据，请妥善保管。');
    } catch (e) {
      _setMessage('备份导出失败：${redactDiagnostics('$e')}');
    } finally {
      if (temporary != null && await temporary.exists())
        await temporary.delete();
      if (mounted) setState(() => _settingsBusy = false);
    }
  }

  Future<void> _restoreBackup() async {
    if (_running ||
        _busy ||
        _profileChanging ||
        _settingsBusy ||
        _resourcesBusy) return;
    setState(() => _settingsBusy = true);
    try {
      final file = await openFile(acceptedTypeGroups: [
        const XTypeGroup(label: 'Tokiboshi 备份', extensions: ['json'])
      ]);
      if (file == null || !mounted) return;
      if (await file.length() > backupMaxBytes)
        throw const FormatException('备份文件超过 64MiB');
      final restored = decodeBackup(await file.readAsString(), _data);
      final yes = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
                  title: const Text('恢复本地备份？'),
                  content: Text(
                      '将恢复 ${restored.nodes.where((n) => !n.isPolicy).length} 个节点、${restored.subscriptions.length} 个来源与界面/分流设置。\n\n恢复后保持停止；本机内核路径、控制器密钥和开机注册保留。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('确认恢复'))
                  ]));
      if (yes != true || !mounted) return;
      final before = _data.copyWith();
      setState(() => _data = restored);
      if (await _persistImport(before)) {
        widget.appearance.value = restored.ui;
        _configureDemand();
        _setMessage('备份已恢复，代理保持停止，请选择节点后连接');
      }
    } catch (e) {
      _setMessage('恢复失败，原配置保留：${redactDiagnostics('$e')}');
    } finally {
      if (mounted) setState(() => _settingsBusy = false);
    }
  }

  Future<void> _updateAllSubscriptions() async {
    if (_busy || _running || _updatingAll) return;
    _updatingAll = true;
    try {
      for (final sub in List<Subscription>.of(_data.subscriptions)) {
        if (!mounted) break;
        await _updateSubscription(sub);
        if (_importCancelling) break;
      }
    } finally {
      _updatingAll = false;
    }
  }

  Widget _navItem(int index, IconData icon, String label, bool collapsed,
      {int? count}) {
    final scheme = Theme.of(context).colorScheme, selected = _page == index;
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        child: Tooltip(
            message: collapsed ? label : '',
            child: AnimatedContainer(
                duration: UiScope.duration(context),
                decoration: BoxDecoration(
                    color: selected ? wine : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: selected ? wine : Colors.transparent)),
                child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => setState(() {
                          _page = index;
                          if (index == 5) _settingsSection = 0;
                        }),
                    child: Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: collapsed ? 9 : 12, vertical: 11),
                        child: Row(
                            mainAxisAlignment: collapsed
                                ? MainAxisAlignment.center
                                : MainAxisAlignment.start,
                            children: [
                              Icon(icon,
                                  size: 17,
                                  color: selected
                                      ? Colors.white
                                      : scheme.onSurfaceVariant),
                              if (!collapsed) ...[
                                const SizedBox(width: 11),
                                Expanded(
                                    child: Text(label,
                                        style: TextStyle(
                                            fontSize: 14,
                                            color: selected
                                                ? Colors.white
                                                : scheme.onSurfaceVariant))),
                                if (count != null)
                                  Text('$count',
                                      style: mono.copyWith(
                                          fontSize: 11,
                                          color: selected
                                              ? Colors.white
                                              : scheme.onSurfaceVariant))
                              ]
                            ]))))));
  }
}

class _FindNodeIntent extends Intent {
  const _FindNodeIntent();
}

class _ConnectCancelled implements Exception {
  const _ConnectCancelled();
}

class _ImportIntent extends Intent {
  const _ImportIntent();
}

class _SettingsIntent extends Intent {
  const _SettingsIntent();
}
