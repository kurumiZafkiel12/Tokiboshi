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

  void details(BuildContext context, String label, TopologyStats stats) =>
      showDialog<void>(
          context: context,
          builder: (dialog) => AlertDialog(
                title: Text(label),
                content: SingleChildScrollView(
                    child: SelectableText(
                        '${stats.count} 条连接\n上传 ${bytesLabel(stats.upload)}\n下载 ${bytesLabel(stats.download)}\n\n命中规则\n${stats.rules.join('\n')}')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog),
                      child: const Text('关闭'))
                ],
              ));

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
    final columns = List.generate(
        4,
        (layer) => topology.nodes.keys.where((key) => key.$1 == layer).toList()
          ..sort((a, b) => a.$2.compareTo(b.$2)));
    final height =
        columns.fold(0, (max, next) => next.length > max ? next.length : max) *
            33.0;
    return LayoutBuilder(builder: (_, constraints) {
      final width = constraints.maxWidth < 640 ? 640.0 : constraints.maxWidth;
      final columnWidth = width / 4;
      final positions = <TopologyKey, Offset>{};
      for (final column in columns) {
        for (var i = 0; i < column.length; i++) {
          positions[column[i]] =
              Offset(column[i].$1 * columnWidth, i * 33 + 15);
        }
      }
      return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            child: Column(children: [
              Row(children: [
                for (final name in [
                  '代理组',
                  '出站节点',
                  '匹配规则',
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
                          top: e.value.dy - 15,
                          left: e.value.dx,
                          width: columnWidth - 28,
                          height: 30,
                          child: FilledButton(
                            key: ValueKey(e.key),
                            style: FilledButton.styleFrom(
                                backgroundColor: colors[e.key.$1],
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 9)),
                            onPressed: () => details(
                                context, e.key.$2, topology.nodes[e.key]!),
                            child: Row(children: [
                              Expanded(
                                  child: Text(e.key.$2,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis)),
                              const SizedBox(width: 5),
                              Text('${topology.nodes[e.key]!.count}'),
                            ]),
                          )),
                  ])),
            ]),
          ));
    });
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
                          onSelectionChanged: (values) =>
                              setState(() => byIp = values.single),
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
