import 'package:flutter/material.dart';
import '../ui/design.dart';
import '../ui/runtime.dart';

class ConnectionsPage extends StatefulWidget {
  const ConnectionsPage(
      {super.key, required this.monitor, required this.running});
  final RuntimeMonitor monitor;
  final bool running;
  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<ConnectionsPage> {
  String _query = '';
  String? _error;
  bool _closing = false;
  Future<void> _close([String? id]) async {
    if (_closing) return;
    if (id == null) {
      final yes = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: const Text('关闭全部连接？'),
                  content: const Text('现有请求会被中断，应用可能会自动重新建立连接。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('关闭全部'))
                  ]));
      if (yes != true) return;
    }
    setState(() => _closing = true);
    try {
      await widget.monitor.closeConnections(id);
      if (mounted) setState(() => _error = null);
    } catch (_) {
      if (mounted) setState(() => _error = '关闭连接失败，请检查控制器状态。');
    } finally {
      if (mounted) setState(() => _closing = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.monitor,
      builder: (context, _) {
        final monitor = widget.monitor;
        final rows = monitor.connections.where((r) {
          final m = r['metadata'] as Map? ?? {};
          return '${m['host']} ${m['destinationIP']} ${m['processPath']} ${r['rule']}'
              .toLowerCase()
              .contains(_query);
        }).toList();
        return Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PageHeading('请求', '查看请求经过的规则与出口。',
                      eyebrow: 'EVERY CONNECTION HAS A PATH.',
                      actions: [
                        OutlinedButton.icon(
                            onPressed: widget.running ? monitor.sample : null,
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text('刷新'))
                      ]),
                  Row(children: [
                    Expanded(
                        child: TextField(
                            decoration: const InputDecoration(
                                prefixIcon: Icon(Icons.search, size: 17),
                                hintText: '搜索域名、IP、进程或规则'),
                            onChanged: (v) =>
                                setState(() => _query = v.toLowerCase()))),
                    const SizedBox(width: 16),
                    Text(
                        '${monitor.available ? monitor.connections.length : 0} 个活动连接',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(width: 12),
                    OutlinedButton(
                        onPressed: widget.running &&
                                monitor.available &&
                                monitor.connections.isNotEmpty &&
                                !_closing
                            ? () => _close()
                            : null,
                        child: const Text('关闭全部'))
                  ]),
                  const SizedBox(height: 14),
                  if (_error != null)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(_error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error))),
                  Expanded(
                      child: Panel(
                          padding: EdgeInsets.zero,
                          child: !widget.running
                              ? const EmptyView('当前没有活动连接', '启动代理后，这里会显示真实请求。',
                                  icon: Icons.monitor_heart_outlined)
                              : !monitor.available
                                  ? EmptyView(
                                      '控制器暂不可达', monitor.error ?? '正在等待请求数据')
                                  : rows.isEmpty
                                      ? const EmptyView(
                                          '没有匹配的连接', '请求会在应用产生流量时自动出现。')
                                      : SingleChildScrollView(
                                          child: SingleChildScrollView(
                                              scrollDirection: Axis.horizontal,
                                              child: DataTable(
                                                  headingRowHeight: 42,
                                                  dataRowMinHeight: 54,
                                                  dataRowMaxHeight: 64,
                                                  columnSpacing: 20,
                                                  columns: [
                                                    for (final s in [
                                                      '目标',
                                                      '匹配规则',
                                                      '出口',
                                                      '下载 / 上传',
                                                      '操作'
                                                    ])
                                                      DataColumn(
                                                          label: Text(s,
                                                              style:
                                                                  const TextStyle(
                                                                      fontSize:
                                                                          11)))
                                                  ],
                                                  rows: [
                                                    for (final r in rows)
                                                      _row(context, r)
                                                  ])))))
                ]));
      });
  DataRow _row(BuildContext context, Map<String, dynamic> r) {
    final meta = r['metadata'] as Map? ?? {};
    final host = '${meta['host'] ?? ''}'.isNotEmpty
        ? '${meta['host']}'
        : '${meta['destinationIP'] ?? '未知目标'}';
    final chains = (r['chains'] as List? ?? []).join(' → ');
    return DataRow(cells: [
      DataCell(SizedBox(
          width: 210,
          child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$host:${meta['destinationPort'] ?? ''}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12)),
                Text('${meta['network'] ?? '—'} · ${meta['type'] ?? '—'}',
                    style: Theme.of(context).textTheme.bodySmall)
              ]))),
      DataCell(SizedBox(
          width: 150,
          child: Text('${r['rule'] ?? '—'}\n${r['rulePayload'] ?? ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11)))),
      DataCell(SizedBox(
          width: 180,
          child: Tooltip(
              message: chains,
              child: Text(chains.isEmpty ? '—' : chains,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11))))),
      DataCell(Text(
          '${bytesLabel(r['download'] as num? ?? 0)} / ${bytesLabel(r['upload'] as num? ?? 0)}',
          style: mono)),
      DataCell(IconButton(
          tooltip: '关闭此连接',
          onPressed:
              _closing || r['id'] == null ? null : () => _close('${r['id']}'),
          icon: const Icon(Icons.close, size: 15)))
    ]);
  }
}
