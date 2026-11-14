import 'package:flutter/material.dart';

import '../bridge/core_bridge.dart';

/// Home / dashboard: connection card with mode switch, quick
/// toggles （系统代理 / 虚拟网卡）, and stats.
class DashboardPage extends StatelessWidget {
  const DashboardPage({
    super.key,
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
  });

  final bool running;
  final bool busy;
  final NodeInfo? selected;
  final int nodeCount;
  final int subscriptionCount;
  final int mixedPort;
  final bool systemProxy;
  final int? selectedLatency;
  final bool selectedMeasured;
  final VoidCallback onToggle;
  final VoidCallback onMeasureSelected;
  final String? coreVersion;
  final int restartCount;
  final String? lastExit;
  final String? clashMode;
  final VoidCallback? onRestart;
  final VoidCallback? onOpenPanel;
  final bool tun;
  final ValueChanged<bool>? onTunChanged;
  final ValueChanged<bool>? onSystemProxyChanged;
  final ValueChanged<String>? onModeChanged;

  static const _modes = <(String, String)>[
    ('Rule', '规则'),
    ('Global', '全局'),
    ('Direct', '直连'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final node = selected;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('仪表盘', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Icon(
                    running ? Icons.power : Icons.power_off,
                    size: 44,
                    color: running ? Colors.greenAccent : scheme.outline,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          running ? 'sing-box 运行中' : 'sing-box 已停止',
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          node == null
                              ? '未选择节点'
                              : '${node.name} · ${node.protocol.toUpperCase()} · ${node.server}:${node.serverPort}',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 10),
                        SegmentedButton<String>(
                          segments: [
                            for (final m in _modes)
                              ButtonSegment<String>(
                                value: m.$1,
                                label: Text(m.$2),
                              ),
                          ],
                          selected: {clashMode ?? 'Rule'},
                          onSelectionChanged: running && onModeChanged != null
                              ? (s) => onModeChanged!(s.first)
                              : null,
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          children: [
                            Chip(
                              avatar: const Icon(Icons.lan, size: 16),
                              label: Text('127.0.0.1:$mixedPort'),
                              visualDensity: VisualDensity.compact,
                            ),
                            Chip(
                              avatar: const Icon(Icons.memory, size: 16),
                              label: Text(coreVersion ?? '内核未下载'),
                              visualDensity: VisualDensity.compact,
                            ),
                            if (restartCount > 0)
                              Chip(
                                avatar: const Icon(Icons.restart_alt, size: 16),
                                label: Text('已自动重启 $restartCount 次'),
                                visualDensity: VisualDensity.compact,
                              ),
                          ],
                        ),
                        if (lastExit != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            '上次退出：$lastExit',
                            style: TextStyle(color: scheme.error),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton(
                        onPressed: busy ? null : onToggle,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                        ),
                        child: Text(running ? '停止' : '启动', style: const TextStyle(fontSize: 16)),
                      ),
                      if (running) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed: busy ? null : onRestart,
                              child: const Text('重启'),
                            ),
                            OutlinedButton(
                              onPressed: onOpenPanel,
                              child: const Text('打开面板'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _toggleCard(
                  context,
                  icon: Icons.shuffle,
                  label: '系统代理',
                  subtitle: '把系统代理指向 127.0.0.1:$mixedPort',
                  value: systemProxy,
                  onChanged: onSystemProxyChanged,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _toggleCard(
                  context,
                  icon: Icons.shield_outlined,
                  label: '虚拟网卡',
                  subtitle: 'TUN 模式接管全局流量（需以管理员身份运行）',
                  value: tun,
                  onChanged: busy ? null : onTunChanged,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _statCard(context, Icons.dns_outlined, '节点', '$nodeCount')),
              const SizedBox(width: 12),
              Expanded(
                child: _statCard(context, Icons.subscriptions_outlined, '订阅', '$subscriptionCount'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.speed, size: 18, color: scheme.primary),
                            const SizedBox(width: 8),
                            const Text('当前节点延迟'),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Text(
                              node == null
                                  ? '—'
                                  : (!selectedMeasured
                                      ? '未测速'
                                      : (selectedLatency == null ? '超时' : '$selectedLatency ms')),
                              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                            ),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.refresh, size: 18),
                              tooltip: '测速',
                              visualDensity: VisualDensity.compact,
                              onPressed: node == null ? null : onMeasureSelected,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _toggleCard(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: value
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 20, color: value ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }

  Widget _statCard(BuildContext context, IconData icon, String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text(label),
              ],
            ),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
