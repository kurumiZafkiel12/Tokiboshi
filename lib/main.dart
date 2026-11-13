import 'package:flutter/material.dart';

import 'bridge/core_bridge.dart';

void main() {
  runApp(TokiboshiApp(bridge: LocalCoreBridge()));
}

class TokiboshiApp extends StatelessWidget {
  const TokiboshiApp({super.key, required this.bridge});

  final CoreBridge bridge;

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
      home: HomePage(bridge: bridge),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.bridge});

  final CoreBridge bridge;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _outboundController = TextEditingController(
    text: '{\n  "type": "hysteria2",\n  "server": "example.com",\n'
        '  "server_port": 443,\n  "password": "",\n'
        '  "tls": {"enabled": true, "server_name": "example.com"}\n}',
  );
  String? _message;
  bool _busy = false;

  bool get _running => widget.bridge.state == CoreState.running;

  @override
  void dispose() {
    _outboundController.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    setState(() => _busy = true);
    try {
      if (_running) {
        await widget.bridge.stop();
        _message = '已停止';
      } else {
        final config = widget.bridge.buildConfig(
          outboundJson: _outboundController.text,
        );
        await widget.bridge.start(config);
        _message = '已启动，本地 mixed 入口 127.0.0.1:7890';
      }
    } on FormatException catch (e) {
      _message = '配置错误：${e.message}';
    } on StateError catch (e) {
      _message = e.message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Tokiboshi')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: Icon(
                _running ? Icons.power : Icons.power_off,
                color: _running ? Colors.greenAccent : scheme.outline,
              ),
              title: Text(_running ? 'sing-box 运行中' : 'sing-box 已停止'),
              subtitle: const Text('内核 sing-box · 中间层 Rust'),
            ),
          ),
          const SizedBox(height: 16),
          const Text('节点 outbound（sing-box JSON）'),
          const SizedBox(height: 8),
          TextField(
            controller: _outboundController,
            enabled: !_running,
            maxLines: 8,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _toggle,
            child: Text(_running ? '停止' : '启动'),
          ),
          if (_message != null) ...[
            const SizedBox(height: 12),
            Text(_message!),
          ],
        ],
      ),
    );
  }
}
