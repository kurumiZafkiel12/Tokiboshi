import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';

/// The zashboard panel, served by sing-box itself at
/// http://127.0.0.1:<clashApiPort>/ui and embedded in a WebView2
/// view. This is the primary node-switching / connections UI; the
/// native pages only manage subscriptions, settings and the core.
class PanelPage extends StatefulWidget {
  const PanelPage({
    super.key,
    required this.running,
    required this.clashApiPort,
    required this.onStart,
  });

  final bool running;
  final int clashApiPort;
  final VoidCallback onStart;

  @override
  State<PanelPage> createState() => _PanelPageState();
}

class _PanelPageState extends State<PanelPage> {
  WebviewController? _controller;
  String? _error;
  bool _loading = false;

  String get _url => 'http://127.0.0.1:${widget.clashApiPort}/ui';

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
    }
  }

  Future<void> _initWebView() async {
    if (!Platform.isWindows) {
      setState(() => _error = '内嵌面板仅支持 Windows 桌面');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final controller = WebviewController();
      await controller.initialize();
      await controller.setBackgroundColor(Colors.transparent);
      await controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await controller.loadUrl(_url);
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'WebView 初始化失败（需要 WebView2 运行时）：$e';
          _loading = false;
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
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Text('可手动在浏览器打开：$_url'),
            ],
          ),
        ),
      );
    }
    final controller = _controller;
    if (_loading || controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Webview(controller);
  }
}
