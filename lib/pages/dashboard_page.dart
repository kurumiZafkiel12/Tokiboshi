import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../bridge/core_bridge.dart';
import '../services/store.dart';
import '../ui/design.dart';
import '../ui/preferences.dart';
import '../ui/runtime.dart';
import '../ui/traffic_chart.dart';
import '../ui/mechanical_clock.dart';
import '../ui/node_widgets.dart';
import 'node_quality_panel.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage(
      {super.key,
      required this.running,
      this.proxyActive,
      required this.busy,
      required this.selected,
      required this.nodeCount,
      required this.subscriptionCount,
      required this.mixedPort,
      required this.systemProxy,
      required this.selectedLatency,
      required this.selectedMeasured,
      required this.onToggle,
      required this.onMeasureSelected,
      this.coreVersion,
      this.restartCount = 0,
      this.lastExit,
      this.clashMode,
      this.onRestart,
      this.onPickNode,
      this.onCancelConnect,
      this.controlsBlocked = false,
      this.onOpenPanel,
      this.tun = false,
      this.onTunChanged,
      this.onSystemProxyChanged,
      this.onModeChanged,
      this.onQualitySample,
      this.onConnections,
      this.subscriptions = const [],
      this.monitor,
      this.onSubscriptions,
      this.onLogs,
      this.onUpdate,
      this.failure,
      this.activeProfileId,
      this.onActivateProfile,
      this.profileBusy = false});
  final bool? proxyActive;
  final bool running, busy, systemProxy, selectedMeasured, tun;
  final NodeInfo? selected;
  final int nodeCount, subscriptionCount, mixedPort, restartCount;
  final int? selectedLatency;
  final String? coreVersion, lastExit, clashMode, failure;
  final VoidCallback onToggle, onMeasureSelected;
  final VoidCallback? onRestart, onOpenPanel, onSubscriptions, onLogs;
  final VoidCallback? onPickNode, onCancelConnect;
  final bool controlsBlocked;
  final ValueChanged<Subscription>? onUpdate;
  final ValueChanged<bool>? onTunChanged, onSystemProxyChanged;
  final ValueChanged<String>? onModeChanged;
  final Future<int?> Function(NodeInfo)? onQualitySample;
  final VoidCallback? onConnections;
  final List<Subscription> subscriptions;
  final RuntimeMonitor? monitor;
  final String? activeProfileId;
  final bool profileBusy;
  final ValueChanged<String>? onActivateProfile;
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  bool _editing = false;
  void _move(String key, int direction) {
    final ui = UiScope.of(context),
        order = List<String>.of(UiScope.of(context).order);
    final from = order.indexOf(key), to = from + direction;
    if (from < 1 || to < 1 || to >= order.length) return;
    order[from] = order[to];
    order[to] = key;
    UiScope.change(context, ui.copyWith(order: order));
  }

  void _drop(String from, String to) {
    if (from == to || from == 'status' || to == 'status') return;
    final ui = UiScope.of(context),
        order = List<String>.of(UiScope.of(context).order);
    final target = order.indexOf(to);
    order.remove(from);
    order.insert(target, from);
    UiScope.change(context, ui.copyWith(order: order));
  }

  @override
  Widget build(BuildContext context) {
    final monitor = widget.monitor;
    return LayoutBuilder(builder: (context, bounds) {
      final ui = UiScope.of(context);
      final wide = bounds.maxWidth >= 790 &&
          MediaQuery.textScalerOf(context).scale(14) <= 17;
      final gutter = bounds.maxWidth < 600 ? 12.0 : 16.0;
      final header = Row(children: [
        Expanded(
          child:
              Text('连接工作台', style: Theme.of(context).textTheme.headlineSmall),
        ),
        if (_editing)
          TextButton(
            onPressed: () => UiScope.change(
                context,
                ui.copyWith(
                    order: const ['status', 'traffic', 'profile', 'runtime'])),
            child: const Text('恢复布局'),
          ),
        OutlinedButton(
          onPressed: () => setState(() => _editing = !_editing),
          child: Text(_editing ? '完成调整' : '调整组件'),
        ),
      ]);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 8),
          child: header,
        ),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            key: const PageStorageKey('dashboard-scroll'),
            padding: EdgeInsets.all(gutter),
            child: ListenableBuilder(
              listenable: monitor ?? const AlwaysStoppedAnimation(0),
              builder: (context, _) {
                final modules = <String, Widget>{
                  'traffic': _traffic(context),
                  'profile': _profile(context),
                  'runtime': _runtime(context),
                };
                final order = ui.order.where(modules.containsKey).toList();
                Widget panel(String id) => _editable(id, modules[id]!);
                final contentWidth = bounds.maxWidth - gutter * 2;
                final left = wide
                    ? ((contentWidth - 12) * 7 / 12).floorToDouble()
                    : contentWidth;
                final right = wide ? contentWidth - 12 - left : contentWidth;
                return TweenAnimationBuilder<double>(
                  tween: Tween(end: wide ? 1.0 : 0.0),
                  duration: UiScope.duration(context),
                  curve: Curves.easeOutCubic,
                  builder: (context, transition, child) => Transform.translate(
                    offset: Offset(0, math.sin(transition * math.pi) * 5),
                    child: child,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _hero(context),
                      const SizedBox(height: 12),
                      _metricBand(context),
                      const SizedBox(height: 12),
                      Wrap(spacing: 12, runSpacing: 12, children: [
                        SizedBox(
                            key: ValueKey(order.first),
                            width: left,
                            child: panel(order.first)),
                        SizedBox(
                            key: const ValueKey('quality'),
                            width: right,
                            child: _quality(context)),
                        SizedBox(
                            key: const ValueKey('ranking'),
                            width: left,
                            child: _ranking(context)),
                        SizedBox(
                            key: const ValueKey('mechanical-clock'),
                            width: right,
                            child: const MechanicalClock(
                                size: 94, dashboard: true)),
                        SizedBox(
                            key: ValueKey(order[1]),
                            width: left,
                            child: panel(order[1])),
                        SizedBox(
                            key: ValueKey(order[2]),
                            width: right,
                            child: panel(order[2])),
                      ]),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ]);
    });
  }

  Widget _quality(BuildContext context) {
    final node = widget.selected;
    final sample = widget.onQualitySample;
    final checked = widget.selectedMeasured;
    return SizedBox(
        height: 200,
        child: Panel(
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _title(
                '出口质量',
                _link(
                    '测量 ↗',
                    node != null && sample != null && widget.running
                        ? () => showDialog<void>(
                              context: context,
                              builder: (dialogContext) => AlertDialog(
                                title: const Text('出口质量'),
                                content: SizedBox(
                                    width: 550,
                                    child: SingleChildScrollView(
                                        child: NodeQualityPanel(
                                            node: node, measure: sample))),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext),
                                      child: const Text('关闭'))
                                ],
                              ),
                            )
                        : null)),
            if (node != null)
              Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            const Spacer(),
            Text(
              widget.selectedLatency != null
                  ? '${widget.selectedLatency} ms'
                  : checked
                      ? '测量失败'
                      : '尚未测量',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontFamily: mono.fontFamily,
                  fontFamilyFallback: mono.fontFamilyFallback),
            ),
            const SizedBox(height: 4),
            Text('多次测量可查看延迟、抖动和超时。',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        )));
  }

  Widget _ranking(BuildContext context) {
    final totals = <String, int>{};
    for (final row
        in widget.monitor?.connections ?? const <Map<String, dynamic>>[]) {
      final meta = row['metadata'];
      if (meta is! Map) continue;
      final path = meta['processName'] ??
          meta['processPath'] ??
          meta['process_path'] ??
          meta['process'];
      if (path is! String || path.trim().isEmpty) continue;
      final name = path.split(RegExp(r'[/\\]')).last;
      final bytes =
          ((row['download'] as num?) ?? 0) + ((row['upload'] as num?) ?? 0);
      totals.update(name, (current) => current + bytes.toInt(),
          ifAbsent: () => bytes.toInt());
    }
    final ranked = totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 168),
        child: Panel(
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _title('应用流量', _link('连接 ↗', widget.onConnections)),
            if (ranked.isEmpty)
              Text('暂无可识别进程的活动连接', style: Theme.of(context).textTheme.bodySmall)
            else
              for (final app in ranked.take(3))
                Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(children: [
                      Expanded(
                          flex: 3,
                          child: Text(app.key,
                              maxLines: 1, overflow: TextOverflow.ellipsis)),
                      const SizedBox(width: 8),
                      Expanded(
                          flex: 5,
                          child: LinearProgressIndicator(
                            value: ranked.first.value > 0
                                ? app.value / ranked.first.value
                                : 0,
                            minHeight: 4,
                            borderRadius: BorderRadius.circular(2),
                          )),
                      const SizedBox(width: 8),
                      Text(bytesLabel(app.value), style: mono),
                    ])),
          ],
        )));
  }

  Widget _hero(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final error = widget.failure != null && !widget.running && !widget.busy;
    final title = widget.busy
        ? '正在准备代理'
        : widget.running
            ? ((widget.proxyActive ?? widget.running) ? '代理接管中' : '内核待命')
            : error
                ? '连接失败'
                : '代理已停止';
    final hint = widget.busy
        ? '准备配置与本地控制器'
        : error
            ? widget.failure!
            : widget.running
                ? (widget.tun
                    ? 'TUN 网卡已启用'
                    : widget.systemProxy
                        ? '系统代理已启用'
                        : '开启代理前，系统流量照常连接')
                : widget.selected == null
                    ? '导入订阅后选择出口'
                    : '当前出口已保留';
    final color = error
        ? colors.error
        : widget.running
            ? good
            : colors.onSurfaceVariant;
    final node = widget.selected;
    return CustomPaint(
        foregroundPainter: _GlassRim(colors.primary.withValues(alpha: .11)),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(23),
              border: Border.all(color: colors.primary.withValues(alpha: .32)),
              gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.alphaBlend(
                        colors.primary.withValues(alpha: .13), colors.surface),
                    colors.surface,
                    Color.alphaBlend(
                        colors.primary.withValues(alpha: .09), colors.surface)
                  ])),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            LayoutBuilder(builder: (context, bounds) {
              final status = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(spacing: 10, runSpacing: 5, children: [
                      StatusDot(widget.running ? '内核已就绪' : '内核未就绪',
                          color: color),
                      StatusDot(
                          (widget.proxyActive ?? widget.running)
                              ? '代理已开启'
                              : '代理已关闭',
                          color: (widget.proxyActive ?? widget.running)
                              ? good
                              : colors.onSurfaceVariant),
                    ]),
                    const SizedBox(height: 4),
                    Text(title,
                        style: Theme.of(context).textTheme.headlineSmall),
                    Text(hint,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 9),
                    FilledButton(
                        onPressed: widget.controlsBlocked
                            ? null
                            : widget.busy
                                ? widget.onCancelConnect
                                : widget.onToggle,
                        child: Text(widget.busy
                            ? '取消连接'
                            : (widget.proxyActive ?? widget.running)
                                ? '停止代理'
                                : '启动代理')),
                  ]);
              final outlet = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('当前出口',
                        style: Theme.of(context).textTheme.labelMedium),
                    const SizedBox(height: 4),
                    Row(children: [
                      if (node != null) ...[
                        RegionMark(node),
                        const SizedBox(width: 7)
                      ],
                      Expanded(
                          child: InkWell(
                              onTap: widget.controlsBlocked
                                  ? null
                                  : widget.onPickNode,
                              child: Text(node?.name ?? '未选择节点',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium))),
                    ]),
                    if (node != null)
                      Text(sourceLabel(node, widget.subscriptions),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall),
                    Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (widget.onPickNode != null)
                            TextButton(
                                onPressed: widget.controlsBlocked
                                    ? null
                                    : widget.onPickNode,
                                child: const Text('选择节点')),
                          if (node != null)
                            TextButton(
                                onPressed: widget.busy
                                    ? null
                                    : widget.onMeasureSelected,
                                child: Text(widget.selectedLatency == null
                                    ? widget.selectedMeasured
                                        ? '测速超时 · 重测'
                                        : '测量延迟'
                                    : '${widget.selectedLatency} ms · 重测')),
                        ]),
                  ]);
              if (bounds.maxWidth < 450 ||
                  MediaQuery.textScalerOf(context).scale(14) > 17) {
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [status, const Divider(height: 18), outlet]);
              }
              return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: status),
                    const SizedBox(width: 22),
                    Expanded(child: outlet),
                  ]);
            }),
            const Divider(height: 14),
            _controls(context),
          ]),
        ));
  }

  Widget _metricBand(BuildContext context) {
    final monitor = widget.monitor;
    final ready = widget.running && monitor?.available == true;
    final metrics = [
      ('↓ 下载', ready ? '${bytesLabel(monitor!.downSpeed)}/s' : '—'),
      ('↑ 上传', ready ? '${bytesLabel(monitor!.upSpeed)}/s' : '—'),
      ('活动连接', ready ? '${monitor!.connections.length} 条' : '—'),
      ('会话用量', ready ? bytesLabel(monitor!.download + monitor.upload) : '—'),
    ];
    return LayoutBuilder(builder: (context, bounds) {
      final columns = bounds.maxWidth < 560 ||
              MediaQuery.textScalerOf(context).scale(14) > 17
          ? 2
          : 4;
      const gap = 8.0;
      final width = (bounds.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(spacing: gap, runSpacing: gap, children: [
        for (final (label, value) in metrics)
          SizedBox(
              width: width,
              child: Panel(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium),
                    Text(value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(
                                fontFamily: mono.fontFamily,
                                fontFamilyFallback: mono.fontFamilyFallback,
                                fontWeight: FontWeight.w600)),
                  ],
                ),
              )),
      ]);
    });
  }

  Widget _editable(String id, Widget panel) {
    final movable = _editing && id != 'status';
    final body = Stack(children: [
      panel,
      if (movable)
        Positioned(
            right: 6,
            bottom: 5,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                  tooltip: '向前移动$id组件',
                  onPressed: UiScope.of(context).order.indexOf(id) > 1
                      ? () => _move(id, -1)
                      : null,
                  icon: const Icon(Icons.arrow_back, size: 16)),
              IconButton(
                  tooltip: '向后移动$id组件',
                  onPressed: UiScope.of(context).order.last != id
                      ? () => _move(id, 1)
                      : null,
                  icon: const Icon(Icons.arrow_forward, size: 16)),
              const Icon(Icons.drag_indicator, size: 15),
            ]))
    ]);
    return DragTarget<String>(
        onWillAcceptWithDetails: (d) => movable && d.data != id,
        onAcceptWithDetails: (d) => _drop(d.data, id),
        builder: (context, candidates, rejected) => AnimatedContainer(
            key: ValueKey('widget-$id'),
            duration: UiScope.duration(context),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: candidates.isNotEmpty
                        ? Theme.of(context).colorScheme.primary
                        : _editing
                            ? Theme.of(context).dividerColor
                            : Colors.transparent)),
            child: movable
                ? Draggable<String>(
                    data: id,
                    feedback: Material(
                        color: Colors.transparent,
                        child: SizedBox(
                            width: 320,
                            child: Opacity(opacity: .85, child: panel))),
                    childWhenDragging: Opacity(opacity: .3, child: body),
                    child: body)
                : body));
  }

  Widget _title(String text, Widget trailing) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(children: [
        Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600))),
        trailing
      ]));
  Widget _traffic(BuildContext context) {
    final m = widget.monitor, ready = widget.running && (m?.available ?? false);
    return SizedBox(
        height: 200,
        child: Panel(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
              _title(
                  '流量趋势 · 最近 60 次',
                  Tag(
                      !widget.running
                          ? '未连接'
                          : ready
                              ? '实时'
                              : '暂不可用',
                      color: ready ? good : null)),
              Wrap(spacing: 14, children: const [Text('↓ 下载'), Text('↑ 上传')]),
              const SizedBox(height: 10),
              Expanded(
                  child: TrafficReadout(
                      down: m?.downHistory ?? const [],
                      up: m?.upHistory ?? const [])),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                    child: Text('会话下载 ${ready ? bytesLabel(m!.download) : '—'}',
                        style: const TextStyle(fontSize: 10))),
                Text('上传 ${ready ? bytesLabel(m!.upload) : '—'}',
                    style: const TextStyle(fontSize: 10))
              ])
            ])));
  }

  Widget _profile(BuildContext context) {
    final viewed = widget.subscriptions
        .where((s) => s.id == widget.selected?.source)
        .firstOrNull;
    return SizedBox(
        height: 200,
        child: Panel(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
              _title('订阅配置', _link('管理 ↗', widget.onSubscriptions)),
              Row(children: [
                Icon(Icons.inventory_2_outlined, size: 20, color: gold),
                const SizedBox(width: 10),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(viewed?.name ?? '内置分流模板',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w500)),
                      Text('订阅仅提供节点。分流在「分流规则」内管理。',
                          style: Theme.of(context).textTheme.bodySmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                    ])),
                const SizedBox(width: 6),
                Tag('仅节点', color: Theme.of(context).colorScheme.primary)
              ]),
              const SizedBox(height: 9),
              Wrap(spacing: 8, children: [
                SizedBox(
                    height: 29,
                    child: OutlinedButton.icon(
                        onPressed: widget.busy ||
                                (widget.proxyActive ?? widget.running) ||
                                widget.profileBusy ||
                                viewed == null
                            ? null
                            : () => widget.onUpdate?.call(viewed),
                        icon: const Icon(Icons.refresh, size: 14),
                        label: const Text('更新'))),
                SizedBox(
                    height: 29,
                    child: OutlinedButton(
                        onPressed: widget.onSubscriptions,
                        child: const Text('来源详情')))
              ]),
            ])));
  }

  Widget _runtime(BuildContext context) => ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 200),
      child: Panel(
          child: Column(children: [
        _title('运行详情', _link('日志 ↗', widget.onLogs)),
        for (final pair in [
          ('内核', widget.coreVersion ?? '尚未就绪'),
          ('监听地址', '127.0.0.1:${widget.mixedPort}'),
          ('路由', widget.clashMode ?? (widget.running ? '读取中' : '未运行')),
          (
            '接入',
            widget.tun
                ? 'TUN 网卡'
                : widget.systemProxy
                    ? '系统代理'
                    : '手动代理'
          )
        ])
          Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Text(pair.$1, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(width: 12),
                Expanded(
                    child: Text(pair.$2,
                        textAlign: TextAlign.end,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: mono.copyWith(fontSize: 11)))
              ]))
      ])));
  Widget _controls(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final mode = _modePicker(context);
        final toggles = Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('系统代理'),
                Switch(
                    value: widget.systemProxy,
                    onChanged: widget.controlsBlocked
                        ? null
                        : widget.onSystemProxyChanged),
              ]),
              Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('TUN 网卡'),
                Switch(
                    value: widget.tun,
                    onChanged: widget.busy || widget.controlsBlocked
                        ? null
                        : widget.onTunChanged),
              ]),
            ]);
        return constraints.maxWidth >= 565
            ? Row(children: [
                Expanded(child: mode),
                const SizedBox(width: 18),
                toggles
              ])
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [mode, toggles]);
      });
  Widget _modePicker(BuildContext context) => Segments<String>(
      values: const {'Rule': '规则', 'Global': '全局', 'Direct': '直连'},
      value: widget.clashMode ?? 'Rule',
      onChanged: widget.running && !widget.busy ? widget.onModeChanged : null);
  Widget _link(String text, VoidCallback? onTap) => InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: Padding(
          padding: const EdgeInsets.all(3),
          child: Text(text,
              style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant))));
}

class _GlassRim extends CustomPainter {
  const _GlassRim(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 450) return;
    final clip =
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(23));
    canvas.save();
    canvas.clipRRect(clip);
    final paint = Paint()
      ..color = color
      ..strokeWidth = .75
      ..style = PaintingStyle.stroke;
    for (final radius in [49.0, 64.0, 79.0]) {
      canvas.drawOval(
          Rect.fromCenter(
              center: Offset(size.width + 8, 20),
              width: radius * 2,
              height: radius * 2.4),
          paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlassRim oldDelegate) => oldDelegate.color != color;
}

class Segments<T> extends StatelessWidget {
  const Segments(
      {super.key,
      required this.values,
      required this.value,
      required this.onChanged});
  final Map<T, String> values;
  final T value;
  final ValueChanged<T>? onChanged;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
      builder: (context, c) => Container(
          height: 36,
          decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: .3),
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(5)),
          child: Stack(children: [
            AnimatedAlign(
                duration: UiScope.duration(context),
                curve: Curves.easeOutCubic,
                alignment: Alignment(
                    -1 +
                        2 *
                            values.keys.toList().indexOf(value) /
                            math.max(1, values.length - 1),
                    0),
                child: FractionallySizedBox(
                    widthFactor: 1 / values.length,
                    child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: Container(
                            decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withValues(alpha: .13),
                                borderRadius: BorderRadius.circular(3),
                                border: Border.all(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: .35))))))),
            Row(children: [
              for (final entry in values.entries)
                Expanded(
                    child: Semantics(
                        selected: entry.key == value,
                        button: true,
                        child: InkWell(
                            onTap: onChanged == null
                                ? null
                                : () => onChanged!(entry.key),
                            child: Center(
                                child: Text(entry.value,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: onChanged == null
                                            ? Theme.of(context).disabledColor
                                            : null))))))
            ])
          ])));
}
