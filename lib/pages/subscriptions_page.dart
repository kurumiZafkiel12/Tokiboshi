import 'package:flutter/material.dart';
import '../services/store.dart';
import '../ui/design.dart';
import '../ui/diagnostics.dart';
import '../ui/import_menu.dart';
import '../ui/motion.dart';

class SubscriptionsPage extends StatefulWidget {
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
      this.onRetryFull,
      this.onEdit,
      this.activeProfileId,
      this.onActivate});
  final List<Subscription> subscriptions;
  final Map<String, int> nodeCounts;
  final bool running, busy;
  final VoidCallback onAdd;
  final VoidCallback? onUpdateAll;
  final ValueChanged<Subscription> onUpdate, onDelete;
  final ValueChanged<String>? onImportMethod, onActivate;
  final ValueChanged<Subscription>? onRetryFull, onEdit;
  final String? activeProfileId;
  @override
  State<SubscriptionsPage> createState() => _SubscriptionsPageState();
}

class _SubscriptionsPageState extends State<SubscriptionsPage> {
  String query = '', filter = 'all';
  Future<void> remove(Subscription sub) async {
    final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
                title: const Text('删除订阅？'),
                content: Text('将删除「${sub.name}」及其导入的节点。其他来源不受影响。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(c, true),
                      child: const Text('删除订阅'))
                ]));
    if (yes == true && mounted && !widget.busy && !widget.running)
      widget.onDelete(sub);
  }

  void details(Subscription sub) => showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
              title: Text('${sub.name} · 来源详情'),
              content: SizedBox(
                  width: 600,
                  child: SingleChildScrollView(
                      child: SelectableText(redactDiagnostics(
                          '${sub.lastError?.isNotEmpty == true ? '最近更新失败：${sub.lastError}\n\n' : ''}${sub.lastReport ?? '请更新订阅以获取来源诊断'}')))),
              actions: [
                if (sub.nodesOnly &&
                    !widget.busy &&
                    !widget.running &&
                    widget.onRetryFull != null)
                  TextButton(
                      onPressed: () {
                        Navigator.pop(c);
                        widget.onRetryFull!(sub);
                      },
                      child: const Text('尝试完整配置')),
                TextButton(
                    onPressed: () => Navigator.pop(c), child: const Text('关闭'))
              ]));
  @override
  Widget build(BuildContext context) {
    final locked = widget.busy || widget.running;
    final sources = widget.subscriptions
        .where((s) =>
            s.name.toLowerCase().contains(query) &&
            (filter == 'all' ||
                filter == 'remote' && s.isRemote ||
                filter == 'local' && !s.isRemote ||
                filter == 'failed' && (s.lastError?.isNotEmpty ?? false)))
        .toList();
    final counts = [
      ('订阅来源', '${widget.subscriptions.length}', '远程订阅与本地配置', Icons.rss_feed),
      (
        '来源节点',
        '${widget.nodeCounts.values.fold<int>(0, (a, b) => a + b)}',
        '不把策略组计入节点',
        Icons.hub_outlined
      ),
      ('导入方式', '仅节点', '分流由应用内置规则与自定义规则管理', Icons.route_outlined),
      (
        '自动更新',
        '${widget.subscriptions.where((s) => s.refreshMinutes > 0).length}',
        '运行中延后，失败保留旧数据',
        Icons.update
      )
    ];
    return CustomScrollView(
      key: const PageStorageKey('subscription-list'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
          sliver: SliverToBoxAdapter(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PageHeading('订阅管理', '每条订阅独立保存节点与更新计划。',
                      eyebrow: 'SOURCES / PROFILES',
                      actions: [
                        OutlinedButton.icon(
                            onPressed: locked || widget.subscriptions.isEmpty
                                ? null
                                : widget.onUpdateAll,
                            icon: const Icon(Icons.sync, size: 16),
                            label: const Text('更新全部')),
                        ImportMenuButton(
                            label: '添加订阅',
                            enabled: !widget.busy,
                            onSelected: (method) =>
                                widget.onImportMethod == null
                                    ? widget.onAdd()
                                    : widget.onImportMethod!(method))
                      ]),
                  LayoutBuilder(
                      builder: (c, size) =>
                          Wrap(spacing: 12, runSpacing: 12, children: [
                            for (final item in counts)
                              SizedBox(
                                  width: (size.maxWidth -
                                          12 * (size.maxWidth < 560 ? 1 : 3)) /
                                      (size.maxWidth < 560 ? 2 : 4),
                                  child: MotionEntrance(
                                      order: counts.indexOf(item),
                                      child: Panel(
                                          padding: const EdgeInsets.all(16),
                                          child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Row(children: [
                                                  Expanded(
                                                      child: Text(item.$1,
                                                          style: Theme.of(c)
                                                              .textTheme
                                                              .bodySmall)),
                                                  Icon(item.$4,
                                                      size: 17,
                                                      color: Theme.of(c)
                                                          .colorScheme
                                                          .primary)
                                                ]),
                                                const SizedBox(height: 10),
                                                Text(item.$2,
                                                    style: const TextStyle(
                                                        fontSize: 26,
                                                        fontWeight:
                                                            FontWeight.w600)),
                                                const SizedBox(height: 5),
                                                Text(item.$3,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: Theme.of(c)
                                                        .textTheme
                                                        .bodySmall)
                                              ]))))
                          ])),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(
                        child: TextField(
                            decoration: const InputDecoration(
                                prefixIcon: Icon(Icons.search, size: 18),
                                hintText: '搜索订阅名称'),
                            onChanged: (v) => setState(
                                () => query = v.trim().toLowerCase()))),
                    const SizedBox(width: 12),
                    for (final entry in {
                      'all': '全部',
                      'remote': '远程',
                      'local': '本地',
                      'failed': '更新失败'
                    }.entries)
                      Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: ChoiceChip(
                              label: Text(entry.value),
                              selected: filter == entry.key,
                              onSelected: (_) =>
                                  setState(() => filter = entry.key)))
                  ]),
                ]),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          sliver: sources.isEmpty
              ? SliverToBoxAdapter(
                  child: widget.subscriptions.isEmpty
                      ? EmptyView('还没有订阅', '添加一个订阅源，集中管理节点与规则。',
                          icon: Icons.inventory_2_outlined,
                          action: FilledButton(
                              onPressed: widget.busy ? null : widget.onAdd,
                              child: const Text('添加第一个订阅')))
                      : const EmptyView('没有匹配的来源', '请调整名称或更新状态筛选。'))
              : SliverList.separated(
                  itemCount: sources.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (c, i) => MotionEntrance(
                      order: i,
                      child: MotionHover(child: sourceCard(c, sources[i])))),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 22),
          sliver: SliverToBoxAdapter(
              child: Text(
                  widget.running
                      ? '运行中可添加来源。新节点下次启动或应用配置后进入内核，现有连接继续运行。'
                      : '更新失败保留上次有效数据。订阅地址和凭据默认隐藏。',
                  style: Theme.of(context).textTheme.bodySmall)),
        ),
      ],
    );
  }

  Widget sourceCard(BuildContext context, Subscription sub) {
    final locked = widget.busy || widget.running,
        failed = sub.lastError?.isNotEmpty ?? false;
    final active = widget.activeProfileId == sub.id;
    final updated = DateTime.tryParse(sub.updatedAt ?? '')
            ?.toLocal()
            .toString()
            .split('.')
            .first ??
        '尚未更新';
    return Panel(
        padding: EdgeInsets.zero,
        accent: active,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
              padding: const EdgeInsets.all(18),
              child: Row(children: [
                Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: wine.withValues(alpha: .12),
                        borderRadius: BorderRadius.circular(12)),
                    child: Icon(
                        sub.isRemote
                            ? Icons.rss_feed
                            : Icons.description_outlined,
                        color: Theme.of(context).colorScheme.primary,
                        size: 24)),
                const SizedBox(width: 14),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(sub.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 7),
                      Wrap(spacing: 8, runSpacing: 5, children: [
                        Tag(sub.isRemote
                            ? '远程来源'
                            : sub.localPath != null
                                ? '本地文件'
                                : '粘贴配置'),
                        Tag(sub.profileJson != null ? '完整配置' : '仅节点'),
                        if (active) const Tag('当前规则配置', color: good),
                        if (sub.profileState == 'pending-update')
                          const Tag('地址已改 · 等待更新', color: gold),
                        if (failed) const Tag('更新失败 · 保留旧数据', color: danger)
                      ])
                    ])),
                if (widget.onEdit != null)
                  IconButton(
                      tooltip: '编辑订阅',
                      onPressed: locked ? null : () => widget.onEdit!(sub),
                      icon: const Icon(Icons.edit_outlined))
              ])),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Wrap(spacing: 32, runSpacing: 12, children: [
                fact('节点数量', '${widget.nodeCounts[sub.id] ?? 0}'),
                fact('规则来源', sub.profileJson != null ? '随订阅提供' : '使用应用模板'),
                fact(
                    '更新计划',
                    sub.refreshMinutes == 0
                        ? '手动更新'
                        : '每 ${sub.refreshMinutes} 分钟'),
                fact('上次成功', updated)
              ])),
          if (failed)
            Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(redactDiagnostics(sub.lastError!),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12))),
          const SizedBox(height: 16),
          const Divider(height: 1),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(children: [
                TextButton.icon(
                    onPressed: () => details(sub),
                    icon: const Icon(Icons.info_outline, size: 16),
                    label: const Text('来源与识别详情')),
                const Spacer(),
                if (sub.profileJson != null && widget.onActivate != null)
                  TextButton(
                      onPressed: locked || active
                          ? null
                          : () => widget.onActivate!(sub.id),
                      child: Text(active ? '已启用' : '启用规则配置')),
                Tooltip(
                    message: '更新',
                    child: OutlinedButton.icon(
                        onPressed: locked ? null : () => widget.onUpdate(sub),
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('立即更新'))),
                const SizedBox(width: 6),
                IconButton(
                    tooltip: '删除',
                    onPressed: locked ? null : () => remove(sub),
                    icon: const Icon(Icons.delete_outline, size: 17))
              ]))
        ]));
  }

  Widget fact(String label, String value) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 5),
        Text(value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500))
      ]);
}
