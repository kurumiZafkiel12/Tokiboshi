import 'package:flutter/material.dart';

/// Settings: local port, sing-box path, system proxy, about.
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.mixedPort,
    required this.singBoxPath,
    required this.systemProxy,
    required this.running,
    required this.dataFilePath,
    required this.onSave,
    required this.onSystemProxyChanged,
  });

  final int mixedPort;
  final String singBoxPath;
  final bool systemProxy;
  final bool running;
  final String dataFilePath;
  final void Function(int port, String singBoxPath) onSave;
  final ValueChanged<bool> onSystemProxyChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final _portController = TextEditingController(text: '${widget.mixedPort}');
  late final _pathController = TextEditingController(text: widget.singBoxPath);
  String? _error;

  @override
  void dispose() {
    _portController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  void _save() {
    final port = int.tryParse(_portController.text.trim()) ?? 0;
    if (port <= 0 || port > 65535) {
      setState(() => _error = '本地端口无效：${_portController.text}');
      return;
    }
    setState(() => _error = null);
    widget.onSave(port, _pathController.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('设置', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _portController,
                    enabled: !widget.running,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '本地端口（mixed，HTTP/SOCKS 共用）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pathController,
                    enabled: !widget.running,
                    decoration: const InputDecoration(
                      labelText: 'sing-box 路径（留空 = 程序目录/PATH）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: widget.running ? null : _save,
                      child: const Text('保存设置'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              title: const Text('系统代理'),
              subtitle: const Text('启动时写入系统代理（127.0.0.1:本地端口），停止时关闭'),
              value: widget.systemProxy,
              onChanged: widget.running ? null : widget.onSystemProxyChanged,
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('关于', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  const Text('Tokiboshi v0.2.0 · Flutter 界面 + Rust 中间层 + sing-box 内核'),
                  const Text('内置 sing-box 1.11.15（Release 包随附）'),
                  Text('数据文件：${widget.dataFilePath}'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
