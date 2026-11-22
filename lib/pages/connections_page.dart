import 'package:flutter/material.dart';

import '../ui/design.dart';
import '../ui/runtime.dart';
import '../ui/diagnostics.dart';

class ConnectionsPage extends StatefulWidget {
  const ConnectionsPage({
    super.key,
    required this.monitor,
    required this.running,
    this.compact = false,
    this.processes = const [],
  });
  final List<String> processes;
  final RuntimeMonitor monitor;
  final bool running, compact;
  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<ConnectionsPage> {
  String _query = '', _network = '', _sort = 'download';
  bool _paused = false;
  List<Map<String, dynamic>> _snapshot = [];
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
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('关闭全部'),
            ),
          ],
        ),
      );
      if (yes != true || !mounted) return;
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
          final base = _paused ? _snapshot : monitor.connections;
          final rows = base.where((r) {
            final m = r['metadata'] as Map? ?? {};
            if (widget.processes.isNotEmpty &&
                !['processPath', 'process'].any((k) {
                  final exe = '${m[k] ?? ''}'
                      .split(RegExp(r'[\\/]'))
                      .last
                      .toLowerCase();
                  return widget.processes.any((p) => p.toLowerCase() == exe);
                })) return false;
            if (_network.isNotEmpty &&
                '${m['network']}'.toLowerCase() != _network) return false;
            return '${m['host']} ${m['destinationIP']} ${m['destinationPort']} ${m['processPath']} ${r['rule']} ${r['rulePayload']} ${r['chains']}'
                .toLowerCase()
                .contains(_query);
          }).toList();
          rows.sort(
            (a, b) => _sort == 'start'
                ? '${b['start'] ?? ''}'.compareTo('${a['start'] ?? ''}')
                : ((b[_sort] as num?) ?? 0).compareTo((a[_sort] as num?) ?? 0),
          );
          return Padding(
            padding: EdgeInsets.all(widget.compact ? 12 : 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!widget.compact)
                  PageHeading(
                    '请求',
                    '查看请求经过的规则与出口。',
                    eyebrow: 'EVERY CONNECTION HAS A PATH.',
                    actions: [
                      OutlinedButton.icon(
                        onPressed: widget.running ? monitor.sample : null,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('刷新'),
                      ),
                    ],
                  ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search, size: 17),
                          hintText: '搜索域名、IP、进程或规则',
                        ),
                        onChanged: (v) =>
                            setState(() => _query = v.toLowerCase()),
                      ),
                    ),
                    const SizedBox(width: 16),
                    if (!widget.compact)
                      Text(
                        '${monitor.available ? monitor.connections.length : 0} 个活动连接',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    const SizedBox(width: 12),
                    if (widget.processes.isEmpty)
                      OutlinedButton(
                        onPressed: widget.running &&
                                monitor.available &&
                                monitor.connections.isNotEmpty &&
                                !_closing
                            ? () => _close()
                            : null,
                        child: const Text('关闭全部'),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final entry in {
                      '': '全部协议',
                      'tcp': 'TCP',
                      'udp': 'UDP',
                    }.entries)
                      ChoiceChip(
                        label: Text(entry.value),
                        selected: _network == entry.key,
                        onSelected: (_) => setState(() => _network = entry.key),
                      ),
                    FilterChip(
                      label: Text(_paused ? '列表已暂停' : '暂停列表'),
                      selected: _paused,
                      onSelected: (value) => setState(() {
                        _paused = value;
                        if (value) _snapshot = List.of(monitor.connections);
                      }),
                    ),
                    PopupMenuButton<String>(
                      tooltip: '连接排序',
                      onSelected: (value) => setState(() => _sort = value),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                            value: 'download', child: Text('下载流量从高到低')),
                        PopupMenuItem(value: 'upload', child: Text('上传流量从高到低')),
                        PopupMenuItem(value: 'start', child: Text('最近建立优先')),
                      ],
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.sort, size: 17),
                            SizedBox(width: 6),
                            Text('排序'),
                          ],
                        ),
                      ),
                    ),
                    Text(
                      '显示 ${rows.length} / ${base.length}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _error!,
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                Expanded(
                  child: Panel(
                    padding: EdgeInsets.zero,
                    child: !widget.running
                        ? const EmptyView(
                            '当前没有活动连接',
                            '启动代理后，这里会显示真实请求。',
                            icon: Icons.monitor_heart_outlined,
                          )
                        : !monitor.available && !_paused
                            ? EmptyView('控制器暂不可达', monitor.error ?? '正在等待请求数据')
                            : rows.isEmpty
                                ? EmptyView(
                                    '没有匹配的连接',
                                    widget.processes.isEmpty
                                        ? '请求会在应用产生流量时自动出现。'
                                        : '等待软件产生可识别的新连接。内核未提供进程名的请求无法归属。')
                                : widget.compact
                                    ? ListView.builder(
                                        itemCount: rows.length,
                                        itemBuilder: (_, index) =>
                                            _compactRow(rows[index]),
                                      )
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
                                                '操作',
                                              ])
                                                DataColumn(
                                                  label: Text(
                                                    s,
                                                    style: const TextStyle(
                                                        fontSize: 11),
                                                  ),
                                                ),
                                            ],
                                            rows: [
                                              for (final r in rows)
                                                _row(context, r)
                                            ],
                                          ),
                                        ),
                                      ),
                  ),
                ),
              ],
            ),
          );
        },
      );
  void _details(Map<String, dynamic> row) {
    final meta = row['metadata'] as Map? ?? {};
    final values = {
      '目标':
          '${meta['host'] ?? meta['destinationIP'] ?? '未知'}:${meta['destinationPort'] ?? ''}',
      '协议': '${meta['network'] ?? '—'} / ${meta['type'] ?? '—'}',
      '来源': '${meta['sourceIP'] ?? '—'}:${meta['sourcePort'] ?? ''}',
      '进程': '${meta['processPath'] ?? meta['process'] ?? '未提供'}',
      '规则': '${row['rule'] ?? '—'} / ${row['rulePayload'] ?? ''}',
      '出口链路': (row['chains'] as List? ?? []).join(' → '),
      '建立时间': '${row['start'] ?? '—'}',
      '下载 / 上传':
          '${bytesLabel(row['download'] as num? ?? 0)} / ${bytesLabel(row['upload'] as num? ?? 0)}',
    };
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('连接详情'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: SelectableText(
              values.entries
                  .map((e) => '${e.key}\n${redactDiagnostics(e.value)}')
                  .join('\n\n'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _compactRow(Map<String, dynamic> row) {
    final meta = row['metadata'] as Map? ?? {};
    final host = '${meta['host'] ?? ''}'.isNotEmpty
        ? '${meta['host']}'
        : '${meta['destinationIP'] ?? '未知目标'}';
    return ListTile(
      title: Text(
        '$host:${meta['destinationPort'] ?? ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${meta['network'] ?? '—'} · ${row['rule'] ?? '—'} · ↓ ${bytesLabel(row['download'] as num? ?? 0)} ↑ ${bytesLabel(row['upload'] as num? ?? 0)}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => _details(row),
      trailing: IconButton(
        tooltip: '关闭此连接',
        onPressed: _closing || row['id'] == null || !widget.monitor.available
            ? null
            : () => _close('${row['id']}'),
        icon: const Icon(Icons.close, size: 18),
      ),
    );
  }

  DataRow _row(BuildContext context, Map<String, dynamic> r) {
    final meta = r['metadata'] as Map? ?? {};
    final host = '${meta['host'] ?? ''}'.isNotEmpty
        ? '${meta['host']}'
        : '${meta['destinationIP'] ?? '未知目标'}';
    final chains = (r['chains'] as List? ?? []).join(' → ');
    return DataRow(
      cells: [
        DataCell(
          SizedBox(
            width: 210,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$host:${meta['destinationPort'] ?? ''}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                Text(
                  '${meta['network'] ?? '—'} · ${meta['type'] ?? '—'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          onTap: () => _details(r),
        ),
        DataCell(
          SizedBox(
            width: 150,
            child: Text(
              '${r['rule'] ?? '—'}\n${r['rulePayload'] ?? ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ),
        DataCell(
          SizedBox(
            width: 180,
            child: Tooltip(
              message: chains,
              child: Text(
                chains.isEmpty ? '—' : chains,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
        ),
        DataCell(
          Text(
            '${bytesLabel(r['download'] as num? ?? 0)} / ${bytesLabel(r['upload'] as num? ?? 0)}',
            style: mono,
          ),
        ),
        DataCell(
          IconButton(
            tooltip: '关闭此连接',
            onPressed:
                _closing || r['id'] == null ? null : () => _close('${r['id']}'),
            icon: const Icon(Icons.close, size: 15),
          ),
        ),
      ],
    );
  }
}
