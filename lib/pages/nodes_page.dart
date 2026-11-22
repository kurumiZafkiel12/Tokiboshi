import 'package:flutter/material.dart';
import '../bridge/core_bridge.dart';
import '../services/store.dart';
import '../services/subscription_resolver.dart';
import '../ui/design.dart';
import '../ui/node_widgets.dart';
import '../ui/preferences.dart';
import '../ui/import_menu.dart';
import '../ui/motion.dart';
import 'node_quality_panel.dart';

class NodesPage extends StatefulWidget {
  const NodesPage(
      {super.key,
      required this.nodes,
      required this.subscriptions,
      required this.selectedIndex,
      required this.running,
      required this.busy,
      required this.latency,
      required this.onSelect,
      required this.onDelete,
      required this.onImport,
      required this.onMeasureAll,
      this.onCreateChain,
      this.onMeasureNode,
      this.onQualitySample,
      this.onImportMethod,
      this.pendingNodes = const {}});
  final List<NodeInfo> nodes;
  final List<Subscription> subscriptions;
  final int selectedIndex;
  final bool running, busy;
  final Map<NodeInfo, int?> latency;
  final Set<NodeInfo> pendingNodes;
  final ValueChanged<int> onSelect, onDelete;
  final VoidCallback onImport, onMeasureAll;
  final VoidCallback? onCreateChain;
  final ValueChanged<NodeInfo>? onMeasureNode;
  final Future<int?> Function(NodeInfo)? onQualitySample;
  final ValueChanged<String>? onImportMethod;
  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  String _query = '', _group = '', _source = '';
  NodeInfo? _qualityNode;
  final Map<String, bool> _expanded = {};
  @override
  void didUpdateWidget(covariant NodesPage old) {
    super.didUpdateWidget(old);
    if (!identical(old.nodes, widget.nodes)) {
      _group = '';
      if (!widget.nodes.contains(_qualityNode)) _qualityNode = null;
    }
    if (old.selectedIndex != widget.selectedIndex) _qualityNode = null;
  }

  bool _grid = false, _sort = false;
  final _search = TextEditingController();
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _details(int index) {
    final n = widget.nodes[index];
    showNodeDetails(context, n, widget.subscriptions, widget.latency,
        onSelect: widget.busy ? null : () => widget.onSelect(index),
        onMeasure: widget.busy ? null : () => widget.onMeasureNode?.call(n),
        onQuality: !widget.running || widget.onQualitySample == null
            ? null
            : () => setState(() => _qualityNode = n),
        onDelete: widget.running || widget.busy ? null : () => _delete(index));
  }

  Future<void> _delete(int index) async {
    final target = widget.nodes[index];
    final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('删除节点？'),
                content:
                    Text('将移除「${widget.nodes[index].name}」。订阅节点在下次更新时可能重新出现。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('删除'))
                ]));
    if (confirm == true && mounted) {
      final current = widget.nodes.indexOf(target);
      if (current >= 0) widget.onDelete(current);
    }
  }

  @override
  Widget build(BuildContext context) {
    final policyIndex =
        _group.startsWith('policy:') ? int.tryParse(_group.substring(7)) : null;
    final members = policyIndex != null && policyIndex < widget.nodes.length
        ? policyNodeIndices(widget.nodes, policyIndex)
        : <int>{};
    bool visible(NodeInfo n, int i) {
      if (n.isPolicy) return false;
      if (_source == '__manual' && n.source.isNotEmpty) return false;
      if (_source.isNotEmpty && _source != '__manual' && n.source != _source)
        return false;
      if (policyIndex != null && !members.contains(i)) return false;
      if (policyIndex == null && _group.isNotEmpty) {
        if (_group == '__manual') {
          if (n.source.isNotEmpty) return false;
        } else if (_group.startsWith('provider:')) {
          if (n.group != _group.substring(9)) return false;
        } else if (n.source != _group) return false;
      }
      return '${n.name} ${n.server} ${n.protocol} ${regionLabel(n)} ${sourceLabel(n, widget.subscriptions)}'
          .toLowerCase()
          .contains(_query);
    }

    final indices = [
      for (var i = 0; i < widget.nodes.length; i++)
        if (visible(widget.nodes[i], i)) i
    ];
    if (_sort)
      indices.sort((a, b) => (widget.latency[widget.nodes[a]] ?? 0x7fffffff)
          .compareTo(widget.latency[widget.nodes[b]] ?? 0x7fffffff));
    return Padding(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 12),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PageHeading('节点选择（${widget.nodes.where((n) => !n.isPolicy).length}）',
              '按来源筛选，选择适合当前连接的出口。',
              eyebrow: 'FIND YOUR NEXT CONNECTION.',
              actions: [
                if (widget.onCreateChain != null)
                  OutlinedButton.icon(
                      onPressed: widget.busy ||
                              widget.running ||
                              widget.nodes.length < 2
                          ? null
                          : widget.onCreateChain,
                      icon: const Icon(Icons.link, size: 16),
                      label: const Text('链式代理')),
                OutlinedButton.icon(
                    onPressed: widget.busy ? null : widget.onMeasureAll,
                    icon: const Icon(Icons.speed, size: 16),
                    label: const Text('测速全部')),
                ImportMenuButton(
                    label: '导入',
                    enabled: !widget.busy,
                    onSelected: (method) => widget.onImportMethod == null
                        ? widget.onImport()
                        : widget.onImportMethod!(method))
              ]),
          if (widget.running &&
              widget.onQualitySample != null &&
              widget.selectedIndex >= 0 &&
              widget.selectedIndex < widget.nodes.length) ...[
            const SizedBox(height: 8),
            NodeQualityPanel(
                node: _qualityNode ?? widget.nodes[widget.selectedIndex],
                measure: widget.onQualitySample!),
            const SizedBox(height: 8),
          ],
          SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                Text('来源', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(width: 10),
                for (final entry in {
                  '': '全部来源',
                  if (widget.nodes.any((n) => n.source.isEmpty))
                    '__manual': '手动导入',
                  for (final sub in widget.subscriptions) sub.id: sub.name
                }.entries)
                  Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                          label: Text(entry.value),
                          selected: _source == entry.key,
                          onSelected: widget.busy
                              ? null
                              : (_) => setState(() {
                                    _source = entry.key;
                                    _group = '';
                                  })))
              ])),
          if (policyIndex != null)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  const Expanded(
                      child: Text('当前仅筛选策略成员；使用策略组需明确切换。',
                          style: TextStyle(fontSize: 12))),
                  TextButton.icon(
                      onPressed: widget.busy
                          ? null
                          : () => widget.onSelect(policyIndex),
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: const Text('使用此策略组'))
                ])),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
                child: TextField(
                    controller: _search,
                    decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search, size: 17),
                        hintText: '搜索节点名或服务器、地区、协议',
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清除搜索',
                                onPressed: () {
                                  _search.clear();
                                  setState(() => _query = '');
                                },
                                icon: const Icon(Icons.close, size: 15))),
                    onChanged: (v) =>
                        setState(() => _query = v.trim().toLowerCase()))),
            const SizedBox(width: 8),
            IconButton(
                tooltip: '按延迟排序',
                isSelected: _sort,
                onPressed: () => setState(() => _sort = !_sort),
                icon: const Icon(Icons.sort)),
            IconButton(
                tooltip: '列表视图',
                isSelected: !_grid,
                onPressed: () => setState(() => _grid = false),
                icon: const Icon(Icons.view_list_outlined)),
            IconButton(
                tooltip: '卡片视图',
                isSelected: _grid,
                onPressed: () => setState(() => _grid = true),
                icon: const Icon(Icons.grid_view_outlined))
          ]),
          const SizedBox(height: 14),
          Expanded(
              child: widget.nodes.isEmpty
                  ? EmptyView('还没有节点', '导入分享链接或订阅，开始建立连接。',
                      icon: Icons.dns_outlined,
                      action: FilledButton(
                          onPressed: widget.onImport,
                          child: const Text('导入节点')))
                  : indices.isEmpty
                      ? EmptyView('没有找到匹配的节点', '试试其他来源或关键词。',
                          icon: Icons.search,
                          action: TextButton(
                              onPressed: () {
                                _search.clear();
                                setState(() {
                                  _query = '';
                                  _group = '';
                                  _source = '';
                                });
                              },
                              child: const Text('清除筛选')))
                      : _grouped(indices)),
          const SizedBox(height: 9),
          Row(children: [
            Expanded(
                child: Text(
                    '显示 ${indices.length} / ${widget.nodes.where((n) => !n.isPolicy).length} 个节点',
                    style: Theme.of(context).textTheme.bodySmall)),
            Text(widget.running ? '内核 URL 测速 · 含代理握手' : 'TCP 端口探测 · 不代表代理可用',
                style: Theme.of(context).textTheme.bodySmall)
          ])
        ]));
  }

  Widget _grouped(List<int> indices) {
    final scaler = MediaQuery.textScalerOf(context);
    final rowHeight = (UiScope.of(context).compact ? 52.0 : 68.0) +
        (scaler.scale(36) - 36).clamp(0.0, double.infinity);
    final cardHeight =
        124.0 + (scaler.scale(54) - 54).clamp(0.0, double.infinity);
    final groups = <String, List<int>>{};
    final labels = <String, String>{};
    for (final i in indices) {
      final n = widget.nodes[i], key = '${n.source}\u0000${n.group}';
      groups.putIfAbsent(key, () => []).add(i);
      labels[key] = sourceLabel(n, widget.subscriptions);
    }
    final keys = groups.keys.toList();
    if (_sort)
      keys.sort((a, b) => groups[a]!
          .reduce((x, y) => x < y ? x : y)
          .compareTo(groups[b]!.reduce((x, y) => x < y ? x : y)));
    bool initiallyOpen(String key) =>
        keys.length <= 3 ||
        key == keys.first ||
        groups[key]!.contains(widget.selectedIndex) ||
        _group.isNotEmpty ||
        _query.isNotEmpty;
    return CustomScrollView(slivers: [
      for (final key in keys) ...[
        SliverToBoxAdapter(
            child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Panel(
                    padding: EdgeInsets.zero,
                    child: InkWell(
                        onTap: () => setState(() => _expanded[key] =
                            !(_expanded[key] ?? initiallyOpen(key))),
                        child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 15),
                            child: Row(children: [
                              Icon(Icons.folder_outlined,
                                  size: 20,
                                  color: Theme.of(context).colorScheme.primary),
                              const SizedBox(width: 10),
                              Expanded(
                                  child: Text(
                                      '${labels[key]}（${groups[key]!.length}）',
                                      style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600))),
                              Icon(
                                  (_expanded[key] ?? initiallyOpen(key))
                                      ? Icons.expand_less
                                      : Icons.expand_more,
                                  size: 18)
                            ])))))),
        if (_expanded[key] ?? initiallyOpen(key))
          if (_grid)
            SliverPadding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                sliver: SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 320,
                        mainAxisExtent: cardHeight,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10),
                    itemCount: groups[key]!.length,
                    itemBuilder: (_, position) => MotionHover(
                        lift: true, child: _card(groups[key]![position]))))
          else if (groups[key]!.length <= 80)
            SliverToBoxAdapter(
                child: SizedBox(
                    height: groups[key]!.length * rowHeight,
                    child: Stack(children: [
                      for (var position = 0;
                          position < groups[key]!.length;
                          position++)
                        AnimatedPositioned(
                            key: ValueKey('node-${groups[key]![position]}'),
                            duration: UiScope.duration(context, 280),
                            curve: Curves.easeOutCubic,
                            top: position * rowHeight,
                            left: 0,
                            right: 0,
                            height: rowHeight,
                            child: MotionHover(
                                child: _row(groups[key]![position])))
                    ])))
          else
            SliverList.builder(
                itemCount: groups[key]!.length,
                itemBuilder: (_, position) => MotionHover(
                    key: ValueKey(groups[key]![position]),
                    child: _row(groups[key]![position])))
      ]
    ]);
  }

  Widget _row(int i) {
    final n = widget.nodes[i], selected = i == widget.selectedIndex;
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
        duration: UiScope.duration(context),
        decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withValues(alpha: .07)
                : Colors.transparent,
            border: Border(
                left: BorderSide(
                    color: selected ? scheme.primary : Colors.transparent,
                    width: 2),
                bottom: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: .5)))),
        child: InkWell(
            onTap: widget.busy ? null : () => widget.onSelect(i),
            child: Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: UiScope.of(context).compact ? 6 : 11),
                child: LayoutBuilder(
                    builder: (context, c) => Row(children: [
                          RegionMark(n),
                          const SizedBox(width: 12),
                          Expanded(
                              flex: 3,
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(n.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: selected
                                                ? FontWeight.w600
                                                : FontWeight.w400)),
                                    Text('${n.server}:${n.serverPort}',
                                        style: mono.copyWith(
                                            fontSize: 10,
                                            color: scheme.onSurfaceVariant),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis)
                                  ])),
                          if (c.maxWidth > 740) ...[
                            const SizedBox(width: 18),
                            Expanded(
                                flex: 2,
                                child: Text(
                                    sourceLabel(n, widget.subscriptions),
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis))
                          ],
                          if (c.maxWidth > 480) ...[
                            const SizedBox(width: 12),
                            SizedBox(
                                width: 85,
                                child: Text(n.protocol.toUpperCase(),
                                    style: mono.copyWith(
                                        fontSize: 10,
                                        color: scheme.onSurfaceVariant)))
                          ],
                          const SizedBox(width: 10),
                          SizedBox(
                              width: 70,
                              child: widget.pendingNodes.contains(n)
                                  ? const Tag('待应用', color: gold)
                                  : LatencyText(n, widget.latency)),
                          IconButton(
                              tooltip: '节点详情',
                              onPressed: () => _details(i),
                              icon: const Icon(Icons.more_horiz, size: 17)),
                          SizedBox(
                              width: 20,
                              child: selected
                                  ? Icon(Icons.check_circle_outline,
                                      color: scheme.primary, size: 17)
                                  : const SizedBox())
                        ])))));
  }

  Widget _card(int i) {
    final n = widget.nodes[i], selected = i == widget.selectedIndex;
    return Panel(
        accent: selected,
        padding: EdgeInsets.zero,
        child: InkWell(
            onTap: widget.busy ? null : () => widget.onSelect(i),
            borderRadius: BorderRadius.circular(7),
            child: Padding(
                padding: const EdgeInsets.all(13),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        RegionMark(n),
                        const SizedBox(width: 10),
                        Expanded(
                            child: Text(n.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13))),
                        IconButton(
                            tooltip: '节点详情',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minHeight: 24, minWidth: 24),
                            onPressed: () => _details(i),
                            icon: const Icon(Icons.more_horiz, size: 17))
                      ]),
                      const Spacer(),
                      Row(children: [
                        Tag(n.protocol.toUpperCase()),
                        const Spacer(),
                        if (widget.pendingNodes.contains(n))
                          const Tag('待应用', color: gold)
                        else
                          LatencyText(n, widget.latency)
                      ]),
                      const SizedBox(height: 5),
                      Text(sourceLabel(n, widget.subscriptions),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall)
                    ]))));
  }
}
