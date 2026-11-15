import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';

/// The zashboard panel, served by sing-box itself at
/// http://127.0.0.1:<clashApiPort>/ui and embedded in a WebView2
/// view. The UI bundle is downloaded by the core on first start,
/// so before loading we poll until the core actually serves it
/// (a blind loadUrl too early sticks forever on an error page).
class PanelPage extends StatefulWidget {
  const PanelPage({
    super.key,
    required this.running,
    required this.clashApiPort,
    required this.onStart,
    this.clashApiSecret = '',
    this.onOpenExternal,
  });

  final bool running;
  final int clashApiPort;
  final VoidCallback onStart;

  /// Bearer secret of the controller; passed to zashboard via query
  /// parameters so the embedded panel authenticates automatically.
  final String clashApiSecret;
  final VoidCallback? onOpenExternal;

  @override
  State<PanelPage> createState() => _PanelPageState();
}

/// Shared by the embedded panel and "open in browser": the /ui URL
/// carrying the controller secret as query parameters, which
/// zashboard reads to authenticate itself.
String panelUrl(int port, String secret) {
  final query = secret.isEmpty
      ? ''
      : '?hostname=127.0.0.1&port=$port&secret=${Uri.encodeComponent(secret)}';
  return 'http://127.0.0.1:$port/ui/$query';
}

class _PanelPageState extends State<PanelPage> {
  WebviewController? _controller;
  String? _error;
  String _status = '';

  String get _base => 'http://127.0.0.1:${widget.clashApiPort}';

  String get _url => panelUrl(widget.clashApiPort, widget.clashApiSecret);

  @override
  void initState() {
    super.initState();
    if (widget.running) _initWebView();
  }

  @override
  void didUpdateWidget(PanelPage old) {
    super.didUpdateWidget(old);
    if (widget.running && !old.running) {
      _initWebView();
    }
    if (!widget.running && old.running) {
      _controller?.dispose();
      _controller = null;
      _error = null;
    }
  }

  /// Wait until the core serves the UI (it downloads zashboard on
  /// first start, which can take a while through the proxy).
  Future<bool> _waitForUi() async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 3);
    try {
      for (var i = 0; i < 30; i++) {
        if (!mounted || !widget.running) return false;
        try {
          final req = await client.getUrl(Uri.parse('$_base/ui/'));
          final resp = await req.close();
          await resp.drain<void>();
          if (resp.statusCode == 200) return true;
        } catch (_) {
          // Not up yet; keep waiting.
        }
        if (mounted) {
          setState(() => _status = '正在等待面板就绪（内核首次启动要先下载面板，约数十秒）… ${i + 1}/30');
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _initWebView() async {
    if (!Platform.isWindows) {
      setState(() => _error = '内嵌面板仅支持 Windows 桌面');
      return;
    }
    setState(() {
      _error = null;
      _status = '正在等待面板就绪…';
    });
    final ready = await _waitForUi();
    if (!mounted) return;
    if (!ready) {
      setState(() {
        _status = '';
        _error = '面板还没就绪：内核可能还没把 zashboard 下载下来。\n'
            '先看「日志」页有没有下载失败，网络通了点「重新加载」再试。';
      });
      return;
    }
    try {
      final controller = _controller ?? WebviewController();
      if (_controller == null) {
        await controller.initialize();
        await controller.setBackgroundColor(Colors.transparent);
        await controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      }
      await controller.loadUrl(_url);
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _status = '';
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'WebView 初始化失败（需要 WebView2 运行时）：$e';
          _status = '';
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.running) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.web_asset_off, size: 44),
            const SizedBox(height: 12),
            const Text('内核未运行，面板不可用'),
            const SizedBox(height: 12),
            FilledButton(onPressed: widget.onStart, child: const Text('启动内核')),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
          child: Row(
            children: [
              const Icon(Icons.web_asset_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_url, style: const TextStyle(fontSize: 12)),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 19),
                tooltip: '重新加载面板',
                onPressed: _initWebView,
              ),
              IconButton(
                icon: const Icon(Icons.open_in_browser, size: 19),
                tooltip: '在浏览器打开',
                onPressed: widget.onOpenExternal,
              ),
            ],
          ),
        ),
        Expanded(child: _body(context)),
      ],
    );
  }

  Widget _body(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(onPressed: _initWebView, child: const Text('重新加载')),
                  OutlinedButton(
                    onPressed: widget.onOpenExternal,
                    child: const Text('在浏览器打开'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    final controller = _controller;
    if (controller == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(_status, textAlign: TextAlign.center),
          ],
        ),
      );
    }
    return Webview(controller);
  }
}
