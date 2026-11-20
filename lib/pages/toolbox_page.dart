import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';

/// 工具箱页（T090 新增）：下载/上传测速。
/// 走 mixed 入站代理，对 Cloudflare Speed 端点测量吞吐；
/// 时长 bounded（下载 10s / 上行 8s），不依赖第三方 SDK。
class ToolboxPage extends StatefulWidget {
  const ToolboxPage({
    super.key,
    required this.running,
    required this.mixedPort,
  });

  final bool running;
  final int mixedPort;

  @override
  State<ToolboxPage> createState() => _ToolboxPageState();
}

class _ToolboxPageState extends State<ToolboxPage> {
  bool _dlBusy = false;
  bool _ulBusy = false;
  double? _downMbps;
  double? _upMbps;
  String? _dlErr;
  String? _ulErr;
  int _dlProgress = 0; // 0-100
  HttpClient? _dlClient;

  static const dlBytes = 100 * 1024 * 1024; // 100 MB 上限
  static const dlSeconds = 10;
  static const upBytes = 8 * 1024 * 1024; // 8 MB 上行载荷

  HttpClient _proxyClient() {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..findProxy = (Uri uri) => 'PROXY 127.0.0.1:${widget.mixedPort}'
      ..autoUncompress = false;
    return c;
  }

  Future<void> _runDownload() async {
    if (_dlBusy) return;
    setState(() {
      _dlBusy = true;
      _dlErr = null;
      _dlProgress = 0;
    });
    final client = _proxyClient();
    final watch = Stopwatch()..start();
    var received = 0;
    try {
      final req = await client.getUrl(Uri.parse(
          'https://speed.cloudflare.com/__down?bytes=$dlBytes'));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      await for (final chunk in resp) {
        received += chunk.length;
        final secs = watch.elapsedMilliseconds / 1000;
        if (mounted) {
          setState(() => _dlProgress =
              (secs / dlSeconds * 100).clamp(0, 99).round());
        }
        if (watch.elapsed >= const Duration(seconds: dlSeconds)) break;
      }
      final secs = watch.elapsedMilliseconds / 1000;
      if (secs > 0.5 && received > 0) {
        final mbps = received * 8 / secs / 1e6;
        if (mounted) setState(() { _downMbps = mbps; _dlProgress = 100; });
      } else {
        if (mounted) setState(() => _dlErr = '样本不足（${received} B）');
      }
    } catch (e) {
      if (mounted) setState(() => _dlErr = '$e');
    } finally {
      client.close(force: true);
      if (mounted) setState(() => _dlBusy = false);
    }
  }

  Future<void> _runUpload() async {
    if (_ulBusy) return;
    setState(() {
      _ulBusy = true;
      _ulErr = null;
    });
    final client = _proxyClient();
    final payload = List.filled(upBytes, 120);
    final watch = Stopwatch()..start();
    try {
      final req = await client.postUrl(Uri.parse('https://speed.cloudflare.com/__up'));
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/octet-stream');
      final done = req.add(payload);
      await done.timeout(const Duration(seconds: 12));
      final resp = await req.close().timeout(const Duration(seconds: 10));
      await resp.drain<void>();
      final secs = watch.elapsedMilliseconds / 1000;
      if (secs > 0.2) {
        final mbps = upBytes * 8 / secs / 1e6;
        if (mounted) setState(() => _upMbps = mbps);
      }
    } catch (e) {
      if (mounted) setState(() => _ulErr = '$e');
    } finally {
      client.close(force: true);
      if (mounted) setState(() => _ulBusy = false);
    }
  }

  String _fmt(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)}';

  @override
  Widget build(BuildContext context) {
    if (!widget.running) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.construction_outlined, size: 40, color: Colors.grey),
        const SizedBox(height: 10),
        const Text('工具箱需要内核运行（测速走代理隧道）'),
        const SizedBox(height: 10),
        FilledButton(onPressed: () {}, child: const Text('启动内核')),
      ]));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('工具箱', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 14),
        _toolCard(
          icon: Icons.cloud_download_outlined,
          title: '下载测速',
          sub: 'Cloudflare 下载端点 · 经当前出口 · 10 秒采样',
          busy: _dlBusy,
          progress: _dlProgress,
          value: _fmt(_downMbps),
          unit: 'Mbps',
          error: _dlErr,
          onStart: _runDownload,
        ),
        const SizedBox(height: 12),
        _toolCard(
          icon: Icons.cloud_upload_outlined,
          title: '上传测速',
          sub: 'Cloudflare 上传端点 · 8 MB 载荷',
          busy: _ulBusy,
          progress: null,
          value: _fmt(_upMbps),
          unit: 'Mbps',
          error: _ulErr,
          onStart: _runUpload,
        ),
        const SizedBox(height: 14),
        const Text('测速走当前出口：切换节点后重测可对比线路质量。'
            '下载/上传结果仅为采样窗口内的平均吞吐。', style: TextStyle(fontSize: 12, color: Colors.grey)),
      ]),
    );
  }

  Widget _toolCard({
    required IconData icon,
    required String title,
    required String sub,
    required bool busy,
    int? progress,
    required String value,
    required String unit,
    String? error,
    required VoidCallback onStart,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 20, color: Colors.white70),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
            if (busy) const SizedBox(width: 8, height: 8, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          const SizedBox(height: 6),
          Text(sub, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 12),
          Row(children: [
            Text('$value $unit', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
            const Spacer(),
            FilledButton.tonal(onPressed: busy ? null : onStart, child: Text(busy ? '测速中…' : '开始')),
          ]),
          if (progress != null) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress / 100, minHeight: 3),
          ],
          if (error != null) Text(error, style: const TextStyle(fontSize: 12, color: Colors.redAccent)),
        ]),
      ),
    );
  }
}
