import 'package:flutter/material.dart';
import '../services/store.dart';
import '../ui/design.dart';
import '../ui/diagnostics.dart';
import '../ui/import_menu.dart';
import '../ui/motion.dart';

class SubscriptionsPage extends StatelessWidget {
  const SubscriptionsPage(
      {super.key,
      required this.subscriptions,
      required this.nodeCounts,
      required this.running,
      required this.busy,
      required this.onAdd,
      required this.onUpdate,
      required this.onDelete,
      this.onUpdateAll,
      this.onImportMethod,
      this.onRetryFull});
  final List<Subscription> subscriptions;
  final Map<String, int> nodeCounts;
  final bool running, busy;
  final VoidCallback onAdd;
  final VoidCallback? onUpdateAll;
  final ValueChanged<Subscription> onUpdate, onDelete;
  final ValueChanged<String>? onImportMethod;
  final ValueChanged<Subscription>? onRetryFull;
  Future<void> _delete(BuildContext context, Subscription sub) async {
    final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('删除订阅？'),
                content: Text('将删除「${sub.name}」及其导入的节点。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('删除订阅'))
                ]));
    if (yes == true) onDelete(sub);
  }

  void _details(BuildContext context, Subscription sub) => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
              title: Text('${sub.name} · 来源详情'),
              content: SizedBox(
                  width: 600,
                  child: SingleChildScrollView(
                      child: SelectableText(redactDiagnostics(
                          sub.lastReport ?? '请更新订阅以获取来源诊断')))),
              actions: [
                if (sub.nodesOnly && !busy && !running && onRetryFull != null)
                  TextButton(
                      onPressed: () {
                        Navigator.pop(context);
                        onRetryFull!(sub);
                      },
                      child: const Text('尝试完整配置')),
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'))
              ]));
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.all(22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeading('订阅', '完整配置负责规则，节点来源提供更多选择。',
            eyebrow: 'ONE PLACE FOR YOUR SOURCES.',
            actions: [
              OutlinedButton.icon(
                  onPressed: busy || running || subscriptions.isEmpty
                      ? null
                      : onUpdateAll,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('更新全部')),
              ImportMenuButton(
                  label: '添加订阅',
                  enabled: !busy && !running,
                  onSelected: (method) => onImportMethod == null
                      ? onAdd()
                      : onImportMethod!(method))
            ]),
        if (running)
          Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Panel(
                  child: Row(children: [
                Icon(Icons.info_outline,
                    size: 17, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                const Expanded(
                    child: Text('请先停止代理，再更新或删除来源，避免改变运行中的节点与规则。',
                        style: TextStyle(fontSize: 12)))
              ]))),
        Expanded(
            child: subscriptions.isEmpty
                ? EmptyView('还没有订阅', '添加一个订阅来源，集中管理节点与规则。',
                    icon: Icons.inventory_2_outlined,
                    action: FilledButton(
                        onPressed: onAdd, child: const Text('添加第一个订阅')))
                : ListView.separated(
                    itemCount: subscriptions.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 14),
                    itemBuilder: (context, i) {
                      final sub = subscriptions[i];
                      final host = sub.isRemote
                          ? (Uri.tryParse(sub.url)?.host ?? '地址已隐藏')
                          : sub.localPath != null
                              ? '本地文件 · ${sub.localPath!.split(RegExp(r"[\\/]")).last}'
                              : '粘贴的本地配置';
                      final updated = DateTime.tryParse(sub.updatedAt ?? '');
                      return MotionEntrance(
                          order: i,
                          child: MotionHover(
                              lift: true,
                              child: Panel(
                                  padding: EdgeInsets.zero,
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                                20, 18, 20, 14),
                                            child: Row(children: [
                                              Icon(Icons.inventory_2_outlined,
                                                  color: sub.profileJson != null
                                                      ? gold
                                                      : Theme.of(context)
                                                          .colorScheme
                                                          .primary,
                                                  size: 23),
                                              const SizedBox(width: 13),
                                              Expanded(
                                                  child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                    Text(sub.name,
                                                        style: const TextStyle(
                                                            fontSize: 16,
                                                            fontWeight:
                                                                FontWeight
                                                                    .w600)),
                                                    const SizedBox(height: 4),
                                                    Text(host,
                                                        style: mono.copyWith(
                                                            color: Theme.of(
                                                                    context)
                                                                .colorScheme
                                                                .onSurfaceVariant))
                                                  ])),
                                              Tag(
                                                  sub.profileJson != null
                                                      ? '完整配置'
                                                      : '仅节点',
                                                  color: sub.profileJson != null
                                                      ? Theme.of(context)
                                                          .colorScheme
                                                          .primary
                                                      : null)
                                            ])),
                                        Padding(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 20),
                                            child: Wrap(
                                                spacing: 30,
                                                runSpacing: 8,
                                                children: [
                                                  _fact(context, '节点',
                                                      '${nodeCounts[sub.id] ?? 0}'),
                                                  _fact(
                                                      context,
                                                      '规则',
                                                      sub.profileJson != null
                                                          ? '随订阅提供'
                                                          : '使用应用模板'),
                                                  _fact(
                                                      context,
                                                      '上次更新',
                                                      updated == null
                                                          ? '尚未更新'
                                                          : updated
                                                              .toLocal()
                                                              .toString()
                                                              .split('.')
                                                              .first)
                                                ])),
                                        const SizedBox(height: 16),
                                        const Divider(height: 1),
                                        Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                                14, 6, 12, 6),
                                            child: Row(children: [
                                              TextButton.icon(
                                                  onPressed: () =>
                                                      _details(context, sub),
                                                  icon: const Icon(
                                                      Icons.info_outline,
                                                      size: 15),
                                                  label: const Text('来源与识别详情')),
                                              const Spacer(),
                                              IconButton(
                                                  tooltip: '更新',
                                                  onPressed: busy || running
                                                      ? null
                                                      : () => onUpdate(sub),
                                                  icon: const Icon(
                                                      Icons.refresh,
                                                      size: 17)),
                                              IconButton(
                                                  tooltip: '删除',
                                                  onPressed: busy || running
                                                      ? null
                                                      : () =>
                                                          _delete(context, sub),
                                                  icon: const Icon(
                                                      Icons.delete_outline,
                                                      size: 17))
                                            ]))
                                      ]))));
                    })),
        const SizedBox(height: 12),
        Text('来源更新失败会保留先前已保存的数据。订阅地址和凭据默认隐藏。',
            style: Theme.of(context).textTheme.bodySmall)
      ]));
  Widget _fact(BuildContext context, String label, String value) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 5),
        Text(value, style: const TextStyle(fontSize: 12))
      ]);
}
