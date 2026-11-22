import 'package:flutter/material.dart';
import '../bridge/core_bridge.dart';
import '../services/store.dart';
import 'design.dart';
import 'node_widgets.dart';
import 'preferences.dart';
import 'runtime.dart';

class ConnectionDock extends StatelessWidget {
  const ConnectionDock(
      {super.key,
      required this.node,
      required this.subscriptions,
      required this.latency,
      required this.running,
      this.proxyActive,
      required this.busy,
      required this.onPick,
      required this.onToggle,
      required this.onProbe,
      required this.onRestart,
      this.onCancel,
      this.monitor,
      this.blocked = false,
      this.showProxyControl = true});
  final NodeInfo? node;
  final List<Subscription> subscriptions;
  final Map<NodeInfo, int?> latency;
  final bool? proxyActive;
  final bool running, busy, blocked, showProxyControl;
  final VoidCallback onPick, onToggle, onProbe, onRestart;
  final VoidCallback? onCancel;
  final RuntimeMonitor? monitor;
  @override
  Widget build(BuildContext context) {
    final active = proxyActive ?? running;
    Widget content() => LayoutBuilder(builder: (context, c) {
          final textRatio = MediaQuery.textScalerOf(context).scale(12) / 12;
          final compact = c.maxWidth < 680 * textRatio;
          return Padding(
              key: const ValueKey('connection-dock'),
              padding: EdgeInsets.fromLTRB(
                  compact ? 10 : 16, 4, compact ? 10 : 16, 10),
              child: WorkbenchGlass(
                  radius: 14,
                  child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      child: Row(children: [
                        if (!compact) ...[
                          Text('当前出口',
                              style: Theme.of(context).textTheme.bodySmall),
                          const SizedBox(width: 14)
                        ],
                        Expanded(
                            child: InkWell(
                                onTap: busy || blocked ? null : onPick,
                                borderRadius: BorderRadius.circular(8),
                                child: Padding(
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 7),
                                    child: Row(children: [
                                      if (node != null) ...[
                                        RegionMark(node!),
                                        const SizedBox(width: 9)
                                      ],
                                      Expanded(
                                          child: Text(node?.name ?? '未选择节点',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  fontWeight:
                                                      FontWeight.w600))),
                                      const SizedBox(width: 8),
                                      const Icon(Icons.unfold_more, size: 16)
                                    ])))),
                        if (c.maxWidth > 850 * textRatio &&
                            monitor != null) ...[
                          const SizedBox(width: 24),
                          Text(
                              monitor!.available
                                  ? '↓ ${bytesLabel(monitor!.downSpeed)}/s'
                                  : '↓ —',
                              style: mono.copyWith(color: good)),
                          const SizedBox(width: 16),
                          Text(
                              monitor!.available
                                  ? '↑ ${bytesLabel(monitor!.upSpeed)}/s'
                                  : '↑ —',
                              style: mono.copyWith(color: brand)),
                        ],
                        if (!compact) ...[
                          const SizedBox(width: 12),
                          StatusDot(running ? '内核就绪' : '内核停止',
                              color: running
                                  ? good
                                  : Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant),
                        ],
                        const SizedBox(width: 12),
                        if (!compact && node != null) ...[
                          LatencyText(node!, latency),
                          const SizedBox(width: 8)
                        ],
                        if (!compact) ...[
                          IconButton(
                              tooltip: '测试连通性',
                              onPressed: busy || blocked || node == null
                                  ? null
                                  : onProbe,
                              icon: const Icon(Icons.speed_outlined)),
                          IconButton(
                              tooltip: '重载内核配置',
                              onPressed: running && !busy && !blocked
                                  ? onRestart
                                  : null,
                              icon: const Icon(Icons.refresh)),
                          const SizedBox(width: 8)
                        ],
                        if (!showProxyControl)
                          Tag(active ? '代理已开启' : '代理已关闭')
                        else
                          FilledButton.icon(
                              style: FilledButton.styleFrom(
                                  minimumSize: const Size(130, 38),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 8)),
                              onPressed: blocked
                                  ? null
                                  : busy
                                      ? (running ? null : onCancel)
                                      : onToggle,
                              icon: busy
                                  ? const SizedBox(
                                      width: 15,
                                      height: 15,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 1.5,
                                          color: Colors.white))
                                  : Icon(
                                      active
                                          ? Icons.stop_circle_outlined
                                          : Icons.power_settings_new,
                                      size: 19),
                              label: Text(busy
                                  ? (running ? '正在停止' : '取消连接')
                                  : active
                                      ? '停止代理'
                                      : '启动代理')),
                      ]))));
        });
    return monitor == null
        ? content()
        : ListenableBuilder(
            listenable: monitor!, builder: (_, __) => content());
  }
}

class AppearanceSettings extends StatelessWidget {
  const AppearanceSettings({super.key});
  @override
  Widget build(BuildContext context) {
    final ui = UiScope.of(context);
    void change(UiPreferences v) => UiScope.change(context, v);
    Widget row(String title, String description, Widget control) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        child: LayoutBuilder(builder: (context, c) {
          final copy =
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Text(description, style: Theme.of(context).textTheme.bodySmall)
          ]);
          return c.maxWidth < 600
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [copy, const SizedBox(height: 10), control])
              : Row(children: [
                  Expanded(child: copy),
                  const SizedBox(width: 20),
                  control
                ]);
        }));
    Widget choices<T>(
            Map<T, String> values, T value, ValueChanged<T> onChanged) =>
        Wrap(spacing: 5, children: [
          for (final e in values.entries)
            ChoiceChip(
                label: Text(e.value),
                selected: e.key == value,
                onSelected: (_) => onChanged(e.key))
        ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text('外观与交互',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
      Panel(
          padding: EdgeInsets.zero,
          child: Column(children: [
            row(
                '界面主题',
                '选择适合环境的明暗。',
                choices(const {false: '深色', true: '浅色'}, ui.light,
                    (v) => change(ui.copyWith(light: v)))),
            const Divider(height: 1),
            row(
                '动态效果',
                '流畅：光流与控件过渡；轻量：仅交互；精简：即时切换。',
                choices(const {'full': '流畅', 'standard': '轻量', 'reduced': '精简'},
                    ui.motion, (v) => change(ui.copyWith(motion: v)))),
            const Divider(height: 1),
            row(
                '跟随系统减少动态效果',
                '系统要求减少动态时，暂停循环与过渡。',
                Switch(
                    value: ui.followSystem,
                    onChanged: (v) => change(ui.copyWith(followSystem: v)))),
            const Divider(height: 1),
            row(
                '狂三细节',
                '角色图标、酒红选中态、红金饰边与蝴蝶结小标。',
                Switch(
                    value: ui.character,
                    onChanged: (v) => change(ui.copyWith(character: v)))),
            const Divider(height: 1),
            row(
                '连接条光流',
                '限定在连接状态组件内，不增加页面高度。',
                Switch(
                    value: ui.flow,
                    onChanged: (v) => change(ui.copyWith(flow: v)))),
            const Divider(height: 1),
            row(
                '列表密度',
                '切换节点列表的行间距。',
                choices(const {false: '舒适', true: '紧凑'}, ui.compact,
                    (v) => change(ui.copyWith(compact: v)))),
            const Divider(height: 1),
            row(
                '关闭窗口时',
                '退出时停止内核，并关闭本应用设置的系统代理。',
                choices(const {true: '最小化到托盘', false: '退出应用'}, ui.closeToTray,
                    (v) => change(ui.copyWith(closeToTray: v)))),
          ])),
      const Padding(
          padding: EdgeInsets.only(top: 8, bottom: 22),
          child:
              Text('外观偏好即时生效并保存；保存失败会在顶部持续提示。', style: TextStyle(fontSize: 11)))
    ]);
  }
}
