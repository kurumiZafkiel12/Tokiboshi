import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';

/// 工具箱页：下载/上传测速 + 延迟质量 + 目标连通。
/// 走 mixed 入站代理，对 Cloudflare Speed 端点测量吞吐；
/// 时长 bounded，不依赖第三方 SDK。
class ToolboxPage extends StatefulWidget {
  const ToolboxPage({
    super.key,
    required this.running,
    required this.mixedPort,
    required this.onStart,
    required this.networkInfo,
    required this.resources,
    this.proxyCredentials,
  });

  final bool running;
  final int mixedPort;
  final VoidCallback onStart;
  final Widget networkInfo, resources;
  final (String, String)? proxyCredentials;

  @override
  State<ToolboxPage> createState() => _ToolboxPageState();
}

class _ToolboxPageState extends State<ToolboxPage> {
  bool _dlBusy = false;
  bool _ulBusy = false;
  bool _latBusy = false;
  bool _tgtBusy = false;
  double? _downMbps;
  double? _upMbps;
  double? _dlPeak;
  double? _dlLive;
  int _dlTotal = 0;
  int _ulTotal = 0;
  String? _dlErr;
  String? _ulErr;
  String? _latErr;
  int _dlProgress = 0; // 0-100
  int _dlSeconds = 10;

  // 延迟质量（对当前出口，10 次 RTT）
  double? _latMin, _latAvg, _latMax, _latJitter;
  // 目标连通（经当前出口的 HTTPS 完成延迟，ms）
  final Map<String, int> _targetMs = {};
  final Map<String, String?> _targetErr = {};

  static const dlBytes = 100 * 1024 * 1024; // 100 MB 上限
  static const upBytes = 8 * 1024 * 1024; // 8 MB 上行载荷
  static const latencyProbes = 10;

  /// 目标连通清单：名称 → URL。204/trace 类端点轻量；非 2xx 也算连通
  /// （握手完成即计延迟），只把网络层失败算作错误。
  static const targets = <String, String>{
    'Google': 'https://www.google.com/generate_204',
    'GitHub': 'https://github.com/favicon.ico',
    'Cloudflare': 'https://speed.cloudflare.com/__down?bytes=0',
    'OpenAI': 'https://api.openai.com/v1/models',
    'YouTube': 'https://www.youtube.com/favicon.ico',
    'Telegram': 'https://api.telegram.org/',
  };

  HttpClient _proxyClient() {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..findProxy = (Uri uri) {
        return 'PROXY 127.0.0.1:${widget.mixedPort}';
      }
      ..autoUncompress = false;
    final credentials = widget.proxyCredentials;
    if (credentials != null) {
      c.authenticateProxy = (host, port, scheme, realm) async {
        if (host != '127.0.0.1' ||
            port != widget.mixedPort ||
            scheme.toLowerCase() != 'basic') return false;
        c.addProxyCredentials(host, port, realm ?? '',
            HttpClientBasicCredentials(credentials.$1, credentials.$2));
        return true;
      };
    }
    return c;
  }

  Future<void> _runDownload() async {
    if (_dlBusy) return;
    setState(() {
      _dlBusy = true;
      _dlErr = null;
      _dlProgress = 0;
      _dlLive = null;
      _dlPeak = null;
      _dlTotal = 0;
    });
    final client = _proxyClient();
    final watch = Stopwatch()..start();
    var received = 0;
    double? peak;
    try {
      final req = await client.getUrl(
          Uri.parse('https://speed.cloudflare.com/__down?bytes=$dlBytes'));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      // 瞬时速率：最近 1s 滑窗样本
      final window = <int, int>{}; // elapsedMs -> cumulative bytes
      await for (final chunk in resp.timeout(const Duration(seconds: 10))) {
        received += chunk.length;
        final ms = watch.elapsedMilliseconds;
        window[ms] = received;
        // 清理滑窗外样本
        window.removeWhere((k, _) => k < ms - 1000);
        if (window.isNotEmpty) {
          final oldest = (window.keys.reduce(math.min));
          final instant =
              (received - (window[oldest] ?? 0)) * 8 / ((ms - oldest) / 1000) / 1e6;
          peak = math.max(peak ?? 0, instant);
          if (mounted) {
            setState(() {
              _dlLive = instant;
              _dlPeak = peak;
              _dlTotal = received;
              _dlProgress = (ms / (_dlSeconds * 1000)).clamp(0, 99).round();
            });
          }
        }
        if (watch.elapsed >= Duration(seconds: _dlSeconds)) break;
      }
      final secs = watch.elapsedMilliseconds / 1000;
      if (secs > 0.5 && received > 0) {
        final mbps = received * 8 / secs / 1e6;
        if (mounted)
          setState(() {
            _downMbps = mbps;
            _dlProgress = 100;
            _dlTotal = received;
          });
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
      _ulTotal = 0;
    });
    final client = _proxyClient();
    final payload = List.filled(upBytes, 120);
    final watch = Stopwatch()..start();
    try {
      final req =
          await client.postUrl(Uri.parse('https://speed.cloudflare.com/__up'));
      req.headers
          .set(HttpHeaders.contentTypeHeader, 'application/octet-stream');
      req.add(payload);
      await req.flush().timeout(const Duration(seconds: 12));
      final resp = await req.close().timeout(const Duration(seconds: 10));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      await resp.drain<void>().timeout(const Duration(seconds: 10));
      final secs = watch.elapsedMilliseconds / 1000;
      if (secs > 0.2) {
        final mbps = upBytes * 8 / secs / 1e6;
        if (mounted)
          setState(() {
            _upMbps = mbps;
            _ulTotal = upBytes;
          });
      }
    } catch (e) {
      if (mounted) setState(() => _ulErr = '$e');
    } finally {
      client.close(force: true);
      if (mounted) setState(() => _ulBusy = false);
    }
  }

  /// 延迟质量：对当前出口连续 [latencyProbes] 次小请求，
  /// 报告 min/avg/max 与抖动（相邻样本差的均值）。
  Future<void> _runLatencyQuality() async {
    if (_latBusy) return;
    setState(() {
      _latBusy = true;
      _latErr = null;
    });
    final client = _proxyClient();
    final samples = <int>[];
    try {
      for (var i = 0; i < latencyProbes; i++) {
        final watch = Stopwatch()..start();
        final req = await client.getUrl(
            Uri.parse('https://speed.cloudflare.com/__down?bytes=0'));
        final resp = await req.close().timeout(const Duration(seconds: 8));
        await resp.drain<void>();
        samples.add(watch.elapsedMilliseconds);
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      final avg = samples.reduce((a, b) => a + b) / samples.length;
      var jitter = 0.0;
      for (var i = 1; i < samples.length; i++) {
        jitter += (samples[i] - samples[i - 1]).abs();
      }
      jitter = samples.length > 1 ? jitter / (samples.length - 1) : 0.0;
      if (mounted) {
        setState(() {
          _latMin = samples.reduce(math.min).toDouble();
          _latAvg = avg;
          _latMax = samples.reduce(math.max).toDouble();
          _latJitter = jitter;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _latErr = '$e');
    } finally {
      client.close(force: true);
      if (mounted) setState(() => _latBusy = false);
    }
  }

  /// 目标连通：对固定清单逐个测 HTTPS 完成延迟（走当前出口）。
  /// 非 2xx 状态仍算连通（握手完成）；只把超时/网络层错误算失败。
  Future<void> _runTargetChecks() async {
    if (_tgtBusy) return;
    setState(() {
      _tgtBusy = true;
      _targetMs.clear();
      _targetErr.updateAll((_, __) => null);
    });
    for (final entry in targets.entries) {
      final client = _proxyClient();
      try {
        final watch = Stopwatch()..start();
        final req = await client.getUrl(Uri.parse(entry.value));
        req.followRedirects = false;
        final resp = await req.close().timeout(const Duration(seconds: 8));
        await resp.drain<void>().timeout(const Duration(seconds: 5));
        if (mounted) setState(() => _targetMs[entry.key] = watch.elapsedMilliseconds);
      } catch (e) {
        if (mounted) setState(() => _targetErr[entry.key] = '$e');
      } finally {
        client.close(force: true);
      }
    }
    if (mounted) setState(() => _tgtBusy = false);
  }

  String _fmt(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)}';
  String _ms(int? v) => v == null ? '—' : '${v}ms';

  String _bytes(int b) {
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(1)} KB';
    return '$b B';
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.running) {
      return ListView(padding: const EdgeInsets.all(20), children: [
        const Icon(Icons.construction_outlined, size: 40, color: Colors.grey),
        const SizedBox(height: 10),
        const Text('工具箱需要内核运行（测速走代理隧道）'),
        const SizedBox(height: 10),
        FilledButton(onPressed: widget.onStart, child: const Text('启动内核')),
        widget.resources,
      ]);
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('工具箱',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 14),
        _toolCard(
          icon: Icons.cloud_download_outlined,
          title: '下载测速',
          sub: 'Cloudflare 下载端点 · 经当前出口 · $_dlSeconds 秒采样',
          busy: _dlBusy,
          progress: _dlProgress,
          value: _fmt(_dlBusy && _dlLive != null ? _dlLive : _downMbps),
          unit: 'Mbps',
          error: _dlErr,
          detail: _speedDetail(),
          extra: _durationSelector(),
          onStart: _runDownload,
        ),
        const SizedBox(height: 12),
        _toolCard(
          icon: Icons.cloud_upload_outlined,
          title: '上传测速',
          sub: 'Cloudflare 上传端点 · 8 MB 载荷 · 已发送 ${_bytes(_ulTotal)}',
          busy: _ulBusy,
          progress: null,
          value: _fmt(_upMbps),
          unit: 'Mbps',
          error: _ulErr,
          onStart: _runUpload,
        ),
        const SizedBox(height: 12),
        _latencyCard(),
        const SizedBox(height: 12),
        _targetsCard(),
        const SizedBox(height: 14),
        widget.networkInfo,
        widget.resources,
        const Text(
            '测速走当前出口：切换节点后重测可对比线路质量。'
            '下载/上传结果仅为采样窗口内的平均吞吐；目标连通为 HTTPS 完成延迟，受远端负载影响。',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
      ]),
    );
  }

  Widget? _speedDetail() {
    if (_downMbps == null && _dlLive == null) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        '峰值 ${_fmt(_dlPeak)} Mbps · 已下载 ${_bytes(_dlTotal)}',
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      ),
    );
  }

  Widget _durationSelector() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        const Text('采样时长', style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(width: 8),
        for (final s in const [10, 20, 30])
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Text('${s}s'),
              selected: _dlSeconds == s,
              onSelected: _dlBusy
                  ? null
                  : (_) => setState(() => _dlSeconds = s),
            ),
          ),
      ]),
    );
  }

  Widget _latencyCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.speed, size: 20, color: Colors.white70),
            const SizedBox(width: 10),
            const Expanded(
                child: Text('延迟质量',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
            if (_latBusy)
              const SizedBox(
                  width: 8,
                  height: 8,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            FilledButton.tonal(
                onPressed: _latBusy ? null : _runLatencyQuality,
                child: Text(_latBusy ? '测量中…' : '开始')),
          ]),
          const SizedBox(height: 6),
          Text('当前出口 · $latencyProbes 次采样 · 抖动 = 相邻样本差的均值',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 10),
          if (_latErr != null)
            Text(_latErr!, style: const TextStyle(fontSize: 12, color: Colors.redAccent))
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _stat('最小', _ms(_latMin?.round())),
                _stat('平均', _ms(_latAvg?.round())),
                _stat('最大', _ms(_latMax?.round())),
                _stat('抖动', _ms(_latJitter?.round())),
              ],
            ),
        ]),
      ),
    );
  }

  Widget _targetsCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.travel_explore, size: 20, color: Colors.white70),
            const SizedBox(width: 10),
            const Expanded(
                child: Text('目标连通',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
            if (_tgtBusy)
              const SizedBox(
                  width: 8,
                  height: 8,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            FilledButton.tonal(
                onPressed: _tgtBusy ? null : _runTargetChecks,
                child: Text(_tgtBusy ? '检测中…' : '开始')),
          ]),
          const SizedBox(height: 6),
          const Text('常用服务经当前出口的 HTTPS 完成延迟',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 8),
          for (final name in targets.keys)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                SizedBox(
                    width: 110,
                    child: Text(name,
                        style: const TextStyle(fontSize: 13))),
                Expanded(
                  child: LinearProgressIndicator(
                    value: _targetMs[name] == null
                        ? 0
                        : (1 - (_targetMs[name]! / 3000)).clamp(0.0, 1.0),
                    minHeight: 4,
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                    width: 64,
                    child: Text(
                        _targetErr[name] != null
                            ? '失败'
                            : _ms(_targetMs[name]),
                        textAlign: TextAlign.end,
                        style: TextStyle(
                            fontSize: 12,
                            color: _targetErr[name] != null
                                ? Colors.redAccent
                                : Colors.grey))),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Column(children: [
      Text(value,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
    ]);
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
    Widget? detail,
    Widget? extra,
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
            Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600))),
            if (busy)
              const SizedBox(
                  width: 8,
                  height: 8,
                  child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          const SizedBox(height: 6),
          Text(sub, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 12),
          Row(children: [
            Text('$value $unit',
                style:
                    const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
            const Spacer(),
            FilledButton.tonal(
                onPressed: busy ? null : onStart,
                child: Text(busy ? '测速中…' : '开始')),
          ]),
          if (detail != null) detail,
          if (extra != null) extra,
          if (progress != null) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress / 100, minHeight: 3),
          ],
          if (error != null)
            Text(error,
                style: const TextStyle(fontSize: 12, color: Colors.redAccent)),
        ]),
      ),
    );
  }
}
