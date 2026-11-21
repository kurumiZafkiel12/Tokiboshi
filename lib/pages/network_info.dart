import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/connection_topology.dart';
import '../ui/runtime.dart';
import '../ui/design.dart';

class NetworkInfo extends StatefulWidget {
  const NetworkInfo(
      {super.key,
      required this.monitor,
      required this.latency,
      required this.refresh});
  final RuntimeMonitor monitor;
  final List<(String, int?)> latency;
  final Future<void> Function() refresh;

  @override
  State<NetworkInfo> createState() => _NetworkInfoState();
}

class _NetworkInfoState extends State<NetworkInfo> {
  bool byIp = false, busy = false;
  static const colors = [
    Color(0xffb43c62),
    Color(0xff6d55ad),
    Color(0xff326997),
    Color(0xff96502d)
  ];
  static const layerNames = ['代理组', '出站节点', '匹配规则'];

  // 上一帧的节点聚合流量，用于差分出实时速率（1s 采样）。
  final _prevTotals = <TopologyKey, (int, int)>{};
  DateTime? _prevAt;
  final _rates = <TopologyKey, (double, double)>{};

  // IP 归属缓存（含失败标记 ''）；仅对公网来源 IP 在线查询一次。
  final _ipOwners = <String, String>{};

  void details(BuildContext context, String label, TopologyStats stats) =>
      showDialog<void>(
          context: context,
          builder: (dialog) => AlertDialog(
                title: Text(label),
                content: SingleChildScrollView(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                      SelectableText(
                          '${stats.count} 条连接\n上传 ${bytesLabel(stats.upload)}\n下载 ${bytesLabel(stats.download)}\n\n命中规则\n${stats.rules.join('\n')}'),
                      if (stats.destinations.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text('目标（去重前 ${stats.destinations.length} 个）',
                            style: Theme.of(context).textTheme.bodySmall),
                        SelectableText(stats.destinations.join('\n')),
                      ],
                      if (_looksLikeIp(label)) ...[
                        const SizedBox(height: 10),
                        FutureBuilder<String>(
                            future: _ownerFor(label),
                            builder: (_, snap) => Text(
                                snap.data ?? 'IP 归属查询中…',
                                style:
                                    Theme.of(context).textTheme.bodySmall)),
                      ],
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog),
                      child: const Text('关闭'))
                ],
              ));

  bool _looksLikeIp(String label) {
    final ip = label.split(':').first;
    return InternetAddress.tryParse(ip) != null;
  }

  String _classifyLocal(String ip) {
    final addr = InternetAddress.tryParse(ip);
    if (addr == null) return '';
    if (addr.isLoopback) return '回环地址（本机内部流量）';
    if (addr.isLinkLocal) return '链路本地地址（无公网归属）';
    final v4 = addr.type == InternetAddressType.IPv4
        ? addr.address.split('.').map(int.parse).toList()
        : null;
    if (v4 != null &&
        (v4[0] == 10 ||
            (v4[0] == 172 && v4[1] >= 16 && v4[1] <= 31) ||
            (v4[0] == 192 && v4[1] == 168))) {
      return '私有网络（LAN/TUN 内来源，无公网 ASN）';
    }
    if (addr.type == InternetAddressType.IPv6) {
      final parts = addr.address.split(':').first.toLowerCase();
      if (parts.startsWith('fc') || parts.startsWith('fd')) {
        return 'IPv6 ULA 私有网络';
      }
    }
    return '';
  }

  /// 来源 IP 归属：私网直接判定；公网走 ip-api 免费接口（直连、明文 http、
  /// 结果与失败都缓存，避免打爆每分钟配额）。sing-box 的 connections
  /// 元数据不含 ASN，这是无依赖下的最轻归属方案。
  Future<String> _ownerFor(String label) async {
    final cached = _ipOwners[label];
    if (cached != null) return cached;
    final ip = label.split(':').first;
    final local = _classifyLocal(ip);
    if (local.isNotEmpty) {
      return _ipOwners[label] = local;
    }
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
      final req = await client.getUrl(Uri.parse(
          'http://ip-api.com/json/$ip?fields=as,isp,country,city&lang=zh-CN'))
        ..followRedirects = false;
      final resp = await req.close().timeout(const Duration(seconds: 5));
      final body = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      final v = body.isNotEmpty ? jsonDecode(body) as Map : null;
      final asField = (v?['as'] ?? '') as String;
      final isp = (v?['isp'] ?? '') as String;
      final place = [
        (v?['country'] ?? '') as String,
        (v?['city'] ?? '') as String
      ].where((s) => s.isNotEmpty).join(' · ');
      final verdict = [
        if (asField.isNotEmpty) asField else if (isp.isNotEmpty) isp,
        if (place.isNotEmpty) place,
      ].join(' · ');
      return _ipOwners[label] =
          verdict.isEmpty ? '公网来源，归属查询无结果' : verdict;
    } catch (_) {
      return _ipOwners[label] = '公网来源，归属查询失败（离线或被墙）';
    }
  }

  Widget graph(BuildContext context) {
    final monitor = widget.monitor;
    if (!monitor.available || monitor.connections.isEmpty) {
      return Padding(
          padding: const EdgeInsets.all(18),
          child: Text(monitor.error == null
              ? '暂无活动连接。通过代理访问网络后，链路会出现在这里。'
              : '暂时无法读取连接，正在重试。'));
    }
    final topology = ConnectionTopology(monitor.connections, byIp: byIp);
    // 实时速率：与上一帧（约 1s 前）差分。首帧不计。
    final now = DateTime.now();
    _rates.clear();
    if (_prevAt != null) {
      final secs =
          now.difference(_prevAt!).inMilliseconds / 1000;
      if (secs > 0.2) {
        for (final e in topology.nodes.entries) {
          final prev = _prevTotals[e.key];
          if (prev != null) {
            _rates[e.key] = (
              math.max(0, e.value.upload - prev.$1) / secs,
              math.max(0, e.value.download - prev.$2) / secs,
            );
          }
        }
      }
    }
    _prevTotals
      ..clear()
      ..addEntries(topology.nodes.entries
          .map((e) => MapEntry(e.key, (e.value.upload, e.value.download))));
    _prevAt = now;
    final columns = List.generate(
        4,
        (layer) => topology.nodes.keys.where((key) => key.$1 == layer).toList()
          ..sort((a, b) => a.$2.compareTo(b.$2)));
    final height =
        columns.fold(0, (max, next) => next.length > max ? next.length : max) *
            47.0;
    return LayoutBuilder(builder: (_, constraints) {
      final width = constraints.maxWidth < 640 ? 640.0 : constraints.maxWidth;
      final columnWidth = width / 4;
      final positions = <TopologyKey, Offset>{};
      for (final column in columns) {
        for (var i = 0; i < column.length; i++) {
          positions[column[i]] =
              Offset(column[i].$1 * columnWidth, i * 47 + 22);
        }
      }
      return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            child: Column(children: [
              Row(children: [
                for (final name in [
                  ...layerNames,
                  byIp ? '来源 IP' : '来源端口'
                ])
                  Expanded(child: Text(name)),
              ]),
              const SizedBox(height: 10),
              SizedBox(
                  height: height,
                  child: Stack(children: [
                    Positioned.fill(
                        child: RepaintBoundary(
                            child: CustomPaint(
                                painter: _Edges(
                      positions,
                      columnWidth,
                      {
                        for (final e in topology.edges.entries)
                          e.key: e.value.count
                      },
                      Theme.of(context).colorScheme.outline,
                    )))),
                    for (final e in positions.entries)
                      Positioned(
                          top: e.value.dy - 21,
                          left: e.value.dx,
                          width: columnWidth - 28,
                          height: 44,
                          child: FilledButton(
                            key: ValueKey(e.key),
                            style: FilledButton.styleFrom(
                                backgroundColor: colors[e.key.$1],
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 9, vertical: 4)),
                            onPressed: () => details(
                                context, e.key.$2, topology.nodes[e.key]!),
                            child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(children: [
                                    Expanded(
                                        child: Text(e.key.$2,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis)),
                                    const SizedBox(width: 5),
                                    Text('${topology.nodes[e.key]!.count}',
                                        style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600)),
                                  ]),
                                  Text(
                                      _rateLabel(_rates[e.key]),
                                      style: const TextStyle(
                                          fontSize: 10,
                                          color: Colors.white70)),
                                ]),
                          )),
                  ])),
            ]),
          ));
    });
  }

  String _rateLabel((double, double)? rate) {
    if (rate == null) return '— 采集速率中';
    final (up, down) = rate;
    if (up < 1 && down < 1) return '无流量';
    return '↓ ${bytesLabel(down.round())}/s  ↑ ${bytesLabel(up.round())}/s';
  }

  @override
  Widget build(BuildContext context) {
    final rows = [...widget.latency]
      ..sort((a, b) => (a.$2 ?? 1 << 30).compareTo(b.$2 ?? 1 << 30));
    final values = rows.map((row) => row.$2).whereType<int>().toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Card(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        Text('网络信息',
                            style: Theme.of(context).textTheme.titleLarge),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(value: false, label: Text('来源端口')),
                            ButtonSegment(value: true, label: Text('来源 IP')),
                          ],
                          selected: {byIp},
                          onSelectionChanged: (values) => setState(() {
                            byIp = values.single;
                            _prevTotals.clear();
                            _prevAt = null;
                          }),
                        ),
                      ]),
                  const SizedBox(height: 14),
                  ListenableBuilder(
                      listenable: widget.monitor,
                      builder: (context, _) => graph(context)),
                ],
              ))),
      Card(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(children: [
                    const Expanded(child: Text('网络延迟')),
                    if (values.isNotEmpty)
                      Chip(
                          label: Text(
                              '平均 ${(values.reduce((a, b) => a + b) / values.length).toStringAsFixed(1)} ms'),
                          side: const BorderSide(color: Colors.green)),
                    IconButton(
                        tooltip: '刷新延迟',
                        icon: const Icon(Icons.refresh),
                        onPressed: busy
                            ? null
                            : () async {
                                setState(() => busy = true);
                                try {
                                  await widget.refresh();
                                } finally {
                                  if (mounted) setState(() => busy = false);
                                }
                              }),
                  ]),
                  if (busy) const LinearProgressIndicator(),
                  if (rows.isEmpty) const Text('点刷新测量当前配置的节点延迟。'),
                  for (final (name, delay) in rows)
                    ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(name),
                        subtitle: LinearProgressIndicator(
                            color: delay == null ? Colors.grey : Colors.green,
                            value: delay == null
                                ? 1
                                : (1 - delay / 1500)
                                    .clamp(.05, 1.0)
                                    .toDouble()),
                        trailing: Text(delay == null ? '超时' : '$delay ms',
                            style: TextStyle(
                                color: delay == null ? Colors.grey : null))),
                ],
              ))),
    ]);
  }
}

class _Edges extends CustomPainter {
  _Edges(this.positions, this.columnWidth, this.counts, this.color);
  final Map<TopologyKey, Offset> positions;
  final Map<TopologyEdge, int> counts;
  final double columnWidth;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    for (final e in counts.entries) {
      final from = positions[e.key.$1]! + Offset(columnWidth - 28, 0);
      final to = positions[e.key.$2]!;
      final mid = (from.dx + to.dx) / 2;
      final path = Path()
        ..moveTo(from.dx, from.dy)
        ..cubicTo(mid, from.dy, mid, to.dy, to.dx, to.dy);
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = color.withValues(alpha: .6)
            ..strokeWidth = e.value.clamp(1, 7).toDouble());
    }
  }

  @override
  bool shouldRepaint(covariant _Edges oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.columnWidth != columnWidth ||
      !mapEquals(oldDelegate.positions, positions) ||
      !mapEquals(oldDelegate.counts, counts);
}
