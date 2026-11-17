import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../bridge/core_bridge.dart';
import '../app_version.dart';
import '../services/store.dart';
import '../ui/design.dart';
import '../ui/preferences.dart';
import '../ui/runtime.dart';
import '../ui/motion.dart';
import '../ui/traffic_chart.dart';

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
        builder: (context, _) => LayoutBuilder(builder: (context, c) {
              final narrow = c.maxWidth < 650;
              final ui = UiScope.of(context);
              final modules = <String, Widget>{
                'status': _status(context),
                'traffic': _traffic(context),
                'profile': _profile(context),
                'runtime': _runtime(context)
              };
              return SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                      narrow ? 16 : 22, 20, narrow ? 16 : 22, 18),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(children: [
                          const Expanded(
                              child: Text('我的工作台',
                                  style: TextStyle(
                                      fontSize: 23,
                                      height: 1.3,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: -.6))),
                          Text('WORKSPACE / $kAppVersion',
                              style: mono.copyWith(
                                  fontSize: 9,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant))
                        ]),
                        const SizedBox(height: 12),
                        Row(children: [
                          Expanded(
                              child: Text('上方查看信息，下方选择连接',
                                  style:
                                      Theme.of(context).textTheme.bodySmall)),
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
                              onPressed: () =>
                                  setState(() => _editing = !_editing),
                              child: Text(_editing ? '完成调整' : '调整组件'))
                        ]),
                        const SizedBox(height: 12),
                        LayoutBuilder(builder: (context, grid) {
                          final width =
                              narrow ? grid.maxWidth : (grid.maxWidth - 14) / 2;
                          final columns = narrow ? 1 : 2;
                          return SizedBox(
                              height: narrow ? 818 : 402,
                              child: Stack(children: [
                                for (final key in ui.order)
                                  AnimatedPositioned(
                                    key: ValueKey('position-$key'),
                                    duration: UiScope.duration(context, 350),
                                    curve: Curves.easeOutCubic,
                                    left: ui.order.indexOf(key) %
                                        columns *
                                        (width + 14),
                                    top: (ui.order.indexOf(key) ~/ columns) *
                                        204.0,
                                    width: width,
                                    height: 194,
                                    child: MotionEntrance(
                                        order: ui.order.indexOf(key),
                                        child: MotionHover(
                                            lift: true,
                                            child:
                                                _editable(key, modules[key]!))),
                                  )
                              ]));
                        }),
                        if (_editing)
                          Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text('拖动组件，或用箭头调整。状态组件固定在左上。',
                                  style:
                                      Theme.of(context).textTheme.bodySmall)),
                        const SizedBox(height: 12),
                        _controls(context),
                      ]));
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
  Widget _status(BuildContext context) {
    final failed = widget.failure != null && !widget.running && !widget.busy;
    final color = failed
        ? Theme.of(context).colorScheme.error
        : widget.running
            ? good
            : Theme.of(context).colorScheme.onSurfaceVariant;
    final duration = widget.monitor?.startedAt == null
        ? null
        : DateTime.now().difference(widget.monitor!.startedAt!);
    final uptime = duration == null
        ? '—'
        : '${duration.inHours.toString().padLeft(2, '0')}:${(duration.inMinutes % 60).toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
    return SizedBox(
        height: 190,
        child: ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: Stack(fit: StackFit.expand, children: [
              Panel(accent: widget.running, child: const SizedBox()),
              Positioned.fill(child: FlowLines(active: widget.running)),
              if (UiScope.of(context).character)
                Positioned(
                    left: 7,
                    top: 7,
                    child: CustomPaint(
                        size: const Size(14, 7),
                        painter: _CornerPainter(gold.withValues(alpha: .4)))),
              Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _title(
                            '连接状态',
                            Text('LOCAL SESSION',
                                style: mono.copyWith(
                                    fontSize: 9,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant))),
                        StatusDot(
                            widget.busy
                                ? (widget.running
                                    ? 'DISCONNECTING'
                                    : 'CONNECTING')
                                : failed
                                    ? 'CONNECTION FAILED'
                                    : widget.running
                                        ? 'CORE RUNNING'
                                        : 'CORE STOPPED',
                            color: color),
                        const SizedBox(height: 5),
                        Text(
                            widget.busy
                                ? (widget.running ? '正在断开' : '正在连接')
                                : failed
                                    ? '连接失败'
                                    : widget.running
                                        ? '已连接'
                                        : '未连接',
                            style: const TextStyle(
                                fontSize: 27,
                                fontWeight: FontWeight.w500,
                                height: 1.25)),
                        const SizedBox(height: 5),
                        Text(
                            widget.busy
                                ? (widget.running
                                    ? '正在停止内核并恢复系统代理。'
                                    : '正在准备内核与配置，请稍候。')
                                : failed
                                    ? '请查看错误详情或日志，再重试连接。'
                                    : widget.selected == null
                                        ? '导入订阅，选择你的第一个出口节点。'
                                        : widget.running
                                            ? 'sing-box 正在处理连接。'
                                            : '节点已选好，可以启动。',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall),
                        const Spacer(),
                        const Divider(height: 14),
                        Row(children: [
                          Expanded(
                              child: StatusDot(
                                  widget.selectedMeasured
                                      ? widget.selectedLatency == null
                                          ? '连通性测试超时'
                                          : '连通性 ${widget.selectedLatency} ms'
                                      : '连通性未测试',
                                  color: widget.selectedMeasured &&
                                          widget.selectedLatency == null
                                      ? danger
                                      : good)),
                          Text(uptime,
                              style: mono.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant))
                        ])
                      ]))
            ])));
  }

  Widget _traffic(BuildContext context) {
    final m = widget.monitor, ready = widget.running && (m?.available ?? false);
    Widget speed(String label, double value) {
      final text = bytesLabel(value);
      final split = text.lastIndexOf(' ');
      return Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 5),
        Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              if (ready)
                AnimatedMetric(
                    value: value,
                    format: (v) {
                      final divisor = value >= 1073741824
                          ? 1073741824.0
                          : value >= 1048576
                              ? 1048576.0
                              : value >= 1024
                                  ? 1024.0
                                  : 1.0;
                      return (v / divisor).toStringAsFixed(divisor >= 1048576
                          ? 2
                          : divisor >= 1024
                              ? 1
                              : 0);
                    },
                    style: const TextStyle(
                        fontSize: 27, fontWeight: FontWeight.w400))
              else
                const Text('—',
                    style:
                        TextStyle(fontSize: 27, fontWeight: FontWeight.w400)),
              const SizedBox(width: 4),
              Text(ready ? '${text.substring(split + 1)}/s' : 'B/s',
                  style: mono.copyWith(fontSize: 9))
            ])
      ]));
    }

    return SizedBox(
        height: 190,
        child: Panel(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
              _title(
                  '流量',
                  Tag(
                      !widget.running
                          ? '未连接'
                          : ready
                              ? '实时'
                              : '暂不可用',
                      color: ready ? good : null)),
              Row(children: [
                speed('↓ 下载', m?.downSpeed ?? 0),
                speed('↑ 上传', m?.upSpeed ?? 0)
              ]),
              const SizedBox(height: 10),
              Expanded(
                  child: SmoothTrafficChart(
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
        height: 190,
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
      height: 190,
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
  Widget _controls(BuildContext context) => Panel(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: LayoutBuilder(builder: (context, c) {
        final mode = _modePicker(context);
        final toggles = Row(children: [
          Expanded(
              child: Row(children: [
            const Text('系统代理', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 5),
            Transform.scale(
                scale: .7,
                child: Switch(
                    value: widget.systemProxy,
                    onChanged: widget.onSystemProxyChanged))
          ])),
          const Text('TUN 网卡', style: TextStyle(fontSize: 12)),
          Transform.scale(
              scale: .7,
              child: Switch(
                  value: widget.tun,
                  onChanged: widget.busy ? null : widget.onTunChanged))
        ]);
        final title =
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('代理设置',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          Text('规则 / 全局 / 直连', style: Theme.of(context).textTheme.bodySmall)
        ]);
        return c.maxWidth < 760
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                title,
                const SizedBox(height: 10),
                mode,
                const SizedBox(height: 6),
                toggles
              ])
            : Row(children: [
                SizedBox(width: 145, child: title),
                Expanded(child: mode),
                const SizedBox(width: 18),
                Expanded(child: toggles)
              ]);
      }));
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

class _CornerPainter extends CustomPainter {
  _CornerPainter(this.color);
  final Color color;
  @override
  void paint(Canvas c, Size s) => c.drawPath(
      Path()
        ..moveTo(0, s.height)
        ..lineTo(0, 0)
        ..lineTo(s.width, 0),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = .7);
  @override
  bool shouldRepaint(_CornerPainter old) => old.color != color;
}
