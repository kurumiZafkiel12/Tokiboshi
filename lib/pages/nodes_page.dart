import 'package:flutter/material.dart';

import '../bridge/core_bridge.dart';
import '../services/store.dart';

const _protocolColors = <String, Color>{
  'vless': Color(0xFF42A5F5),
  'vmess': Color(0xFFAB47BC),
  'trojan': Color(0xFFFF7043),
  'hysteria2': Color(0xFFEC407A),
  'shadowsocks': Color(0xFF26A69A),
};

/// Node list grouped by source (manual import / each subscription),
/// with search and TCP latency results.
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subNames = {for (final s in widget.subscriptions) s.id: s.name};
    final visible = <int>[
      for (var i = 0; i < widget.nodes.length; i++)
        if (_query.isEmpty ||
            widget.nodes[i].name.toLowerCase().contains(_query) ||
            widget.nodes[i].server.toLowerCase().contains(_query))
          i,
    ];
    final groups = <String, List<int>>{};
    for (final i in visible) {
      groups.putIfAbsent(widget.nodes[i].source, () => []).add(i);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Row(
            children: [
              Text('节点（${widget.nodes.length}）',
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
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
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
        Expanded(
          child: widget.nodes.isEmpty
              ? const Center(child: Text('还没有节点，点右上角「导入」粘贴链接或订阅地址'))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                  children: [
                    for (final entry in groups.entries) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                        child: Text(
                          entry.key.isEmpty
                              ? '手动导入'
                              : '订阅 · ${subNames[entry.key] ?? entry.key}',
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      for (final i in entry.value)
                        _nodeCard(context, i, widget.nodes[i]),
                    ],
                  ],
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
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? scheme.primary : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: widget.running ? null : () => widget.onSelect(index),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  node.protocol.toUpperCase(),
                  style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      node.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    Text(
                      '${node.server}:${node.serverPort}',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (hasLatency)
                Text(
                  ms == null ? '超时' : '$ms ms',
                  style: TextStyle(
                    fontSize: 12,
                    color: ms == null ? scheme.error : Colors.greenAccent,
                  ),
                ),
              if (selected)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(Icons.check_circle, size: 18, color: scheme.primary),
                ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 19),
                tooltip: '删除',
                onPressed: widget.running ? null : () => widget.onDelete(index),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
