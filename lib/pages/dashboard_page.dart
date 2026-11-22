import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../bridge/core_bridge.dart';
import '../services/store.dart';
import '../ui/design.dart';
import '../ui/preferences.dart';
import '../ui/runtime.dart';
import '../ui/motion.dart';
import '../ui/traffic_chart.dart';
import '../ui/mechanical_clock.dart';
import '../ui/node_widgets.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage(
      {super.key,
      required this.running,
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
      this.subscriptions = const [],
      this.monitor,
      this.onSubscriptions,
      this.onLogs,
      this.onUpdate,
      this.failure,
      this.activeProfileId,
      this.onActivateProfile,
      this.profileBusy = false});
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
    return ListenableBuilder(
      listenable: monitor ?? const AlwaysStoppedAnimation(0),
      builder: (context, _) => LayoutBuilder(builder: (context, bounds) {
        final ui = UiScope.of(context);
        final wide = bounds.maxWidth >= 980 &&
            MediaQuery.textScalerOf(context).scale(14) <= 17;
        final modules = <String, Widget>{
          'traffic': _traffic(context),
          'profile': _profile(context),
          'runtime': _runtime(context),
        };
        final order = [
          for (final key in ui.order)
            if (modules.containsKey(key)) key,
        ];
        final details = [
          for (final key in order)
            Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: MotionEntrance(
                    key: ValueKey(key),
                    order: order.indexOf(key),
                    child: _editable(key, modules[key]!))),
        ];
        final clock = wide
            ? const MechanicalClock(size: 150, dashboard: true)
            : const MechanicalClock(
                size: 150, initiallyOpen: false, dashboard: true);
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(wide ? 26 : 17, 17, wide ? 26 : 17, 22),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                  child: Text('连接工作台',
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w600))),
              if (_editing)
                TextButton(
                    onPressed: () => UiScope.change(
                        context,
                        ui.copyWith(order: const [
                          'status',
                          'traffic',
                          'profile',
                          'runtime'
                        ])),
                    child: const Text('恢复布局')),
              OutlinedButton(
                  onPressed: () => setState(() => _editing = !_editing),
                  child: Text(_editing ? '完成调整' : '调整组件')),
            ]),
            const SizedBox(height: 12),
            if (wide)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _hero(context)),
                const SizedBox(width: 12),
                SizedBox(width: 226, child: clock),
              ])
            else
              _hero(context),
            const SizedBox(height: 11),
            _metricBand(context),
            const SizedBox(height: 12),
            if (wide)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 5, child: details.first),
                const SizedBox(width: 13),
                Expanded(
                    flex: 4,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: details.skip(1).toList())),
              ])
            else ...[
              ...details,
              clock,
            ],
          ]),
        );
      }),
    );
  }

  Widget _hero(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final error = widget.failure != null && !widget.running && !widget.busy;
    final title = widget.busy
        ? '正在准备代理'
        : widget.running
            ? '内核已运行'
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
                        : '按应用代理设置接入')
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
                    StatusDot('代理状态', color: color),
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
                            : widget.running
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
    return Panel(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        child: LayoutBuilder(builder: (context, bounds) {
          final columns = bounds.maxWidth < 420 ||
                  MediaQuery.textScalerOf(context).scale(14) > 17
              ? 2
              : 4;
          return Wrap(runSpacing: 8, children: [
            for (final (label, value) in metrics)
              SizedBox(
                  width: bounds.maxWidth / columns,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label,
                            style: Theme.of(context).textTheme.labelMedium),
                        Text(value,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                    fontFeatures: mono.fontFeatures,
                                    fontWeight: FontWeight.w600)),
                      ])),
          ]);
        }));
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
        height: 220,
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
    final profiles =
        widget.subscriptions.where((s) => s.profileJson != null).toList();
    final viewed = widget.subscriptions
        .where((s) => s.id == widget.activeProfileId)
        .firstOrNull;
    return SizedBox(
        height: 220,
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
                      Text(
                          viewed?.name ??
                              (widget.activeProfileId == null
                                  ? '请选择规则配置'
                                  : '内置分流模板'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w500)),
                      Text(
                          widget.activeProfileId == null
                              ? '请明确选择一份规则配置'
                              : viewed?.profileJson != null
                                  ? '订阅携带规则 · 运行状态见规则页'
                                  : '使用内置分流模板',
                          style: Theme.of(context).textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis)
                    ])),
                const SizedBox(width: 6),
                Tag(viewed?.profileJson != null ? '完整配置' : '内置模板',
                    color: Theme.of(context).colorScheme.primary)
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Text('切换配置', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(width: 10),
                Expanded(
                    child: SizedBox(
                        height: 34,
                        child: DropdownButtonFormField<String>(
                            key: ValueKey(widget.activeProfileId),
                            initialValue: widget.activeProfileId,
                            isExpanded: true,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(fontSize: 12),
                            decoration: const InputDecoration(
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 5)),
                            hint: const Text('请选择激活配置'),
                            items: [
                              const DropdownMenuItem(
                                  value: '', child: Text('内置分流模板')),
                              for (final s in profiles)
                                DropdownMenuItem(
                                    value: s.id,
                                    child: Text(s.name,
                                        overflow: TextOverflow.ellipsis))
                            ],
                            onChanged: widget.running ||
                                    widget.busy ||
                                    widget.profileBusy
                                ? null
                                : (v) {
                                    if (v != null)
                                      widget.onActivateProfile?.call(v);
                                  })))
              ]),
              const SizedBox(height: 9),
              Wrap(spacing: 8, children: [
                SizedBox(
                    height: 29,
                    child: OutlinedButton.icon(
                        onPressed: widget.busy ||
                                widget.running ||
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

  Widget _runtime(BuildContext context) => SizedBox(
      height: 220,
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
