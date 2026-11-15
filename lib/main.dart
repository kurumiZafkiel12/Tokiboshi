import 'package:flutter/material.dart';

import 'dart:async';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'bridge/core_bridge.dart';
import 'bridge/rust_core_bridge.dart';
import 'pages/dashboard_page.dart';
import 'pages/logs_page.dart';
import 'pages/nodes_page.dart';
import 'pages/panel_page.dart';
import 'pages/settings_page.dart';
import 'pages/subscriptions_page.dart';
import 'services/clash_api.dart';
import 'services/latency.dart';
import 'services/local_ports.dart';
import 'services/node_tags.dart';
import 'services/proxy_chain.dart';
import 'services/store.dart';
import 'services/subscription_fetcher.dart';
import 'services/subscription_resolver.dart';
import 'services/system_proxy.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    try {
      await windowManager.ensureInitialized();
    } catch (_) {
      // Window/tray niceties are optional; never block startup.
    }
  }
  await RustLib.init();
  runApp(TokiboshiApp(bridge: RustCoreBridge()));
}

class TokiboshiApp extends StatelessWidget {
  const TokiboshiApp({
    super.key,
    required this.bridge,
    this.store,
    this.systemProxy,
    this.fetcher,
    this.allocatePort = findAvailablePort,
  });

  final CoreBridge bridge;
  final Store? store;
  final SystemProxy? systemProxy;
  final SubscriptionFetcher? fetcher;
  final PortAllocator allocatePort;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tokiboshi',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFB71C1C),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: ShellPage(
        bridge: bridge,
        allocatePort: allocatePort,
        store: store ?? Store(),
        systemProxy: systemProxy ?? const WindowsSystemProxy(),
        fetcher: fetcher ?? const HttpSubscriptionFetcher(),
      ),
    );
  }
}

class ShellPage extends StatefulWidget {
  const ShellPage({
    super.key,
    required this.bridge,
    required this.store,
    required this.systemProxy,
    required this.fetcher,
    required this.allocatePort,
  });

  final CoreBridge bridge;
  final Store store;
  final SystemProxy systemProxy;
  final SubscriptionFetcher fetcher;
  final PortAllocator allocatePort;

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> with WindowListener, TrayListener {
  AppData _data = AppData();
  bool _running = false;
  bool _busy = false;
  bool _measuring = false;
  int _page = 0;
  bool _navCollapsed = false;
  String? _message;
  String? _coreVersion;
  int _restartCount = 0;
  String? _lastExit;
  String? _clashMode;
  Timer? _statusTimer;
  final Map<NodeInfo, int?> _latency = {};

  String get _dataDir => widget.store.dir.path;
  ClashApiClient get _clash => ClashApiClient(port: _data.clashApiPort);

  @override
  void initState() {
    super.initState();
    _load();
    _initTray();
    _statusTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _syncCoreStatus());
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final data = await widget.store.load();
    final running = await widget.bridge.coreRunning();
    if (!mounted) return;
    setState(() {
      _data = data;
      _running = running;
    });
    await _refreshCoreVersion();
    if (mounted && !_running && _data.autoConnect && _data.nodes.isNotEmpty) {
      await _toggleCore();
    }
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

  /// Keep the UI truthful about the supervised core: if it died for
  /// good (restart limit hit), reflect that and drop the system proxy.
  /// Also refreshes the Clash mode while running.
  Future<void> _syncCoreStatus() async {
    try {
      final status = await widget.bridge.coreStatus();
      if (!mounted) return;
      var changed = status.restartCount != _restartCount ||
          status.lastExit != _lastExit;
      if (_running && !status.running) {
        _running = false;
        _clashMode = null;
        changed = true;
        await widget.systemProxy.apply(false, _data.mixedPort);
        _message = status.lastExit != null
            ? '内核已退出：${status.lastExit}'
            : '内核已停止';
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

  Future<void> _persist() => widget.store.save(_data);

  void _setMessage(String? text) {
    if (mounted) setState(() => _message = text);
  }

  // ---- import / subscriptions ----

  Future<void> _importDialog() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入节点 / 订阅'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            maxLines: 10,
            autofocus: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '粘贴订阅链接（http/https，会自动拉取并存为订阅）、\n'
                  '分享链接（vless/vmess/trojan/hysteria2/hy2/ss）、多条链接、\n'
                  'base64 订阅内容、sing-box JSON 或 Clash YAML',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    await _importText(text.trim());
  }

  static bool _isHttpUrl(String s) =>
      s.startsWith('http://') || s.startsWith('https://');

  /// Fetch a subscription URL and parse it; if the returned content
  /// itself lists further subscription URLs (one link containing
  /// many), recursively fetch providers and merge their nodes.
  Future<ParseOutcome> _fetchParseExpand(String url) =>
      SubscriptionResolver(bridge: widget.bridge, fetcher: widget.fetcher).resolve(url);

  Future<void> _createChainDialog() async {
    if (_running || _busy || _data.nodes.length < 2) return;
    var entry = 0;
    var exit = 1;
    String? error;
    final name = TextEditingController(text: '链式代理');
    final result = await showDialog<List<NodeInfo>>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, update) => AlertDialog(
        title: const Text('添加链式代理'),
        content: SizedBox(width: 460, child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('连接顺序：本机 → 前置节点 → 落地节点 → 目标网站。保存独立副本，不随原订阅更新。'),
          const SizedBox(height: 12),
          TextField(controller: name, decoration: const InputDecoration(labelText: '链名称')),
          DropdownButtonFormField<int>(
            initialValue: entry, isExpanded: true,
            decoration: const InputDecoration(labelText: '前置节点'),
            items: [for (var i = 0; i < _data.nodes.length; i++)
              DropdownMenuItem(value: i, child: Text(_data.nodes[i].name, overflow: TextOverflow.ellipsis))],
            onChanged: (value) => update(() => entry = value ?? entry),
          ),
          DropdownButtonFormField<int>(
            initialValue: exit, isExpanded: true,
            decoration: const InputDecoration(labelText: '落地节点'),
            items: [for (var i = 0; i < _data.nodes.length; i++)
              DropdownMenuItem(value: i, child: Text(_data.nodes[i].name, overflow: TextOverflow.ellipsis))],
            onChanged: (value) => update(() => exit = value ?? exit),
          ),
          if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () {
            try { Navigator.pop(context, createProxyChain(_data.nodes, entry, exit, name.text)); }
            on FormatException catch (e) { update(() => error = e.message); }
          }, child: const Text('添加')),
        ],
      )),
    );
    name.dispose();
    if (result == null || !mounted) return;
    setState(() {
      _data.nodes = [..._data.nodes, ...result];
      _data.selectedIndex = _data.nodes.length - 1;
      _message = '链式代理已添加，已选择落地节点；请保留同组前置节点';
    });
    await _persist();
  }

  Future<void> _importText(String trimmed) async {
    // Split pasted content: standalone http(s) lines are subscription
    // URLs (a single pasted link may carry many nodes); the rest is
    // parsed as links/content.
    final lines = trimmed
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final urlLines = lines.where(_isHttpUrl).toList();
    final rest = lines.where((l) => !_isHttpUrl(l)).join('\n');
    if (urlLines.isNotEmpty) {
      for (final url in urlLines) {
        final uri = Uri.tryParse(url);
        final name = (uri != null && uri.host.isNotEmpty) ? uri.host : '订阅';
        await _addSubscription(name, url);
      }
      if (rest.isEmpty) return;
      trimmed = rest;
    }
    setState(() => _busy = true);
    try {
      List<NodeInfo> imported;
      var skipped = const <String>[];
      if (trimmed.contains('\n') || !trimmed.contains('://')) {
        final outcome = await widget.bridge.parseSubscription(trimmed);
        imported = outcome.nodes;
        skipped = outcome.skipped;
      } else {
        try {
          imported = [await widget.bridge.parseShareLink(trimmed)];
        } catch (_) {
          final outcome = await widget.bridge.parseSubscription(trimmed);
          imported = outcome.nodes;
          skipped = outcome.skipped;
        }
      }
      setState(() {
        _data.nodes = [..._data.nodes, ...resolvePolicyGroups(imported)];
        if (_data.selectedIndex < 0 && _data.nodes.isNotEmpty) {
          _data.selectedIndex = 0;
        }
        _message = '已导入 ${imported.length} 个节点${_skippedNote(skipped)}';
      });
      await _persist();
    } catch (e) {
      _setMessage('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "；另有 N 个暂不支持已跳过（wireguard ×1）" or '' when none.
  String _skippedNote(List<String> skipped) {
    if (skipped.isEmpty) return '';
    return '；跳过/未完成 ${skipped.length} 项：${skipped.take(5).join('；')}'
        '${skipped.length > 5 ? '；其余 ${skipped.length - 5} 项' : ''}';
  }

  Future<void> _addSubscriptionDialog() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final result = await showDialog<({String name, String url})>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加订阅'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '名称（可空，默认用域名）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: urlController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '订阅链接（http/https）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, (
              name: nameController.text.trim(),
              url: urlController.text.trim(),
            )),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (result == null || result.url.isEmpty) return;
    var name = result.name;
    if (name.isEmpty) {
      final uri = Uri.tryParse(result.url);
      name = (uri != null && uri.host.isNotEmpty) ? uri.host : '订阅';
    }
    await _addSubscription(name, result.url);
  }

  String _subscriptionReport(ParseOutcome outcome) {
    final counts = <String, int>{};
    for (final node in outcome.nodes) {
      if (node.isPolicy) continue;
      final group = node.group.isEmpty ? '内联节点' : node.group;
      counts[group] = (counts[group] ?? 0) + 1;
    }
    return ['策略组：${outcome.nodes.where((n) => n.isPolicy).length} 个', for (final entry in counts.entries) '${entry.key}：${entry.value} 个', ...outcome.skipped].join('\n');
  }

  Future<void> _addSubscription(String name, String url) async {
    setState(() => _busy = true);
    try {
      final outcome = await _fetchParseExpand(url);
      final id = 'sub-${DateTime.now().millisecondsSinceEpoch}';
      final nodes = resolvePolicyGroups(outcome.nodes.map((n) => n.withSource(id)).toList());
      setState(() {
        _data.subscriptions = [
          ..._data.subscriptions,
          Subscription(
            id: id,
            name: name,
            url: url,
            updatedAt: DateTime.now().toIso8601String(),
            lastReport: _subscriptionReport(outcome),
          ),
        ];
        _data.nodes = [..._data.nodes, ...nodes];
        if (_data.selectedIndex < 0 && _data.nodes.isNotEmpty) {
          _data.selectedIndex = 0;
        }
        _message =
            '订阅「$name」已添加：${nodes.where((n) => !n.isPolicy).length} 个节点${_skippedNote(outcome.skipped)}';
      });
      await _persist();
    } catch (e) {
      _setMessage('订阅添加失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _updateSubscription(Subscription sub) async {
    setState(() => _busy = true);
    try {
      final outcome = await _fetchParseExpand(sub.url);
      final selected = _data.selected;
      final selectedFromSub = selected != null && selected.source == sub.id;
      var fresh = outcome.nodes.map((n) => n.withSource(sub.id)).toList();
      final retained = retainFailedSourceNodes(
          _data.nodes.where((n) => n.source == sub.id).toList(), fresh, outcome.failedGroups);
      fresh.addAll(retained);
      fresh = resolvePolicyGroups(fresh);
      setState(() {
        _data.nodes = [
          for (final n in _data.nodes)
            if (n.source != sub.id) n,
          ...fresh,
        ];
        _data.subscriptions = [
          for (final s in _data.subscriptions)
            if (s.id == sub.id)
              s.copyWith(updatedAt: DateTime.now().toIso8601String(),
                  lastReport: '${_subscriptionReport(outcome)}${retained.isEmpty ? '' : '\n保留上次成功获取的 ${retained.length} 个节点（相关来源更新失败）'}')
            else
              s,
        ];
        if (selected != null && !selectedFromSub) {
          _data.selectedIndex = _data.nodes.indexOf(selected);
        } else if (selectedFromSub) {
          final idx = _data.nodes.indexWhere(
            (n) => n.source == sub.id && n.name == selected.name,
          );
          _data.selectedIndex =
              idx >= 0 ? idx : (_data.nodes.isEmpty ? -1 : 0);
        }
        _message = '订阅「${sub.name}」已更新：${fresh.where((n) => !n.isPolicy).length} 个节点${_skippedNote(outcome.skipped)}';
      });
      await _persist();
    } catch (e) {
      _setMessage('订阅更新失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteSubscription(Subscription sub) async {
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
      _message = '订阅「${sub.name}」已删除';
    });
    await _persist();
  }

  // ---- nodes ----

  String _nodeTag(NodeInfo node) {
    final index = _data.nodes.indexOf(node);
    return index < 0 ? node.name : assignNodeTags(_data.nodes.map((n) => n.name))[index];
  }

  Future<void> _selectNode(int index) async {
    setState(() => _data.selectedIndex = index);
    await _persist();
    // While the core runs, switch the selector live through the
    // Clash API (node tags are assigned from names). If the live
    // switch fails, the choice still applies on the next start via
    // the generated config's selector default.
    if (_running && index >= 0 && index < _data.nodes.length) {
      final node = _data.nodes[index];
      try {
        await _clash.select('proxy', _nodeTag(node));
        _setMessage('已切换到 ${node.name}');
      } catch (_) {
        _setMessage('已选中 ${node.name}（重启内核后生效）');
      }
    }
    _refreshTray();
  }

  Future<void> _deleteNode(int index) async {
    setState(() {
      _data.nodes = [..._data.nodes]..removeAt(index);
      if (_data.selectedIndex == index) {
        _data.selectedIndex = _data.nodes.isEmpty ? -1 : 0;
      } else if (_data.selectedIndex > index) {
        _data.selectedIndex -= 1;
      }
    });
    await _persist();
  }

  static const _udpProtocols = {'hysteria', 'hysteria2', 'tuic'};

  /// While the core runs, measure through the Clash API delay
  /// endpoint (the real outbound). While stopped, only TCP-based
  /// protocols can be probed honestly — a TCP connect to a UDP
  /// (hy2/tuic) port says nothing, so those are skipped instead of
  /// being reported as failures.
  Future<void> _measureNode(NodeInfo node) async {
    if (_measuring) return;
    if (!_running && _udpProtocols.contains(node.protocol)) {
      _setMessage('内核未启动：${node.protocol} 是 UDP 协议，测速需先启动内核');
      return;
    }
    _measuring = true;
    final ms = _running
        ? await _clash.delay(_nodeTag(node))
        : await tcpLatency(node.server, node.serverPort);
    _measuring = false;
    if (mounted) setState(() => _latency[node] = ms);
  }

  Future<void> _measureAll() async {
    if (_measuring) return;
    _measuring = true;
    var skipped = 0;
    for (final node in List.of(_data.nodes)) {
      if (node.isPolicy) continue;
      if (!_running && _udpProtocols.contains(node.protocol)) {
        skipped++;
        continue;
      }
      final ms = _running
          ? await _clash.delay(_nodeTag(node))
          : await tcpLatency(node.server, node.serverPort);
      if (!mounted) {
        _measuring = false;
        return;
      }
      setState(() => _latency[node] = ms);
    }
    _measuring = false;
    if (skipped > 0) {
      _setMessage('已跳过 $skipped 个 UDP 协议节点（内核未启动时测不准），启动内核后可测全部');
    }
  }

  Future<void> _openExternalPanel() async {
    final url = 'http://127.0.0.1:${_data.clashApiPort}/ui';
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
        MenuItem(key: 'mode_rule', label: '规则模式', checked: _clashMode != 'Global' && _clashMode != 'Direct', disabled: !_running),
        MenuItem(key: 'mode_global', label: '全局模式', checked: _clashMode == 'Global', disabled: !_running),
        MenuItem(key: 'mode_direct', label: '直连模式', checked: _clashMode == 'Direct', disabled: !_running),
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
    windowManager.hide();
  }

  Future<void> _quitApp() async {
    try {
      if (_running) {
        await widget.bridge.stopCore();
        if (_data.systemProxy) {
          await widget.systemProxy.apply(false, _data.mixedPort);
        }
      }
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
    _setMessage('正在下载 sing-box 内核（首次启动需要）…');
    await widget.bridge.startEnsureCore(_dataDir);
    for (var i = 0; i < 200; i++) {
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

  Future<void> _toggleCore() async {
    if (_busy) return;
    setState(() => _busy = true);
    var started = false;
    try {
      if (_running) {
        await widget.bridge.stopCore();
        await widget.systemProxy.apply(false, _data.mixedPort);
        setState(() {
          _running = false;
          _clashMode = null;
          _message = '已停止';
        });
        return;
      }
      if (_data.nodes.isEmpty) {
        _setMessage('先导入节点');
        return;
      }
      final binary = await _ensureCoreBinary();
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
      final config = await widget.bridge.buildConfig(
        nodes: _data.nodes
            .map((n) => NodeSpec(name: n.name, outboundJson: n.outboundJson))
            .toList(),
        mixedPort: _data.mixedPort,
        clashApiPort: _data.clashApiPort,
        enableTun: _data.enableTun,
        blockAds: _data.blockAds,
        bypassCn: _data.bypassCn,
        dataDir: _dataDir,
        selectedName: selected == null ? null : assignNodeTags(_data.nodes.map((n) => n.name))[_data.selectedIndex],
      );
      final configFile = await widget.store.writeRuntimeConfig(config);
      await widget.bridge.startCore(
        singBoxPath: binary,
        configPath: configFile.path,
      );
      started = true;
      if (_data.systemProxy) {
        await widget.systemProxy.apply(true, _data.mixedPort);
      }
      setState(() {
        _running = true;
        _restartCount = 0;
        _lastExit = null;
        _message = '运行中：${_data.nodes.where((n) => !n.isPolicy).length} 个节点 · mixed 127.0.0.1:${_data.mixedPort}'
            ' · 面板 127.0.0.1:${_data.clashApiPort}/ui'
            '${_data.systemProxy ? ' · 系统代理已开启' : ''}'
            '${portsChanged ? ' · 原端口被占用，已自动更换并保存端口' : ''}';
      });
    } catch (e) {
      if (started) {
        try { await widget.bridge.stopCore(); } catch (_) {}
        try { await widget.systemProxy.apply(false, _data.mixedPort); } catch (_) {}
        if (mounted) setState(() => _running = false);
      }
      _setMessage('启动失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
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
    await _toggleCore();
  }

  Future<void> _ensureFromSettings() async {
    _setMessage('正在检查/下载 sing-box 内核…');
    await widget.bridge.startEnsureCore(_dataDir);
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

  Future<void> _saveSettings(int port, int clashApiPort, String singBoxPath) async {
    setState(() {
      _data.mixedPort = port;
      _data.clashApiPort = clashApiPort;
      _data.singBoxPath = singBoxPath;
      _message = '设置已保存';
    });
    await _persist();
  }

  Future<void> _setSystemProxy(bool value) async {
    setState(() {
      _data.systemProxy = value;
    });
    await _persist();
    if (_running) {
      await widget.systemProxy.apply(value, _data.mixedPort);
      _setMessage(value ? '系统代理已开启' : '系统代理已关闭');
    }
  }

  Future<void> _setTun(bool value) async {
    setState(() {
      _data.enableTun = value;
    });
    await _persist();
    if (_running) {
      _setMessage(value ? '虚拟网卡已开启，正在重启内核…' : '虚拟网卡已关闭，正在重启内核…');
      await _restartCore();
    } else {
      _setMessage(value ? '虚拟网卡已开启（下次启动生效）' : '虚拟网卡已关闭');
    }
  }

  Future<void> _setMode(String mode) async {
    try {
      await _clash.setMode(mode);
      if (mounted) setState(() => _clashMode = mode);
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
          onStart: _toggleCore,
          onOpenExternal: _openExternalPanel,
        );
      case 2:
        page = NodesPage(
          nodes: _data.nodes,
          subscriptions: _data.subscriptions,
          selectedIndex: _data.selectedIndex,
          running: _running,
          busy: _busy,
          latency: _latency,
          onSelect: _selectNode,
          onDelete: _deleteNode,
          onImport: _importDialog,
          onMeasureAll: _measureAll,
          onCreateChain: _createChainDialog,
        );
      case 3:
        page = SubscriptionsPage(
          subscriptions: _data.subscriptions,
          nodeCounts: nodeCounts,
          running: _running,
          busy: _busy,
          onAdd: _addSubscriptionDialog,
          onUpdate: _updateSubscription,
          onDelete: _deleteSubscription,
        );
      case 4:
        page = LogsPage(fetchLogs: widget.bridge.coreLogs);
      case 5:
        page = SettingsPage(
          mixedPort: _data.mixedPort,
          clashApiPort: _data.clashApiPort,
          singBoxPath: _data.singBoxPath,
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
        );
      default:
        page = DashboardPage(
          running: _running,
          busy: _busy,
          selected: selected,
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
          onOpenPanel: () => setState(() => _page = 1),
          onTunChanged: _setTun,
          onSystemProxyChanged: _setSystemProxy,
          onModeChanged: _setMode,
          onMeasureSelected: () {
            final node = _data.selected;
            if (node != null) _measureNode(node);
          },
        );
    }
    return Scaffold(
      body: Row(
        children: [
          Container(
            width: _navCollapsed ? 68 : 208,
            color: scheme.surfaceContainerLow,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(_navCollapsed ? 16 : 16, 18, 16, 14),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.asset(
                          'assets/icon.png',
                          width: 36,
                          height: 36,
                        ),
                      ),
                      if (!_navCollapsed) ...[
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Tokiboshi',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                _navItem(0, Icons.dashboard_outlined, '仪表盘'),
                _navItem(1, Icons.web_asset_outlined, '面板'),
                _navItem(2, Icons.dns_outlined, '节点'),
                _navItem(3, Icons.subscriptions_outlined, '订阅'),
                _navItem(4, Icons.terminal_outlined, '日志'),
                _navItem(5, Icons.settings_outlined, '设置'),
                const Spacer(),
                IconButton(
                  icon: Icon(
                    _navCollapsed
                        ? Icons.keyboard_double_arrow_right
                        : Icons.keyboard_double_arrow_left,
                    size: 19,
                  ),
                  tooltip: _navCollapsed ? '展开侧栏' : '收起侧栏',
                  onPressed: () => setState(() => _navCollapsed = !_navCollapsed),
                ),
                if (!_navCollapsed)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('v0.5.3 · sing-box 1.14.4'),
                  ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_message != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    color: scheme.surfaceContainerHighest,
                    child: Text(_message!),
                  ),
                if (_busy) const LinearProgressIndicator(minHeight: 2),
                Expanded(child: page),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _navItem(int index, IconData icon, String label) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _page == index;
    final item = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _page = index),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: _navCollapsed ? 8 : 12,
              vertical: 10,
            ),
            child: Row(
              mainAxisAlignment:
                  _navCollapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                Icon(
                  icon,
                  size: 19,
                  color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                ),
                if (!_navCollapsed) ...[
                  const SizedBox(width: 10),
                  Text(
                    label,
                    style: TextStyle(
                      color: selected ? scheme.onPrimaryContainer : scheme.onSurface,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return _navCollapsed ? Tooltip(message: label, child: item) : item;
  }
}
