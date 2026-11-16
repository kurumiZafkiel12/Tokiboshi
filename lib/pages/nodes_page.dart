import 'package:flutter/material.dart';
import '../bridge/core_bridge.dart';
import '../services/store.dart';
import '../services/subscription_resolver.dart';
import '../ui/design.dart';
import '../ui/node_widgets.dart';
import '../ui/preferences.dart';

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
      this.onMeasureNode});
  final List<NodeInfo> nodes;
  final List<Subscription> subscriptions;
  final int selectedIndex;
  final bool running, busy;
  final Map<NodeInfo, int?> latency;
  final ValueChanged<int> onSelect, onDelete;
  final VoidCallback onImport, onMeasureAll;
  final VoidCallback? onCreateChain;
  final ValueChanged<NodeInfo>? onMeasureNode;
  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  String _query = '', _group = '';
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
        onDelete: widget.running || widget.busy ? null : () => _delete(index));
  }

  Future<void> _delete(int index) async {
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
    if (confirm == true && mounted) widget.onDelete(index);
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
    final providers =
        widget.nodes.map((n) => n.group).where((g) => g.isNotEmpty).toSet();
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
                FilledButton.icon(
                    onPressed:
                        widget.busy || widget.running ? null : widget.onImport,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('导入'))
              ]),
          SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                _filter('全部', ''),
                for (var i = 0; i < widget.nodes.length; i++)
                  if (widget.nodes[i].isPolicy)
                    _filter(widget.nodes[i].name, 'policy:$i', policy: i),
                if (widget.nodes.any((n) => n.source.isEmpty))
                  _filter('手动导入', '__manual'),
                for (final sub in widget.subscriptions)
                  _filter(sub.name, sub.id),
                for (final p in providers) _filter(p, 'provider:$p')
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
            Text('延迟来自实际测试', style: Theme.of(context).textTheme.bodySmall)
          ])
        ]));
  }

  Widget _filter(String label, String value, {int? policy}) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
          label: Text(label),
          selected: _group == value,
          onSelected: widget.busy
              ? null
              : (_) {
                  setState(() => _group = value);
                  if (policy != null) widget.onSelect(policy);
                }));
  Widget _grouped(List<int> indices) {
    final groups = <String, List<int>>{};
    final labels = <String, String>{};
    for (final i in indices) {
      final n = widget.nodes[i], key = '${n.source}\u0000${n.group}';
      groups.putIfAbsent(key, () => []).add(i);
      labels[key] = sourceLabel(n, widget.subscriptions);
    }
    final keys = groups.keys.toList();
    return ListView.separated(
        itemCount: keys.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, g) {
          final key = keys[g], items = groups[key]!;
          return Panel(
              padding: EdgeInsets.zero,
              child: ExpansionTile(
                  key: PageStorageKey('$_group/$_query/$key'),
                  initiallyExpanded: keys.length <= 3 ||
                      _group.isNotEmpty ||
                      _query.isNotEmpty,
                  shape: const Border(),
                  collapsedShape: const Border(),
                  dense: true,
                  leading: Icon(Icons.folder_outlined,
                      size: 18, color: Theme.of(context).colorScheme.primary),
                  title: Text('${labels[key]}（${items.length}）',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w500)),
                  children: [
                    if (_grid)
                      GridView.builder(
                          key: PageStorageKey('nodes-grid/$key'),
                          primary: false,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(12),
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 320,
                                  mainAxisExtent: 118,
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 10),
                          itemCount: items.length,
                          itemBuilder: (context, row) => _card(items[row]))
                    else ...[
                      const Divider(height: 1),
                      for (final i in items) _row(i)
                    ]
                  ]));
        });
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
                              width: 70, child: LatencyText(n, widget.latency)),
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
