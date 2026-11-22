import 'dart:convert';
import 'package:flutter/material.dart';
import '../bridge/core_bridge.dart';
import '../services/store.dart';
import 'design.dart';
import 'preferences.dart';

String sourceLabel(NodeInfo node, List<Subscription> subscriptions) {
  final sources = subscriptions.where((s) => s.id == node.source);
  final source = sources.isEmpty
      ? (node.source.isEmpty ? '本地导入' : '未知来源')
      : sources.first.name;
  return node.group.isEmpty ? source : '$source / ${node.group}';
}

final _regionalFlags = RegExp(r'[\u{1F1E6}-\u{1F1FF}]{2}', unicode: true);

String nodeDisplayName(NodeInfo node) {
  final name = node.name.replaceAll(_regionalFlags, '').trim();
  return name.isEmpty ? regionLabel(node) : name;
}

String regionLabel(NodeInfo node) {
  const regionalStart = 0x1f1e6;
  final runes = node.name.runes.toList();
  for (var i = 0; i + 1 < runes.length; i++) {
    final first = runes[i] - regionalStart,
        second = runes[i + 1] - regionalStart;
    if (first >= 0 && first < 26 && second >= 0 && second < 26) {
      return String.fromCharCodes([first + 65, second + 65]);
    }
  }
  final name = node.name.toUpperCase();
  for (final pair in const [
    ('日本', 'JP'),
    ('东京', 'JP'),
    ('大阪', 'JP'),
    ('JAPAN', 'JP'),
    ('🇯🇵', 'JP'),
    ('香港', 'HK'),
    ('🇭🇰', 'HK'),
    ('新加坡', 'SG'),
    ('SINGAPORE', 'SG'),
    ('🇸🇬', 'SG'),
    ('美国', 'US'),
    ('🇺🇸', 'US'),
    ('台湾', 'TW'),
    ('🇹🇼', 'TW'),
    ('韩国', 'KR'),
    ('🇰🇷', 'KR'),
    ('德国', 'DE'),
    ('🇩🇪', 'DE'),
    ('英国', 'GB'),
    ('🇬🇧', 'GB')
  ]) {
    if (name.contains(pair.$1)) return pair.$2;
  }
  final match = RegExp(r'(^|[^A-Z])(JP|HK|SG|US|TW|KR|DE|GB|AU|CA)([^A-Z]|$)')
      .firstMatch(name);
  return match?.group(2) ?? (node.isPolicy ? '组' : '·');
}

class RegionMark extends StatelessWidget {
  const RegionMark(this.node, {super.key});
  final NodeInfo node;
  @override
  Widget build(BuildContext context) {
    final code = regionLabel(node);
    final fallback = Text(code,
        style: mono.copyWith(
            color: Theme.of(context).colorScheme.primary, fontSize: 11));
    return Container(
        width: 31,
        height: 29,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(7)),
        child: code.length != 2
            ? fallback
            : Image.asset('assets/flags/$code.png',
                width: 20,
                height: 20,
                semanticLabel: '地区 $code',
                errorBuilder: (_, __, ___) => fallback));
  }
}

class LatencyText extends StatelessWidget {
  const LatencyText(this.node, this.latency, {super.key});
  final NodeInfo node;
  final Map<NodeInfo, int?> latency;
  @override
  Widget build(BuildContext context) {
    final measured = latency.containsKey(node);
    final ms = latency[node];
    return Text(
        !measured
            ? '未测速'
            : ms == null
                ? '超时'
                : '$ms ms',
        style: mono.copyWith(
            color: !measured
                ? Theme.of(context).colorScheme.onSurfaceVariant
                : ms == null
                    ? Theme.of(context).colorScheme.error
                    : ms < 200
                        ? good
                        : gold));
  }
}

Future<void> showNodeDetails(BuildContext context, NodeInfo node,
        List<Subscription> subscriptions, Map<NodeInfo, int?> latency,
        {VoidCallback? onSelect,
        VoidCallback? onMeasure,
        VoidCallback? onQuality,
        VoidCallback? onDelete}) =>
    showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: '关闭节点详情',
        barrierColor: Colors.black54,
        transitionDuration: UiScope.duration(context, 280),
        transitionBuilder: (context, a, secondary, child) => SlideTransition(
            position: Tween(begin: const Offset(1, 0), end: Offset.zero)
                .animate(
                    CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
            child: child),
        pageBuilder: (context, _, __) => Align(
            alignment: Alignment.centerRight,
            child: Material(
                color: Theme.of(context).colorScheme.surface,
                child: SizedBox(
                    width: 430,
                    child: SafeArea(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                          Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(24, 18, 12, 18),
                              child: Row(children: [
                                const Expanded(
                                    child: Text('节点详情',
                                        style: TextStyle(
                                            fontSize: 17,
                                            fontWeight: FontWeight.w600))),
                                IconButton(
                                    tooltip: '关闭详情',
                                    onPressed: () => Navigator.pop(context),
                                    icon: const Icon(Icons.close))
                              ])),
                          Divider(
                              height: 1, color: Theme.of(context).dividerColor),
                          Expanded(
                              child: SingleChildScrollView(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        RegionMark(node),
                                        const SizedBox(height: 16),
                                        Text(nodeDisplayName(node),
                                            style: const TextStyle(
                                                fontSize: 23,
                                                fontWeight: FontWeight.w600)),
                                        const SizedBox(height: 10),
                                        Tag(node.protocol.toUpperCase(),
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary),
                                        const SizedBox(height: 28),
                                        for (final pair in [
                                          (
                                            '来源',
                                            sourceLabel(node, subscriptions)
                                          ),
                                          (
                                            '服务器',
                                            node.server.isEmpty
                                                ? '策略组'
                                                : node.server
                                          ),
                                          (
                                            '端口',
                                            node.serverPort == 0
                                                ? '—'
                                                : '${node.serverPort}'
                                          ),
                                          (
                                            '类型',
                                            node.isPolicy ? '策略组' : '代理节点'
                                          ),
                                          (
                                            '测速状态',
                                            latency.containsKey(node)
                                                ? latency[node] == null
                                                    ? '超时'
                                                    : '${latency[node]} ms'
                                                : '未测速'
                                          )
                                        ]) ...[
                                          Text(pair.$1,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall),
                                          const SizedBox(height: 6),
                                          SelectableText(pair.$2),
                                          const SizedBox(height: 21)
                                        ],
                                        const Text('凭据默认隐藏。详情不展示密码、UUID 或完整配置。',
                                            style: TextStyle(fontSize: 11)),
                                      ]))),
                          Padding(
                              padding: const EdgeInsets.all(20),
                              child: Wrap(spacing: 8, runSpacing: 8, children: [
                                if (onSelect != null)
                                  FilledButton(
                                      onPressed: () {
                                        Navigator.pop(context);
                                        onSelect();
                                      },
                                      child: const Text('选择此节点')),
                                if (onMeasure != null)
                                  OutlinedButton(
                                      onPressed: () {
                                        Navigator.pop(context);
                                        onMeasure();
                                      },
                                      child: const Text('测试延迟')),
                                if (onQuality != null)
                                  OutlinedButton(
                                      onPressed: () {
                                        Navigator.pop(context);
                                        onQuality();
                                      },
                                      child: const Text('查看节点质量')),
                                if (onDelete != null)
                                  TextButton(
                                      onPressed: () {
                                        Navigator.pop(context);
                                        onDelete();
                                      },
                                      child: Text('删除节点',
                                          style: TextStyle(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .error))),
                              ]))
                        ]))))));


/// 编辑手动导入的节点（订阅节点随订阅更新，不允许本地编辑）。
/// 返回更新后的 NodeInfo；取消返回 null。
Future<NodeInfo?> showNodeEditor(BuildContext context, NodeInfo node) async {
  Map<String, dynamic> ob;
  try {
    ob = jsonDecode(node.outboundJson) as Map<String, dynamic>;
  } catch (_) {
    await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
            title: const Text('无法编辑'),
            content: const Text('该节点的出站配置无法解析（非 JSON）。'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'))
            ]));
    return null;
  }
  final name = TextEditingController(text: nodeDisplayName(node));
  final server = TextEditingController(text: '${ob['server'] ?? ''}');
  final port = TextEditingController(text: '${ob['server_port'] ?? ''}');
  final secret = TextEditingController(
      text: '${ob['password'] ?? ob['uuid'] ?? ob['psk'] ?? ''}');
  final sniKey = ob['tls'] is Map && (ob['tls'] as Map)['sni'] != null
      ? 'sni'
      : (ob['tls'] is Map && (ob['tls'] as Map)['server_name'] != null
          ? 'server_name'
          : null);
  final sni = TextEditingController(
      text: sniKey == null
          ? ''
          : '${(ob['tls'] as Map)[sniKey] ?? ''}');
  final hasSecret =
      ob.containsKey('password') || ob.containsKey('uuid') || ob.containsKey('psk');
  final secretLabel = ob.containsKey('uuid')
      ? 'UUID'
      : ob.containsKey('psk')
          ? 'PSK'
          : '密码';
  String error = '';

  return showDialog<NodeInfo>(
      context: context,
      barrierDismissible: false,
      builder: (dialog) => StatefulBuilder(builder: (dialog, setState) {
            Widget field(String label, TextEditingController c,
                    {bool obscure = false}) =>
                Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                        controller: c,
                        obscureText: obscure,
                        decoration: InputDecoration(
                            labelText: label,
                            border: const OutlineInputBorder(),
                            isDense: true)));
            return AlertDialog(
                title: const Text('编辑节点'),
                content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  field('名称', name),
                  Row(children: [
                    Expanded(flex: 3, child: field('服务器', server)),
                    const SizedBox(width: 10),
                    Expanded(child: field('端口', port)),
                  ]),
                  if (hasSecret) field(secretLabel, secret, obscure: true),
                  if (sniKey != null) field('SNI', sni),
                  if (error.isNotEmpty)
                    Text(error,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 12)),
                  const Text('仅手动导入的节点可编辑；订阅节点随订阅更新。',
                      style: TextStyle(fontSize: 11)),
                ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () {
                        final sv = server.text.trim();
                        final pt = int.tryParse(port.text.trim());
                        if (sv.isEmpty || pt == null || pt <= 0 || pt > 65535) {
                          error = '服务器与端口无效（端口 1–65535）');
                          return;
                        }
                        if (name.text.trim().isEmpty) {
                          error = '名称不能为空';
                          return;
                        }
                        ob['server'] = sv;
                        ob['server_port'] = pt;
                        if (hasSecret && secret.text.isNotEmpty) {
                          final key = ob.containsKey('uuid')
                              ? 'uuid'
                              : ob.containsKey('psk')
                                  ? 'psk'
                                  : 'password';
                          ob[key] = secret.text.trim();
                        }
                        if (sniKey != null && sni.text.trim().isNotEmpty) {
                          (ob['tls'] as Map)[sniKey] = sni.text.trim();
                        }
                        if (ob.containsKey('tag')) ob['tag'] = name.text.trim();
                        Navigator.pop(
                            dialog,
                            NodeInfo(
                                name: name.text.trim(),
                                outboundJson: jsonEncode(ob),
                                source: node.source,
                                group: node.group));
                      },
                      child: const Text('保存')),
                ]);
          }));
}

class NodePicker extends StatefulWidget {
  const NodePicker(
      {super.key,
      required this.nodes,
      required this.subscriptions,
      required this.selectedIndex,
      required this.latency,
      required this.onSelect,
      required this.onManage,
      required this.onMeasure,
      this.busy = false,
      this.requiredSource});
  final List<NodeInfo> nodes;
  final List<Subscription> subscriptions;
  final int selectedIndex;
  final Map<NodeInfo, int?> latency;
  final ValueChanged<int> onSelect;
  final VoidCallback onManage;
  final Future<void> Function() onMeasure;
  final bool busy;
  final String? requiredSource;
  @override
  State<NodePicker> createState() => _NodePickerState();
}

class _NodePickerState extends State<NodePicker> {
  String _query = '', _source = '';
  bool _sort = false, _measuring = false;
  final _search = TextEditingController();
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final indices = [
      for (var i = 0; i < widget.nodes.length; i++)
        if ((widget.requiredSource == null ||
                widget.nodes[i].source == widget.requiredSource) &&
            (_source.isEmpty ||
                (_source == '__local'
                    ? widget.nodes[i].source.isEmpty
                    : widget.nodes[i].source == _source)) &&
            '${widget.nodes[i].name} ${regionLabel(widget.nodes[i])} ${widget.nodes[i].protocol} ${sourceLabel(widget.nodes[i], widget.subscriptions)}'
                .toLowerCase()
                .contains(_query))
          i
    ];
    if (_sort)
      indices.sort((a, b) => (widget.latency[widget.nodes[a]] ?? 0x7fffffff)
          .compareTo(widget.latency[widget.nodes[b]] ?? 0x7fffffff));
    return Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
            width: 760,
            height: 560,
            child: Column(children: [
              Padding(
                  padding: const EdgeInsets.fromLTRB(22, 18, 12, 12),
                  child: Row(children: [
                    const Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text('选择出口节点',
                              style: TextStyle(
                                  fontSize: 19, fontWeight: FontWeight.w600)),
                          SizedBox(height: 5),
                          Text('运行时选择后立即切换；停止时保存选择',
                              style: TextStyle(fontSize: 11))
                        ])),
                    IconButton(
                        tooltip: '关闭节点选择',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close))
                  ])),
              Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(children: [
                    SizedBox(
                        width: 150,
                        child: DropdownButtonFormField<String>(
                            key: ValueKey(_source),
                            initialValue: _source,
                            isExpanded: true,
                            decoration: const InputDecoration(
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 10)),
                            items: [
                              const DropdownMenuItem(
                                  value: '',
                                  child: Text('全部来源',
                                      style: TextStyle(fontSize: 12))),
                              const DropdownMenuItem(
                                  value: '__local',
                                  child: Text('本地导入',
                                      style: TextStyle(fontSize: 12))),
                              for (final sub in widget.subscriptions)
                                DropdownMenuItem(
                                    value: sub.id,
                                    child: Text(sub.name,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 12)))
                            ],
                            onChanged: (v) =>
                                setState(() => _source = v ?? ''))),
                    const SizedBox(width: 10),
                    Expanded(
                        child: TextField(
                            controller: _search,
                            autofocus: true,
                            decoration: const InputDecoration(
                                prefixIcon: Icon(Icons.search, size: 17),
                                hintText: '搜索名称、地区、协议'),
                            onChanged: (v) =>
                                setState(() => _query = v.toLowerCase()))),
                    IconButton(
                        tooltip: '测速全部',
                        onPressed: widget.busy || _measuring
                            ? null
                            : () async {
                                setState(() => _measuring = true);
                                try {
                                  await widget.onMeasure();
                                } finally {
                                  if (mounted)
                                    setState(() => _measuring = false);
                                }
                              },
                        icon: const Icon(Icons.speed))
                  ])),
              Padding(
                  padding: const EdgeInsets.fromLTRB(22, 14, 20, 8),
                  child: Row(children: [
                    Expanded(
                        child: Text('节点 / 来源  ${indices.length}',
                            style: Theme.of(context).textTheme.bodySmall)),
                    TextButton(
                        onPressed: () => setState(() => _sort = !_sort),
                        child: Text(_sort ? '延迟 ↑' : '延迟 ↕'))
                  ])),
              const Divider(height: 1),
              Expanded(
                  child: indices.isEmpty
                      ? EmptyView('没有匹配节点', '请调整筛选，或先导入订阅',
                          action: TextButton(
                              onPressed: () {
                                _search.clear();
                                setState(() {
                                  _query = '';
                                  _source = '';
                                });
                              },
                              child: const Text('清除筛选')))
                      : ListView.builder(
                          itemCount: indices.length,
                          itemBuilder: (context, row) {
                            final i = indices[row], node = widget.nodes[i];
                            return ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 22, vertical: 3),
                                leading: RegionMark(node),
                                title: Text(nodeDisplayName(node),
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13)),
                                subtitle: Text(
                                    '${node.protocol.toUpperCase()} · ${sourceLabel(node, widget.subscriptions)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 10)),
                                trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      LatencyText(node, widget.latency),
                                      const SizedBox(width: 16),
                                      Icon(
                                          i == widget.selectedIndex
                                              ? Icons.check_circle
                                              : Icons.circle_outlined,
                                          size: 17,
                                          color: i == widget.selectedIndex
                                              ? Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                              : null)
                                    ]),
                                selected: i == widget.selectedIndex,
                                onTap: widget.busy
                                    ? null
                                    : () {
                                        Navigator.pop(context);
                                        widget.onSelect(i);
                                      });
                          })),
              const Divider(height: 1),
              Padding(
                  padding: const EdgeInsets.fromLTRB(22, 10, 22, 10),
                  child: Row(children: [
                    Text('${indices.length} 个节点与策略',
                        style: Theme.of(context).textTheme.bodySmall),
                    const Spacer(),
                    TextButton(
                        onPressed: () {
                          Navigator.pop(context);
                          widget.onManage();
                        },
                        child: const Text('完整节点管理 ↗'))
                  ]))
            ])));
  }
}
