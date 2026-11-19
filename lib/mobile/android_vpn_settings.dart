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

  Future<void> _pickApps(BuildContext context) async {
    final apps = await androidVpnChannel.invokeListMethod<dynamic>('vpnApps');
    if (!context.mounted) return;
    final selected = controller.data.androidExcludedApps.toSet();
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
        builder: (_, update) => AlertDialog(
          title: const Text('选择绕过 VPN 的应用'),
          content: SizedBox(
            width: 360,
            height: 320,
            child: entries.isEmpty
                ? const Center(child: Text('没有可选应用'))
                : ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (_, i) {
                      final app = entries[i];
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
                  ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(dialog, selected.toList()),
                child: const Text('保存')),
          ],
        ),
      ),
    );
    if (result != null && context.mounted) {
      await controller.saveVpnSettings(excludedApps: result);
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
                  subtitle: Text(
                      '已选 ${controller.data.androidExcludedApps.length} 个应用绕过 VPN'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: controller.busy
                      ? null
                      : () => _perform(context, () => _pickApps(context)),
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
                  child:
                      Text('MTU 和排除应用在下次连接时生效。若系统禁止未通过 VPN 的连接，被排除的应用可能无法联网。'),
                ),
                const Divider(),
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
