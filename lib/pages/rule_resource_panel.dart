import 'dart:io';
import 'package:flutter/material.dart';
import '../services/rule_resources.dart';
import '../services/store.dart';
import '../ui/design.dart';

class RuleResourcePanel extends StatelessWidget {
  const RuleResourcePanel(
      {super.key,
      required this.catalog,
      required this.data,
      required this.dataDir,
      required this.busy,
      required this.onSettings,
      required this.onUpdate});
  final List<RuleResource> catalog;
  final AppData data;
  final String dataDir;
  final bool busy;
  final Future<void> Function(AppData Function(AppData)) onSettings;
  final Future<void> Function(RuleResource) onUpdate;

  Future<void> edit(BuildContext context, RuleResource item) async {
    final controller =
        TextEditingController(text: data.ruleSetUrls[item.tag] ?? '');
    try {
      final value = await showDialog<String>(
          context: context,
          builder: (dialog) {
            String? error;
            return StatefulBuilder(
                builder: (_, setDialogState) => AlertDialog(
                      title: Text('编辑 ${item.tag} 的源'),
                      content: SizedBox(
                          width: 540,
                          child: TextField(
                              controller: controller,
                              decoration: InputDecoration(
                                  labelText: 'HTTPS 源地址',
                                  helperText: '留空恢复默认源，保存后需手动点更新。',
                                  errorText: error))),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(dialog),
                            child: const Text('取消')),
                        FilledButton(
                            onPressed: () {
                              final url = controller.text.trim();
                              try {
                                validateRuleResourceUrl(url);
                                Navigator.pop(dialog, url);
                              } on FormatException catch (e) {
                                setDialogState(() => error = e.message);
                              }
                            },
                            child: const Text('保存'))
                      ],
                    ));
          });
      if (value == null || !context.mounted) return;
      await onSettings((next) {
        final old = next.ruleSetUrls[item.tag] ?? '';
        if (value != old) {
          if (value.isEmpty) {
            next.ruleSetUrls.remove(item.tag);
          } else {
            next.ruleSetUrls[item.tag] = value;
          }
          next.ruleSetPending.add(item.tag);
        }
        return next;
      });
    } finally {
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Card(
          child: ExpansionTile(
        leading: const Icon(Icons.inventory_2_outlined),
        title: const Text('规则集资源'),
        subtitle: const Text('3 个核心规则集 · 14 个可选规则集'),
        childrenPadding: const EdgeInsets.all(12),
        children: [
          SwitchListTile(
            title: const Text('启动内核时检查更新'),
            subtitle: const Text('每 24 小时更新已下载规则集。改过地址的规则集需先手动更新。'),
            value: data.ruleSetAutoUpdate,
            onChanged: busy
                ? null
                : (value) =>
                    onSettings((next) => next..ruleSetAutoUpdate = value),
          ),
          ListTile(
            title: const Text('分流预设'),
            subtitle: const Text('下次启动内核生效。流媒体和 AI 预设只引用已下载的对应规则集。'),
            trailing: DropdownButton<String>(
                value: routingPresets.containsKey(data.routingPreset)
                    ? data.routingPreset
                    : 'balanced',
                items: routingPresets.entries
                    .map((e) =>
                        DropdownMenuItem(value: e.key, child: Text(e.value)))
                    .toList(),
                onChanged: busy
                    ? null
                    : (value) {
                        if (value != null)
                          onSettings((next) => next..routingPreset = value);
                      }),
          ),
          for (final group in catalog.map((e) => e.group).toSet())
            ExpansionTile(
                title: Text(group),
                initiallyExpanded: group == '核心',
                children: [
                  for (final item in catalog.where((r) => r.group == group))
                    _row(context, item)
                ]),
          if (busy) const LinearProgressIndicator(),
        ],
      ));

  Widget _row(BuildContext context, RuleResource item) {
    final stat = File(item.path(dataDir)).statSync();
    final exists = stat.type == FileSystemEntityType.file;
    final url = data.ruleSetUrls[item.tag] ?? item.url;
    final status = exists
        ? '${bytesLabel(stat.size)} · ${stat.modified.toLocal().toString().substring(0, 16)}'
        : item.group == '核心'
            ? '未就绪'
            : '未下载';
    return ListTile(
      title: Text(item.tag),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
            '${data.ruleSetPending.contains(item.tag) ? '待更新 · ' : ''}$status'),
        Tooltip(
            message: url,
            child: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis)),
      ]),
      trailing: Wrap(spacing: 4, children: [
        IconButton(
            tooltip: '编辑源',
            onPressed: busy ? null : () => edit(context, item),
            icon: const Icon(Icons.edit_outlined)),
        OutlinedButton(
            onPressed: busy ? null : () => onUpdate(item),
            child: Text(exists ? '更新' : '下载')),
      ]),
    );
  }
}
