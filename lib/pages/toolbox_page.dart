import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../services/network_checks.dart';

/// 工具箱页：下载/上传测速 + 延迟质量 + 目标连通 + 检测与修复。
/// 走 mixed 入站代理，测速多服务可选；不依赖第三方 SDK。
class ToolboxPage extends StatefulWidget {
  const ToolboxPage({
    super.key,
    required this.running,
    required this.mixedPort,
    required this.onStart,
    required this.networkInfo,
    required this.resources,
    this.proxyCredentials,
    this.systemProxy,
  });

  final bool running;
  final int mixedPort;
  final VoidCallback onStart;
  final Widget networkInfo, resources;
  final (String, String)? proxyCredentials;
  final SystemProxy? systemProxy;

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
  String _dlService = 'hetzner';
  String? _dlEndpoint;

  // 检测与修复（Hotaru 移植）：出口对照 + 系统代理残留。
  bool _chkBusy = false;
  ExitIpInfo? _proxiedIp, _directIp;
  InternetAddress? _physicalIp;
  String? _chkErr;
  String? _proxyServer, _autoConfigUrl;
  bool _clearing = false;

  // 延迟质量（对当前出口，10 次 RTT）
  double? _latMin, _latAvg, _latMax, _latJitter;
  // 目标连通（经当前出口的 HTTPS 完成延迟，ms）
  final Map<String, int> _targetMs = {};
  final Map<String, String?> _targetErr = {};

  static const upBytes = 8 * 1024 * 1024; // 8 MB 上行载荷
  static const latencyProbes = 10;

  // speed.cloudflare.com rejects bare-Dart agents with 403;
  // a browser UA is required for the speed endpoints.
  static const speedUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';

  /// 下载测速服务：Cloudflare 对数据中心出口 IP 常见 403（TLS 指纹
  /// 层拦截，换 UA 无效），所以提供多服务并在所选端点失败时自动回退。
  static const dlServices = <String, (String, String)>{
    'hetzner': ('Hetzner 德国', 'https://speed.hetzner.de/100MB.bin'),
    'tele2': ('Tele2 荷兰', 'http://speedtest.tele2.net/100MB.zip'),
    'cloudflare': ('Cloudflare', 'https://speed.cloudflare.com/__down?bytes=104857600'),
  };

  /// 延迟质量探测端点：gstatic 204 无 bot 拦截、全球 anycast。
  static const latencyProbeUrl = 'https://www.gstatic.com/generate_204';

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
      _dlEndpoint = null;
    });
    final client = _proxyClient();
    final watch = Stopwatch()..start();
    var received = 0;
    double? peak;
    Object? lastError;
    final tried = <String>[];
    // 候选：用户所选端点优先，其余按表顺序自动回退（Cloudflare 对
    // 数据中心出口 IP 常见 403——TLS 指纹层拦截，换 UA 无效）。
    final order = [
      _dlService,
      for (final key in dlServices.keys)
        if (key != _dlService) key,
    ];
    HttpClientResponse? resp;
    String used = _dlService;
    for (final key in order) {
      final (name, url) = dlServices[key]!;
      tried.add(name);
      try {
        final req = await client.getUrl(Uri.parse(url));
        req.headers.set(HttpHeaders.userAgentHeader, speedUa);
        final candidate =
            await req.close().timeout(const Duration(seconds: 15));
        if (candidate.statusCode != 200) {
          throw HttpException('HTTP ${candidate.statusCode}');
        }
        resp = candidate;
        used = key;
        break;
      } catch (e) {
        lastError = e;
      }
    }
    try {
      if (resp == null) {
        throw HttpException(
            '全部端点失败（${tried.join('、')}）：${lastError is HttpException ? lastError.message : '$lastError'}');
      }
      if (used != _dlService) {
        setState(() => _dlEndpoint = '${dlServices[used]!.$1}（自动回退）');
      } else {
        setState(() => _dlEndpoint = dlServices[used]!.$1);
      }
      // 时长上限只对 Cloudflare（无限流式）生效；文件型端点（默认）
      // 跑满 100MB 文件，进度按已下载量估算。
      final seconds = used == 'cloudflare' ? _dlSeconds : 0;
      // 瞬时速率：最近 1s 滑窗样本
      final window = <int, int>{}; // elapsedMs -> cumulative bytes
      await for (final chunk in resp.timeout(const Duration(seconds: 15))) {
        received += chunk.length;
        final ms = watch.elapsedMilliseconds;
        window[ms] = received;
        window.removeWhere((k, _) => k < ms - 1000);
        if (window.isNotEmpty) {
          final oldest = window.keys.reduce(math.min);
          final instant =
              (received - (window[oldest] ?? 0)) * 8 / ((ms - oldest) / 1000) / 1e6;
          peak = math.max(peak ?? 0, instant);
          if (mounted) {
            setState(() {
              _dlLive = instant;
              _dlPeak = peak;
              _dlTotal = received;
              _dlProgress = used == 'cloudflare'
                  ? (ms / (seconds * 1000)).clamp(0, 99).round()
                  : (received / (100 * 1024 * 1024) * 100)
                      .clamp(0, 99)
                      .round();
            });
          }
        }
        if (used == 'cloudflare' &&
            watch.elapsed >= Duration(seconds: seconds)) break;
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
      req.headers.set(HttpHeaders.userAgentHeader, speedUa);
      req.headers
          .set(HttpHeaders.contentTypeHeader, 'application/octet-stream');
      req.add(payload);
      await req.flush().timeout(const Duration(seconds: 12));
      final resp = await req.close().timeout(const Duration(seconds: 10));
      if (resp.statusCode == 403) {
        throw HttpException('端点拒绝（403）：该出口 IP 被 Cloudflare 限制（上传端点暂无免费替代），换个节点再试');
      }
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
        final req = await client.getUrl(Uri.parse(latencyProbeUrl));
        req.headers.set(HttpHeaders.userAgentHeader, speedUa);
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
        req.headers.set(HttpHeaders.userAgentHeader, speedUa);
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

  Future<void> _runChecks() async {
    if (_chkBusy) return;
    setState(() {
      _chkBusy = true;
      _chkErr = null;
      _proxiedIp = null;
      _directIp = null;
      _physicalIp = null;
    });
    try {
      final proxied = _proxyClient();
      final direct = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      final results = await Future.wait([
        queryExitIp(proxied),
        queryExitIp(direct),
        probePhysicalIp().then((v) => v as InternetAddress?).catchError((_) => null),
      ]);
      final server = await widget.systemProxy?.readProxyServer();
      final pac = await readAutoConfigUrl();
      if (mounted) {
        setState(() {
          _proxiedIp = results[0] as ExitIpInfo?;
          _directIp = results[1] as ExitIpInfo?;
          _physicalIp = results[2] as InternetAddress?;
          _proxyServer = server;
          _autoConfigUrl = pac;
        });
      }
      proxied.close(force: true);
      direct.close(force: true);
    } catch (e) {
      if (mounted) setState(() => _chkErr = '$e');
    } finally {
      if (mounted) setState(() => _chkBusy = false);
    }
  }

  Future<void> _clearResidual() async {
    setState(() => _clearing = true);
    try {
      final ok = await clearProxyResidual();
      if (mounted) {
        setState(() {
          _proxyServer = ok ? null : _proxyServer;
          _autoConfigUrl = ok ? null : _autoConfigUrl;
        });
        _snackbar(ok ? '残留已清理' : '清理失败：注册表操作被拒绝');
      }
    } catch (e) {
      if (mounted) _snackbar('清理失败：$e');
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  void _snackbar(String message) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
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
          sub:
              '${dlServices[_dlService]!.$1} 下载端点 · 经当前出口 · 失败自动切换服务',
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
        _checksCard(),
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
      child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
        const Text('测速服务', style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(width: 8),
        for (final entry in dlServices.entries)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Text(entry.value.$1),
              selected: _dlService == entry.key,
              onSelected: _dlBusy
                  ? null
                  : (_) => setState(() {
                        _dlService = entry.key;
                        _dlEndpoint = null;
                      }),
            ),
          ),
        const SizedBox(width: 10),
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
        if (_dlEndpoint != null) ...[
          const SizedBox(width: 4),
          Text('端点：$_dlEndpoint',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
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

  Widget _checksCard() {
    final residual = proxyResidual(
        coreRunning: widget.running,
        proxyServer: _proxyServer,
        pac: _autoConfigUrl);
    final proxied = _proxiedIp;
    final physical = _physicalIp;
    final proxiedIp = proxied?.ip ?? '—';
    final physicalIp = physical?.address ?? '—';
    final leaking =
        proxied != null && physical != null && proxied.ip == physical.address;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.health_and_safety_outlined,
                size: 20, color: Colors.white70),
            const SizedBox(width: 10),
            const Expanded(
                child: Text('检测与修复',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600))),
            if (_chkBusy)
              const SizedBox(
                  width: 8,
                  height: 8,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            FilledButton.tonal(
                onPressed: _chkBusy ? null : _runChecks,
                child: Text(_chkBusy ? '检测中…' : '开始检测')),
          ]),
          const SizedBox(height: 6),
          Text(
              '出口对照：经代理查询的出口 IP vs STUN 探测的物理出口。TUN 模式下两者一致属正常（UDP 已被接管）。',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 10),
          if (_chkErr != null)
            Text(_chkErr!,
                style: const TextStyle(fontSize: 12, color: Colors.redAccent))
          else ...[
            Row(children: [
              const SizedBox(
                  width: 96,
                  child: Text('代理出口', style: TextStyle(fontSize: 13))),
              SelectableText(proxiedIp, style: const TextStyle(fontSize: 13)),
              if (proxied?.asn.isNotEmpty == true)
                Expanded(
                    child: Text('  ${proxied.asn} · ${proxied.country}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.grey))),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              const SizedBox(
                  width: 96,
                  child: Text('物理出口', style: TextStyle(fontSize: 13))),
              SelectableText(physicalIp, style: const TextStyle(fontSize: 13)),
              if (physical != null)
                Expanded(
                    child: Text(
                        leaking
                            ? '  ⚠ 与代理出口一致（可能泄漏或 TUN）'
                            : '  与代理不同：代理生效',
                        maxLines: 1,
                        style: TextStyle(
                            fontSize: 11,
                            color: leaking
                                ? Colors.orangeAccent
                                : Colors.green))),
            ]),
          ],
          const Divider(height: 20),
          Row(children: [
            const SizedBox(
                width: 96,
                child: Text('系统代理残留', style: TextStyle(fontSize: 13))),
            Expanded(
              child: Text(
                widget.running
                    ? '内核运行中（退出时会自动清理）'
                    : residual.residual
                        ? '检测到残留：${[
                            if (_proxyServer?.isNotEmpty == true)
                              'ProxyServer=$_proxyServer',
                            if (_autoConfigUrl?.isNotEmpty == true)
                              'PAC=$_autoConfigUrl'
                          ].join('，')}'
                        : (_proxyServer == null && _autoConfigUrl == null
                            ? '未检测（点"开始检测"读取注册表）'
                            : '无残留'),
                style: TextStyle(
                    fontSize: 12,
                    color:
                        residual.residual ? Colors.orangeAccent : Colors.grey),
              ),
            ),
            OutlinedButton(
                onPressed:
                    residual.residual && !_clearing ? _clearResidual : null,
                child: Text(_clearing ? '清理中…' : '清除残留')),
          ]),
        ]),
      ),
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
