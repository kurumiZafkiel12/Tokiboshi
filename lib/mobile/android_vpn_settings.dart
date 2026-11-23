import 'package:flutter/material.dart';

import 'android_bridge.dart';
import 'android_controller.dart';

class AndroidVpnSettings extends StatelessWidget {
  const AndroidVpnSettings({super.key, required this.controller});

  final AndroidController controller;

  Future<void> _perform(
      BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作失败，请检查当前 VPN 状态后重试。')),
        );
      }
    }
  }

  Future<void> _pickApps(BuildContext context, {bool include = false}) async {
    final apps = await androidVpnChannel.invokeListMethod<dynamic>('vpnApps');
    if (!context.mounted) return;
    final selected = (include
            ? controller.data.androidIncludedApps ?? []
            : controller.data.androidExcludedApps)
        .toSet();
    String query = '';
    final labels = <String, String>{
      for (final app in apps ?? []) app['id'] as String: app['name'] as String,
    };
    for (final id in selected) {
      labels.putIfAbsent(id, () => id);
    }
    final entries = labels.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final result = await showDialog<List<String>>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (_, update) {
          final visible = entries
              .where((app) =>
                  '${app.value} ${app.key}'.toLowerCase().contains(query))
              .toList();
          return AlertDialog(
            title: Text(include ? '仅所选应用通过 VPN' : '选择绕过 VPN 的应用'),
            content: SizedBox(
              width: 360,
              height: 320,
              child: Column(children: [
                TextField(
                  decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search), hintText: '搜索应用或包名'),
                  onChanged: (text) =>
                      update(() => query = text.trim().toLowerCase()),
                ),
                const SizedBox(height: 8),
                Expanded(
                    child: visible.isEmpty
                        ? const Center(child: Text('没有匹配的应用'))
                        : ListView.builder(
                            itemCount: visible.length,
                            itemBuilder: (_, i) {
                              final app = visible[i];
                              return CheckboxListTile(
                                title: Text(app.value),
                                subtitle: Text(app.key),
                                value: selected.contains(app.key),
                                onChanged: (value) => update(() {
                                  if (value == true) {
                                    selected.add(app.key);
                                  } else {
                                    selected.remove(app.key);
                                  }
                                }),
                              );
                            },
                          )),
              ]),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialog),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: include && selected.isEmpty
                      ? null
                      : () => Navigator.pop(dialog, selected.toList()),
                  child: const Text('保存')),
            ],
          );
        },
      ),
    );
    if (result != null && context.mounted) {
      await controller.saveVpnSettings(
        includedApps: include ? result : null,
        excludedApps: include ? null : result,
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Android VPN 设置')),
        body: SafeArea(
          child: ListenableBuilder(
            listenable: controller,
            builder: (_, __) => ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ListTile(
                  title: const Text('排除应用'),
                  subtitle: Text(controller.data.androidIncludedApps != null
                      ? '未启用'
                      : '已选 ${controller.data.androidExcludedApps.length} 个应用绕过 VPN'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: controller.busy
                      ? null
                      : () => _perform(context, () => _pickApps(context)),
                ),
                ListTile(
                  title: const Text('仅指定应用使用 VPN'),
                  subtitle: Text(controller.data.androidIncludedApps == null
                      ? '未启用'
                      : '已启用 · ${controller.data.androidIncludedApps!.length} 个应用'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: controller.busy
                      ? null
                      : () => _perform(
                          context, () => _pickApps(context, include: true)),
                ),
                if (controller.data.androidIncludedApps != null ||
                    controller.data.androidExcludedApps.isNotEmpty)
                  ListTile(
                    title: const Text('恢复所有应用使用 VPN'),
                    onTap: controller.busy
                        ? null
                        : () => _perform(context,
                            () => controller.saveVpnSettings(allApps: true)),
                  ),
                ListTile(
                  title: const Text('网卡 MTU'),
                  subtitle: const Text('默认 1500'),
                  trailing: DropdownButton<int>(
                    value: controller.data.androidMtu,
                    items: const [1500, 1400, 1280]
                        .map((value) => DropdownMenuItem(
                            value: value, child: Text('$value')))
                        .toList(),
                    onChanged: controller.busy
                        ? null
                        : (value) => _perform(context,
                            () => controller.saveVpnSettings(mtu: value)),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                      '应用范围与 MTU 在下次连接时生效。开启系统的「阻止不使用 VPN 的连接」时，范围外的应用可能无法联网。'),
                ),
                const Divider(),
                ListTile(
                  title: const Text('添加快捷设置磁贴'),
                  subtitle: const Text('下拉控制中心可连接或断开 VPN'),
                  trailing: const Icon(Icons.add_to_home_screen),
                  onTap: () => _perform(context, () async {
                    final result = await androidVpnChannel
                        .invokeMethod<int>('addQuickTile');
                    if (result == null && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('请在系统快捷设置的编辑页，将 Tokiboshi 拉到已启用区域。'),
                      ));
                    }
                  }),
                ),
                for (final entry in {
                  'vpnSettings': '系统 VPN 设置',
                  'notificationSettings': 'VPN 通知设置'
                }.entries)
                  ListTile(
                    title: Text(entry.value),
                    trailing: const Icon(Icons.open_in_new),
                    onTap: () => _perform(context,
                        () => androidVpnChannel.invokeMethod<void>(entry.key)),
                  ),
              ],
            ),
          ),
        ),
      );
}
