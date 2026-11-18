import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_version.dart';
import '../services/client_preferences.dart';
import '../ui/client_settings.dart';
import '../ui/shell_widgets.dart';
import '../ui/design.dart';
import '../ui/general_settings.dart';
import '../services/desktop_settings.dart';

/// Settings: local port, sing-box path, system proxy, about.
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.mixedPort,
    required this.clashApiPort,
    required this.singBoxPath,
    required this.systemProxy,
    this.autoConnect = true,
    this.onAutoConnectChanged,
    required this.running,
    required this.dataFilePath,
    required this.onSave,
    required this.onSystemProxyChanged,
    this.coreVersion,
    this.onEnsureCore,
    this.blockAds = true,
    this.bypassCn = true,
    this.onBlockAdsChanged,
    this.onBypassCnChanged,
    this.desktop = const DesktopSettings(),
    this.onDesktopChanged,
    this.settingsBusy = false,
    this.onCheckUpdate,
    this.onOpenUpdate,
    this.updateStatus,
    this.checkingUpdate = false,
    this.onCopyControllerSecret,
    this.client = const ClientPreferences(),
    this.onClientSave,
    this.onBackup,
    this.onRestore,
    this.initialSection = 0,
  });

  final int initialSection;
  final ClientPreferences client;
  final Future<void> Function(ClientPreferences)? onClientSave;
  final VoidCallback? onBackup, onRestore;
  final int mixedPort;
  final int clashApiPort;
  final String singBoxPath;
  final bool systemProxy;
  final bool autoConnect;
  final ValueChanged<bool>? onAutoConnectChanged;
  final bool running;
  final String dataFilePath;
  final void Function(int port, int clashApiPort, String singBoxPath) onSave;
  final ValueChanged<bool> onSystemProxyChanged;
  final String? coreVersion;
  final VoidCallback? onEnsureCore;
  final bool blockAds;
  final bool bypassCn;
  final ValueChanged<bool>? onBlockAdsChanged;
  final ValueChanged<bool>? onBypassCnChanged;
  final DesktopSettings desktop;
  final ValueChanged<DesktopSettings>? onDesktopChanged;
  final bool settingsBusy, checkingUpdate;
  final VoidCallback? onCheckUpdate, onOpenUpdate, onCopyControllerSecret;
  final String? updateStatus;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final _portController =
      TextEditingController(text: '${widget.mixedPort}');
  late final _clashPortController =
      TextEditingController(text: '${widget.clashApiPort}');
  late final _pathController = TextEditingController(text: widget.singBoxPath);
  String? _error;

  @override
  void didUpdateWidget(covariant SettingsPage old) {
    super.didUpdateWidget(old);
    if (old.mixedPort != widget.mixedPort &&
        _portController.text == '${old.mixedPort}')
      _portController.text = '${widget.mixedPort}';
    if (old.clashApiPort != widget.clashApiPort &&
        _clashPortController.text == '${old.clashApiPort}')
      _clashPortController.text = '${widget.clashApiPort}';
    if (old.singBoxPath != widget.singBoxPath &&
        _pathController.text == old.singBoxPath)
      _pathController.text = widget.singBoxPath;
  }

  @override
  void dispose() {
    _portController.dispose();
    _clashPortController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  void _save() {
    final port = int.tryParse(_portController.text.trim()) ?? 0;
    final clashPort = int.tryParse(_clashPortController.text.trim()) ?? 0;
    if (port <= 0 || port > 65535) {
      setState(() => _error = '本地端口无效：${_portController.text}');
      return;
    }
    if (clashPort <= 0 || clashPort > 65535) {
      setState(() => _error = 'Clash API 端口无效：${_clashPortController.text}');
      return;
    }
    if (port == clashPort) {
      setState(() => _error = '本地端口与 Clash API 端口不能相同');
      return;
    }
    setState(() => _error = null);
    widget.onSave(port, clashPort, _pathController.text.trim());
  }

  Widget section(Widget child) =>
      Padding(padding: const EdgeInsets.only(bottom: 16), child: child);
  Widget scroll(String key, List<Widget> children) => SingleChildScrollView(
      key: PageStorageKey(key),
      padding: const EdgeInsets.only(top: 20, bottom: 20),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, children: children));

  @override
  Widget build(BuildContext context) => DefaultTabController(
      key: ValueKey(widget.initialSection),
      initialIndex: widget.initialSection,
      length: 4,
      child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const PageHeading('设置', '连接、分流与界面偏好，在此集中管理。',
                eyebrow: 'PREFERENCES / LOCAL WORKSPACE'),
            const TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(text: '常规与连接'),
                  Tab(text: '外观动效'),
                  Tab(text: '分流与 DNS'),
                  Tab(text: '数据与诊断')
                ]),
            Expanded(
                child: TabBarView(children: [
              scroll('settings-general', [
                GeneralSettings(
                    value: widget.desktop,
                    onChanged: widget.onDesktopChanged ?? (_) {},
                    busy: widget.settingsBusy,
                    autoConnect: widget.autoConnect,
                    onAutoConnectChanged: widget.onAutoConnectChanged,
                    onCheckUpdate: widget.onCheckUpdate ?? () {},
                    onOpenUpdate: widget.onOpenUpdate,
                    updateStatus: widget.updateStatus,
                    checkingUpdate: widget.checkingUpdate,
                    onCopyControllerSecret:
                        widget.onCopyControllerSecret ?? () {}),
                const SizedBox(height: 20),
                Panel(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                      const Text('本地监听与内核',
                          style: TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 16),
                      TextField(
                          controller: _portController,
                          enabled: !widget.running && !widget.settingsBusy,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                              labelText: '本地端口（mixed，HTTP/SOCKS 共用）')),
                      const SizedBox(height: 14),
                      TextField(
                          controller: _clashPortController,
                          enabled: !widget.running && !widget.settingsBusy,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                              labelText: 'Clash API 控制器端口')),
                      const SizedBox(height: 14),
                      TextField(
                          controller: _pathController,
                          enabled: !widget.running && !widget.settingsBusy,
                          decoration: const InputDecoration(
                              labelText: 'sing-box 路径（留空使用托管内核）')),
                      if (_error != null)
                        Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(_error!,
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error))),
                      const SizedBox(height: 16),
                      Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton(
                              onPressed: widget.running || widget.settingsBusy
                                  ? null
                                  : _save,
                              child: const Text('保存设置')))
                    ])),
              ]),
              scroll('settings-appearance', [const AppearanceSettings()]),
              scroll('settings-routing', [
                if (widget.onClientSave != null)
                  ClientSettings(
                      key: ValueKey(widget.client),
                      value: widget.client,
                      onSave: widget.onClientSave!,
                      busy: widget.settingsBusy),
                const SizedBox(height: 20),
                Panel(
                    child: Column(children: [
                  const ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('内置规则模板'),
                      subtitle: Text('仅在使用内置模板时添加以下规则；完整配置保留订阅自身规则。')),
                  SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('广告拦截'),
                      subtitle: const Text('广告域名规则集就绪后应用。'),
                      value: widget.blockAds,
                      onChanged: widget.settingsBusy
                          ? null
                          : widget.onBlockAdsChanged),
                  SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('国内直连'),
                      subtitle: const Text('国内域名与 IP 规则集就绪后应用。'),
                      value: widget.bypassCn,
                      onChanged: widget.settingsBusy
                          ? null
                          : widget.onBypassCnChanged),
                ]))
              ]),
              scroll('settings-data', [
                section(Panel(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Text('备份与恢复',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      const Text(
                          '备份节点、订阅、完整配置、分流和界面偏好。不包含内核与缓存；文件含订阅和节点凭据，请妥善保管。'),
                      const SizedBox(height: 16),
                      Wrap(spacing: 12, runSpacing: 8, children: [
                        OutlinedButton.icon(
                            onPressed:
                                widget.settingsBusy ? null : widget.onBackup,
                            icon: const Icon(Icons.download_outlined, size: 17),
                            label: const Text('导出本地备份')),
                        OutlinedButton.icon(
                            onPressed: widget.running || widget.settingsBusy
                                ? null
                                : widget.onRestore,
                            icon: const Icon(Icons.settings_backup_restore,
                                size: 17),
                            label: const Text('从备份恢复'))
                      ]),
                      if (widget.running)
                        const Padding(
                            padding: EdgeInsets.only(top: 10),
                            child: Text('请停止代理后恢复配置。'))
                    ]))),
                section(Panel(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Text('内核与诊断',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      Text(widget.coreVersion ?? '内核尚未就绪'),
                      const SizedBox(height: 10),
                      Wrap(spacing: 12, runSpacing: 8, children: [
                        OutlinedButton.icon(
                            onPressed: widget.settingsBusy || widget.running
                                ? null
                                : widget.onEnsureCore,
                            icon: const Icon(Icons.system_update_alt, size: 17),
                            label: const Text('检查内核资源')),
                        OutlinedButton.icon(
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(
                                  text:
                                      'Tokiboshi $kAppVersion (build $kAppBuild)\n内核：${widget.coreVersion ?? '未就绪'}\n状态：${widget.running ? '运行中' : '已停止'}\nMixed：${widget.mixedPort} / Controller：${widget.clashApiPort}'));
                              if (context.mounted)
                                ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text('诊断概况已复制，不含订阅或节点凭据')));
                            },
                            icon: const Icon(Icons.copy_outlined, size: 17),
                            label: const Text('复制诊断概况'))
                      ]),
                      const SizedBox(height: 16),
                      Text('数据位置：${widget.dataFilePath}',
                          style: Theme.of(context).textTheme.bodySmall)
                    ]))),
                section(const Panel(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text('Tokiboshi · 時の星',
                          style: TextStyle(
                              fontSize: 19, fontWeight: FontWeight.w600)),
                      SizedBox(height: 8),
                      Text('v$kAppVersion · build $kAppBuild · Windows'),
                      SizedBox(height: 12),
                      SelectableText(
                          '项目：https://github.com/kurumiZafkiel12/Tokiboshi'),
                      SizedBox(height: 6),
                      SelectableText(
                          '反馈：https://github.com/kurumiZafkiel12/Tokiboshi/issues'),
                      SizedBox(height: 14),
                      Text(
                          '应用快捷键：Ctrl K 查找节点 · Ctrl I 导入 · Ctrl , 设置\n所有快捷键仅在应用窗口内生效。',
                          style: TextStyle(fontSize: 12))
                    ])))
              ])
            ]))
          ])));
}
