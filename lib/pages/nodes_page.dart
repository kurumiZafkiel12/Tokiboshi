import 'package:flutter/material.dart';

import '../bridge/core_bridge.dart';
import '../services/store.dart';

const _protocolColors = <String, Color>{
  'vless': Color(0xFF42A5F5),
  'vmess': Color(0xFFAB47BC),
  'trojan': Color(0xFFFF7043),
  'hysteria2': Color(0xFFEC407A),
  'hysteria': Color(0xFFEC407A),
  'shadowsocks': Color(0xFF26A69A),
  'socks': Color(0xFF8D6E63),
  'http': Color(0xFF78909C),
  'tuic': Color(0xFF7E57C2),
};

/// Node selection: group filter chips (all / manual / each
/// subscription) over a card grid — name, protocol, latency,
/// selected check. Tapping a card selects the node; while the core
/// runs the shell also switches it live through the Clash API.
class NodesPage extends StatefulWidget {
  const NodesPage({
    super.key,
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
  });

  final List<NodeInfo> nodes;
  final List<Subscription> subscriptions;
  final int selectedIndex;
  final bool running;
  final bool busy;
  final Map<NodeInfo, int?> latency;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onDelete;
  final VoidCallback onImport;
  final VoidCallback onMeasureAll;

  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  String _query = '';

  /// '' = all groups; otherwise a subscription id, or '__manual'.
  String _group = '';

  @override
  Widget build(BuildContext context) {
    bool inGroup(NodeInfo n) {
      if (_group.isEmpty) return true;
      if (_group == '__manual') return n.source.isEmpty;
      return n.source == _group;
    }

    final visible = <int>[
      for (var i = 0; i < widget.nodes.length; i++)
        if (inGroup(widget.nodes[i]) &&
            (_query.isEmpty ||
                widget.nodes[i].name.toLowerCase().contains(_query) ||
                widget.nodes[i].server.toLowerCase().contains(_query)))
          i,
    ];
    final hasManual = widget.nodes.any((n) => n.source.isEmpty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Row(
            children: [
              Text('节点选择（${widget.nodes.length}）',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: widget.busy ? null : widget.onMeasureAll,
                icon: const Icon(Icons.speed, size: 18),
                label: const Text('测速全部'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: widget.busy || widget.running ? null : widget.onImport,
                icon: const Icon(Icons.add_link, size: 18),
                label: const Text('导入'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: '搜索节点名或服务器',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              ChoiceChip(
                label: const Text('全部'),
                selected: _group.isEmpty,
                onSelected: (_) => setState(() => _group = ''),
              ),
              if (hasManual)
                ChoiceChip(
                  label: const Text('手动导入'),
                  selected: _group == '__manual',
                  onSelected: (_) => setState(() => _group = '__manual'),
                ),
              for (final s in widget.subscriptions)
                ChoiceChip(
                  label: Text(s.name),
                  selected: _group == s.id,
                  onSelected: (_) => setState(() => _group = s.id),
                ),
            ],
          ),
        ),
        Expanded(
          child: widget.nodes.isEmpty
              ? const Center(child: Text('还没有节点，点右上角「导入」粘贴链接或订阅地址'))
              : visible.isEmpty
                  ? const Center(child: Text('这个分组里没有匹配的节点'))
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 300,
                        mainAxisExtent: 96,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                      ),
                      itemCount: visible.length,
                      itemBuilder: (context, vi) {
                        final i = visible[vi];
                        return _nodeCard(context, i, widget.nodes[i]);
                      },
                    ),
        ),
      ],
    );
  }

  Widget _nodeCard(BuildContext context, int index, NodeInfo node) {
    final scheme = Theme.of(context).colorScheme;
    final selected = index == widget.selectedIndex;
    final color = _protocolColors[node.protocol] ?? scheme.primary;
    final ms = widget.latency[node];
    final hasLatency = widget.latency.containsKey(node);
    return Card(
      margin: EdgeInsets.zero,
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.45) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? scheme.primary : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => widget.onSelect(index),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      node.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                      ),
                    ),
                  ),
                  if (selected)
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.green.shade400,
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(3),
                      child: const Icon(Icons.check, size: 13, color: Colors.black),
                    )
                  else
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 17),
                      tooltip: '删除',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed:
                          widget.running ? null : () => widget.onDelete(index),
                    ),
                ],
              ),
              const Spacer(),
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    node.protocol,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                  const Spacer(),
                  Text(
                    !hasLatency
                        ? '未测速'
                        : (ms == null ? '失败' : '$ms ms'),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: !hasLatency
                          ? scheme.onSurfaceVariant
                          : (ms == null ? scheme.error : Colors.greenAccent),
                    ),
                  ),
                ],
              ),
              Text(
                '${node.server}:${node.serverPort}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
