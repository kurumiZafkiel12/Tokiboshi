import 'package:flutter/material.dart';

import '../bridge/core_bridge.dart';

/// Home / dashboard: connection status, selected node, quick stats.
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
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            Chip(
                              avatar: const Icon(Icons.lan, size: 16),
                              label: Text('127.0.0.1:$mixedPort'),
                              visualDensity: VisualDensity.compact,
                            ),
                            Chip(
                              avatar: const Icon(Icons.language, size: 16),
                              label: Text(systemProxy ? '系统代理 开' : '系统代理 关'),
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  FilledButton(
                    onPressed: busy ? null : onToggle,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                    ),
                    child: Text(running ? '停止' : '启动', style: const TextStyle(fontSize: 16)),
                  ),
                ],
              ),
            ),
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
