import 'package:flutter/material.dart';

import 'bridge/core_bridge.dart';
import 'bridge/rust_core_bridge.dart';
import 'pages/dashboard_page.dart';
import 'pages/nodes_page.dart';
import 'pages/settings_page.dart';
import 'pages/subscriptions_page.dart';
import 'services/latency.dart';
import 'services/store.dart';
import 'services/subscription_fetcher.dart';
import 'services/system_proxy.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  });

  final CoreBridge bridge;
  final Store? store;
  final SystemProxy? systemProxy;
  final SubscriptionFetcher? fetcher;

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
  });

  final CoreBridge bridge;
  final Store store;
  final SystemProxy systemProxy;
  final SubscriptionFetcher fetcher;

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  AppData _data = AppData();
  bool _running = false;
  bool _busy = false;
  bool _measuring = false;
  int _page = 0;
  String? _message;
  final Map<NodeInfo, int?> _latency = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await widget.store.load();
    final running = await widget.bridge.coreRunning();
    if (!mounted) return;
    setState(() {
      _data = data;
      _running = running;
    });
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

  Future<void> _importText(String trimmed) async {
    final isUrl = !trimmed.contains('\n') &&
        (trimmed.startsWith('http://') || trimmed.startsWith('https://'));
    if (isUrl) {
      final uri = Uri.tryParse(trimmed);
      final name = (uri != null && uri.host.isNotEmpty) ? uri.host : '订阅';
      await _addSubscription(name, trimmed);
      return;
    }
    setState(() => _busy = true);
    try {
      List<NodeInfo> imported;
      if (trimmed.contains('\n') || !trimmed.contains('://')) {
        imported = await widget.bridge.parseSubscription(trimmed);
      } else {
        try {
          imported = [await widget.bridge.parseShareLink(trimmed)];
        } catch (_) {
          imported = await widget.bridge.parseSubscription(trimmed);
        }
      }
      setState(() {
        _data.nodes = [..._data.nodes, ...imported];
        if (_data.selectedIndex < 0 && _data.nodes.isNotEmpty) {
          _data.selectedIndex = 0;
        }
        _message = '已导入 ${imported.length} 个节点';
      });
      await _persist();
    } catch (e) {
      _setMessage('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

  Future<void> _addSubscription(String name, String url) async {
    setState(() => _busy = true);
    try {
      final content = await widget.fetcher.fetch(url);
      final parsed = await widget.bridge.parseSubscription(content);
      final id = 'sub-${DateTime.now().millisecondsSinceEpoch}';
      final nodes = parsed.map((n) => n.withSource(id)).toList();
      setState(() {
        _data.subscriptions = [
          ..._data.subscriptions,
          Subscription(
            id: id,
            name: name,
            url: url,
            updatedAt: DateTime.now().toIso8601String(),
          ),
        ];
        _data.nodes = [..._data.nodes, ...nodes];
        if (_data.selectedIndex < 0 && _data.nodes.isNotEmpty) {
          _data.selectedIndex = 0;
        }
        _message = '订阅「$name」已添加：${nodes.length} 个节点';
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
      final content = await widget.fetcher.fetch(sub.url);
      final parsed = await widget.bridge.parseSubscription(content);
      final selected = _data.selected;
      final selectedFromSub = selected != null && selected.source == sub.id;
      final fresh = parsed.map((n) => n.withSource(sub.id)).toList();
      setState(() {
        _data.nodes = [
          for (final n in _data.nodes)
            if (n.source != sub.id) n,
          ...fresh,
        ];
        _data.subscriptions = [
          for (final s in _data.subscriptions)
            if (s.id == sub.id)
              s.copyWith(updatedAt: DateTime.now().toIso8601String())
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
        _message = '订阅「${sub.name}」已更新：${fresh.length} 个节点';
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

  Future<void> _selectNode(int index) async {
    setState(() => _data.selectedIndex = index);
    await _persist();
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

  Future<void> _measureNode(NodeInfo node) async {
    if (_measuring) return;
    _measuring = true;
    final ms = await tcpLatency(node.server, node.serverPort);
    _measuring = false;
    if (mounted) setState(() => _latency[node] = ms);
  }

  Future<void> _measureAll() async {
    if (_measuring) return;
    _measuring = true;
    for (final node in List.of(_data.nodes)) {
      final ms = await tcpLatency(node.server, node.serverPort);
      if (!mounted) {
        _measuring = false;
        return;
      }
      setState(() => _latency[node] = ms);
    }
    _measuring = false;
  }

  // ---- core ----

  Future<void> _toggleCore() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_running) {
        await widget.bridge.stopCore();
        await widget.systemProxy.apply(false, _data.mixedPort);
        setState(() {
          _running = false;
          _message = '已停止';
        });
        return;
      }
      final node = _data.selected;
      if (node == null) {
        _setMessage('先导入并选择一个节点');
        return;
      }
      final config = await widget.bridge.buildConfig(
        outboundJson: node.outboundJson,
        mixedPort: _data.mixedPort,
      );
      final configFile = await widget.store.writeRuntimeConfig(config);
      await widget.bridge.startCore(
        singBoxPath: resolveSingBoxPath(_data.singBoxPath),
        configPath: configFile.path,
      );
      if (_data.systemProxy) {
        await widget.systemProxy.apply(true, _data.mixedPort);
      }
      setState(() {
        _running = true;
        _message = '运行中：${node.name} · 本地 mixed 127.0.0.1:${_data.mixedPort}'
            '${_data.systemProxy ? ' · 系统代理已开启' : ''}';
      });
    } catch (e) {
      _setMessage('启动失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveSettings(int port, String singBoxPath) async {
    setState(() {
      _data.mixedPort = port;
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
  }

  // ---- layout ----

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _data.selected;
    final nodeCounts = <String, int>{};
    for (final n in _data.nodes) {
      if (n.source.isNotEmpty) {
        nodeCounts[n.source] = (nodeCounts[n.source] ?? 0) + 1;
      }
    }
    final Widget page;
    switch (_page) {
      case 1:
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
        );
      case 2:
        page = SubscriptionsPage(
          subscriptions: _data.subscriptions,
          nodeCounts: nodeCounts,
          running: _running,
          busy: _busy,
          onAdd: _addSubscriptionDialog,
          onUpdate: _updateSubscription,
          onDelete: _deleteSubscription,
        );
      case 3:
        page = SettingsPage(
          mixedPort: _data.mixedPort,
          singBoxPath: _data.singBoxPath,
          systemProxy: _data.systemProxy,
          running: _running,
          dataFilePath: widget.store.file.path,
          onSave: _saveSettings,
          onSystemProxyChanged: _setSystemProxy,
        );
      default:
        page = DashboardPage(
          running: _running,
          busy: _busy,
          selected: selected,
          nodeCount: _data.nodes.length,
          subscriptionCount: _data.subscriptions.length,
          mixedPort: _data.mixedPort,
          systemProxy: _data.systemProxy,
          selectedLatency: selected == null ? null : _latency[selected],
          selectedMeasured: selected != null && _latency.containsKey(selected),
          onToggle: _toggleCore,
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
            width: 208,
            color: scheme.surfaceContainerLow,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
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
                  ),
                ),
                _navItem(0, Icons.dashboard_outlined, '仪表盘'),
                _navItem(1, Icons.dns_outlined, '节点'),
                _navItem(2, Icons.subscriptions_outlined, '订阅'),
                _navItem(3, Icons.settings_outlined, '设置'),
                const Spacer(),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('v0.2.1 · sing-box 1.11.15'),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _page = index),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 19,
                  color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? scheme.onPrimaryContainer : scheme.onSurface,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
