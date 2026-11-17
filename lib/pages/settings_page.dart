import 'package:flutter/material.dart';

import '../app_version.dart';
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
  });

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

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeading('设置', '让 Tokiboshi 适应你的使用习惯。',
              eyebrow: 'MAKE YOURSELF AT HOME.'),
          const AppearanceSettings(),
          const Text('连接与启动',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
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
              onCopyControllerSecret: widget.onCopyControllerSecret ?? () {}),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _portController,
                    enabled: !widget.running,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '本地端口（mixed，HTTP/SOCKS 共用）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _clashPortController,
                    enabled: !widget.running,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Clash API 端口（面板与控制通道，默认 9090）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pathController,
                    enabled: !widget.running,
                    decoration: const InputDecoration(
                      labelText: 'sing-box 路径（留空 = 用托管内核，自动下载）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: widget.running ? null : _save,
                      child: const Text('保存设置'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.memory, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child:
                        Text(widget.coreVersion ?? 'sing-box 内核未下载（首次启动时自动下载）'),
                  ),
                  OutlinedButton(
                    onPressed: widget.onEnsureCore,
                    child: const Text('下载/更新内核'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              title: const Text('系统代理'),
              subtitle: const Text('启动时写入系统代理（127.0.0.1:本地端口），停止时关闭'),
              value: widget.systemProxy,
              onChanged: widget.running ? null : widget.onSystemProxyChanged,
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 14, 16, 2),
                  child: Text('分流规则',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text(
                    '固定规则：私有/局域网地址直连、其余流量走代理（规则模式下）。下面两项可开关，改动后重启内核生效。',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                SwitchListTile(
                  title: const Text('广告拦截'),
                  subtitle:
                      const Text('广告域名直接拒绝（geosite-category-ads-all 规则集）'),
                  value: widget.blockAds,
                  onChanged: widget.onBlockAdsChanged,
                ),
                SwitchListTile(
                  title: const Text('国内直连'),
                  subtitle: const Text(
                      '国内网站与 IP 直连（geosite-cn / geoip-cn 规则集），DNS 同步走本地解析'),
                  value: widget.bypassCn,
                  onChanged: widget.onBypassCnChanged,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('关于',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  const Text(
                      'Tokiboshi · 時の星 v$kAppVersion · 修订 2（build $kAppBuild） · Flutter + Rust + sing-box'),
                  const Text(
                      '面板为 zashboard（由 sing-box 托管于 127.0.0.1:9090/ui）；内核 sing-box 1.14.4 随安装包提供，缺失时自动下载'),
                  const SelectableText(
                      '项目地址：https://github.com/kurumiZafkiel12/Tokiboshi'),
                  const SelectableText(
                      '问题反馈：https://github.com/kurumiZafkiel12/Tokiboshi/issues'),
                  Text('数据文件：${widget.dataFilePath}'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
