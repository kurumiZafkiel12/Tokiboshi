import 'package:flutter/material.dart';

import '../services/store.dart';

/// Subscription management: add by URL, update, delete.
class SubscriptionsPage extends StatelessWidget {
  const SubscriptionsPage({
    super.key,
    required this.subscriptions,
    required this.nodeCounts,
    required this.running,
    required this.busy,
    required this.onAdd,
    required this.onUpdate,
    required this.onDelete,
  });

  final List<Subscription> subscriptions;
  final Map<String, int> nodeCounts;
  final bool running;
  final bool busy;
  final VoidCallback onAdd;
  final ValueChanged<Subscription> onUpdate;
  final ValueChanged<Subscription> onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Row(
            children: [
              const Text('订阅', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
              const Spacer(),
              FilledButton.icon(
                onPressed: busy || running ? null : onAdd,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加订阅'),
              ),
            ],
          ),
        ),
        Expanded(
          child: subscriptions.isEmpty
              ? const Center(child: Text('还没有订阅，点右上角添加订阅链接'))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  children: [
                    for (final sub in subscriptions)
                      Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Row(
                            children: [
                              Icon(Icons.rss_feed, color: scheme.primary),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      sub.name,
                                      style: const TextStyle(fontWeight: FontWeight.w600),
                                    ),
                                    Text(
                                      sub.url,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                    Text(
                                      '${nodeCounts[sub.id] ?? 0} 个节点'
                                      '${sub.updatedAt == null ? '' : ' · 更新于 ${sub.updatedAt!.replaceFirst('T', ' ').substring(0, 19)}'}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.info_outline),
                                tooltip: '来源与识别详情',
                                onPressed: () => showDialog<void>(context: context, builder: (context) => AlertDialog(
                                  title: const Text('来源与识别详情'),
                                  content: SingleChildScrollView(child: SelectableText(sub.lastReport ?? '请更新订阅以获取来源诊断')),
                                  actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
                                )),
                              ),
                              IconButton(
                                icon: const Icon(Icons.refresh),
                                tooltip: '更新',
                                onPressed:
                                    busy || running ? null : () => onUpdate(sub),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: '删除',
                                onPressed:
                                    busy || running ? null : () => onDelete(sub),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
