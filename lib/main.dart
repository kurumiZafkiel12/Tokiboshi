import 'package:flutter/material.dart';

import 'bridge/core_bridge.dart';
import 'bridge/rust_core_bridge.dart';
import 'services/store.dart';
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
  });

  final CoreBridge bridge;
  final Store? store;
  final SystemProxy? systemProxy;

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
      home: HomePage(
        bridge: bridge,
        store: store ?? Store(),
        systemProxy: systemProxy ?? const WindowsSystemProxy(),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.bridge,
    required this.store,
    required this.systemProxy,
  });

  final CoreBridge bridge;
  final Store store;
  final SystemProxy systemProxy;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  AppData _data = AppData();
  bool _running = false;
  bool _busy = false;
  bool _systemProxy = true;
  String? _message;
  final _portController = TextEditingController(text: '7890');
  final _corePathController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _portController.dispose();
    _corePathController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final data = await widget.store.load();
    final running = await widget.bridge.coreRunning();
    if (!mounted) return;
    setState(() {
      _data = data;
      _running = running;
      _portController.text = '${data.mixedPort}';
      _corePathController.text = data.singBoxPath;
    });
  }

  Future<void> _persist() => widget.store.save(_data);

  void _setMessage(String? text) {
    if (mounted) setState(() => _message = text);
  }

  Future<void> _import() async {
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
              hintText: '粘贴分享链接（vless/vmess/trojan/hysteria2/ss）、'
                  '多条链接、base64 订阅内容或 sing-box JSON 配置',
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
    setState(() => _busy = true);
    try {
      final trimmed = text.trim();
      final List<NodeInfo> imported;
      if (trimmed.contains('\n') || !trimmed.contains('://')) {
        imported = await widget.bridge.parseSubscription(trimmed);
      } else {
        imported = [await widget.bridge.parseShareLink(trimmed)];
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
      final port = int.tryParse(_portController.text.trim()) ?? 0;
      if (port <= 0 || port > 65535) {
        _setMessage('本地端口无效：${_portController.text}');
        return;
      }
      _data.mixedPort = port;
      _data.singBoxPath = _corePathController.text.trim();
      await _persist();
      final config = await widget.bridge.buildConfig(
        outboundJson: node.outboundJson,
        mixedPort: port,
      );
      final configFile = await widget.store.writeRuntimeConfig(config);
      await widget.bridge.startCore(
        singBoxPath: resolveSingBoxPath(_data.singBoxPath),
        configPath: configFile.path,
      );
      if (_systemProxy) await widget.systemProxy.apply(true, port);
      setState(() {
        _running = true;
        _message = '运行中：${node.name} · 本地 mixed 127.0.0.1:$port'
            '${_systemProxy ? ' · 系统代理已开启' : ''}';
      });
    } catch (e) {
      _setMessage('启动失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tokiboshi'),
        actions: [
          IconButton(
            onPressed: _busy || _running ? null : _import,
            icon: const Icon(Icons.add_link),
            tooltip: '导入节点 / 订阅',
          ),
        ],
      ),
      body: Column(
        children: [
          Card(
            margin: const EdgeInsets.all(12),
            child: ListTile(
              leading: Icon(
                _running ? Icons.power : Icons.power_off,
                color: _running ? Colors.greenAccent : scheme.outline,
              ),
              title: Text(_running ? 'sing-box 运行中' : 'sing-box 已停止'),
              subtitle: Text(
                _data.selected?.name ?? '未选择节点',
              ),
              trailing: FilledButton(
                onPressed: _busy ? null : _toggleCore,
                child: Text(_running ? '停止' : '启动'),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _portController,
                    enabled: !_running,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '本地端口',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _corePathController,
                    enabled: !_running,
                    decoration: const InputDecoration(
                      labelText: 'sing-box 路径（留空 = 程序目录/PATH）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: _systemProxy,
                      onChanged: _running
                          ? null
                          : (v) => setState(() => _systemProxy = v),
                    ),
                    const Text('系统代理'),
                  ],
                ),
              ],
            ),
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(_message!),
              ),
            ),
          const Divider(height: 24),
          Expanded(
            child: _data.nodes.isEmpty
                ? const Center(child: Text('还没有节点，点右上角图标导入'))
                : ListView.builder(
                    itemCount: _data.nodes.length,
                    itemBuilder: (context, index) {
                      final node = _data.nodes[index];
                      final selected = index == _data.selectedIndex;
                      return ListTile(
                        leading: Icon(
                          selected
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                        ),
                        title: Text(node.name),
                        selected: selected,
                        onTap: _running
                            ? null
                            : () async {
                                setState(() => _data.selectedIndex = index);
                                await _persist();
                              },
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed:
                              _running ? null : () => _deleteNode(index),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
