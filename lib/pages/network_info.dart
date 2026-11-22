import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/connection_topology.dart';
import '../services/asn_lookup.dart';
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
  // Party 式视图：'graph' = 四层链路图；其余为单维度视图。
  String view = 'graph';
  static const viewTabs = [
    ('graph', '链路图'),
    ('group', '代理组'),
    ('node', '出站节点'),
    ('rule', '规则'),
    ('byIp', '来源 IP'),
    ('byPort', '来源端口'),
    ('asn', 'ASN 归属'),
  ];
  static const colors = [
    Color(0xffb43c62),
    Color(0xff6d55ad),
    Color(0xff326997),
    Color(0xff96502d)
  ];
  static const layerNames = ['代理组', '出站节点', '匹配规则'];

  final _sampler = ConnectionRateSampler();
  final _clock = Stopwatch()..start();
  List<Map<String, dynamic>>? _paused;
  Map<String, (double, double)> _frozenRates = {};
  final _origins = <String, List<AsnOrigin>>{};
  final _asnErrors = <String>{};
  bool _asnBusy = false;

  void details(BuildContext context, String label, TopologyStats stats) =>
      showDialog<void>(
          context: context,
          builder: (dialog) => AlertDialog(
                title: Text(label),
                content: SingleChildScrollView(
                    child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                        '${stats.count} 条连接 · ↑ ${bytesLabel(stats.upload)} · ↓ ${bytesLabel(stats.download)}'
                        '\n命中规则\n${stats.rules.join('\n')}'),
                    if (stats.destinations.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      const Text('连接目标'),
                      SelectableText(stats.destinations.join('\n')),
                    ],
                    if (stats.addresses.any(isPublicAsnAddress))
                      TextButton(
                          onPressed: () {
                            Navigator.pop(dialog);
                            setState(() => view = 'asn');
                          },
                          child: const Text('查看公网 ASN')),
                  ],
                )),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog),
                      child: const Text('关闭'))
                ],
              ));

  Future<void> _lookup(List<String> addresses) async {
    final approved = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: const Text('查询公开 ASN 归属'),
              content: Text(
                  '将下列公网 IP 经 HTTPS 提交给 RIPEstat。该查询用于前缀归属分析。\n${addresses.join('、')}'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(dialog, true),
                    child: const Text('查询')),
              ],
            ));
    if (approved != true || !mounted || _asnBusy) return;
    setState(() => _asnBusy = true);
    try {
      for (final ip in addresses) {
        try {
          final result = await lookupAsn(ip);
          if (!mounted) return;
          setState(() {
            if (_origins.length >= 256) _origins.remove(_origins.keys.first);
            _origins[ip] = result;
            _asnErrors.remove(ip);
          });
        } catch (_) {
          if (!mounted) return;
          setState(() {
            if (_asnErrors.length >= 256) _asnErrors.remove(_asnErrors.first);
            _asnErrors.add(ip);
          });
        }
      }
    } finally {
      if (mounted) setState(() => _asnBusy = false);
    }
  }

  Widget _asnView(List<Map<String, dynamic>> rows) {
    final counts = <String, int>{};
    for (final row in rows) {
      final meta = row['metadata'];
      if (meta is! Map) continue;
      final candidates = {meta['sourceIP'], meta['destinationIP']}
          .whereType<String>()
          .where(isPublicAsnAddress);
      for (final ip in candidates) {
        counts.update(ip, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    final keys = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    final visible = keys.take(24).toList();
    final unresolved =
        visible.where((ip) => !_origins.containsKey(ip)).take(8).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('公网来源 / 目标 IP 的 BGP 起源 ASN · RIPEstat'),
      if (unresolved.isNotEmpty)
        OutlinedButton.icon(
            onPressed: _asnBusy ? null : () => _lookup(unresolved),
            icon: const Icon(Icons.travel_explore),
            label:
                Text(_asnBusy ? '查询中…' : '查询前 ${unresolved.length} 个未知公网 IP')),
      if (visible.isEmpty) const Text('当前活动连接无公开的来源或目标 IP。'),
      if (keys.length > visible.length)
        Text('按连接数显示前 ${visible.length} 个地址，共 ${keys.length} 个。'),
      for (final ip in visible)
        ListTile(
            contentPadding: EdgeInsets.zero,
            title: SelectableText(ip),
            subtitle: Text(_origins[ip]
                        ?.map((item) => 'AS${item.$1}  ${item.$2}')
                        .join(' / ')
                        .isNotEmpty ==
                    true
                ? _origins[ip]!
                    .map((item) => 'AS${item.$1}  ${item.$2}')
                    .join(' / ')
                : _origins.containsKey(ip)
                    ? '没有公开起源 ASN'
                    : _asnErrors.contains(ip)
                        ? '查询失败，可重试'
                        : '尚未查询'),
            trailing: Text('${counts[ip]} 条连接')),
    ]);
  }

  Widget graph(BuildContext context) {
    final monitor = widget.monitor;
    final rows = _paused ?? monitor.connections;
    if (_paused == null && !monitor.available) _sampler.reset();
    if (view == 'asn') return _asnView(rows);
    if ((_paused == null && !monitor.available) || rows.isEmpty) {
      return Padding(
          padding: const EdgeInsets.all(18),
          child: Text(monitor.error == null ? '暂无活动连接。' : '暂时无法读取连接，正在重试。'));
    }
    final topology = ConnectionTopology(rows,
        byIp: view == 'byIp' || (view == 'graph' && byIp),
        deltas: _paused == null
            ? _sampler.update(rows, _clock.elapsed)
            : _frozenRates);
    final rates = topology.rates;
    final columns = List.generate(
        4,
        (layer) => topology.nodes.keys.where((key) => key.$1 == layer).toList()
          ..sort((a, b) => a.$2.compareTo(b.$2)));
    final height =
        columns.fold(0, (max, next) => next.length > max ? next.length : max) *
            47.0;
    // Party 式单维度视图：按当前 tab 只列出该层的节点（按连接数排序）。
    if (view != 'graph') {
      final layer = switch (view) {
        'group' => 0,
        'node' => 1,
        'rule' => 2,
        _ => 3,
      };
      final keys = topology.nodes.keys.where((key) => key.$1 == layer).toList()
        ..sort((a, b) =>
            topology.nodes[b]!.count.compareTo(topology.nodes[a]!.count));
      return Column(children: [
        for (final key in keys)
          Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                      onTap: () =>
                          details(context, key.$2, topology.nodes[key]!),
                      title: Text(key.$2,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                          '${topology.nodes[key]!.count} 条连接'
                          '${rates[key] == null ? '' : ' · ${_rateLabel(rates[key])}'}',
                          style: const TextStyle(fontSize: 11)),
                      trailing: Text(bytesLabel(topology.nodes[key]!.download),
                          style: const TextStyle(fontSize: 12))))),
      ]);
    }
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
                for (final name in [...layerNames, byIp ? '来源 IP' : '来源端口'])
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
                                  Text(_rateLabel(rates[e.key]),
                                      style: const TextStyle(
                                          fontSize: 10, color: Colors.white70)),
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
                        Wrap(spacing: 6, children: [
                          OutlinedButton.icon(
                              onPressed: () => setState(() {
                                    if (_paused == null) {
                                      _paused = widget.monitor.connections;
                                      _frozenRates = _sampler.update(
                                          _paused!, _clock.elapsed);
                                    } else {
                                      _paused = null;
                                      _sampler.reset();
                                    }
                                  }),
                              icon: Icon(_paused == null
                                  ? Icons.pause
                                  : Icons.play_arrow),
                              label: Text(_paused == null ? '暂停快照' : '恢复实时')),
                          for (final (mode, label) in viewTabs)
                            ChoiceChip(
                                label: Text(label),
                                selected: view == mode,
                                onSelected: (_) => setState(() {
                                      view = mode;
                                      if (mode == 'byIp') byIp = true;
                                      if (mode == 'byPort') byIp = false;
                                    })),
                        ]),
                      ]),
                  if (view == 'graph')
                    Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                            onPressed: () => setState(() => byIp = !byIp),
                            child: Text(
                                byIp ? '按来源 IP · 切换端口' : '按来源端口 · 切换 IP'))),
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
