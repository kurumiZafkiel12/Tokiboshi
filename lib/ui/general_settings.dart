import 'package:flutter/material.dart';
import '../services/desktop_settings.dart';
import 'design.dart';

class GeneralSettings extends StatelessWidget {
  const GeneralSettings(
      {super.key,
      required this.value,
      required this.onChanged,
      required this.busy,
      required this.autoConnect,
      required this.onAutoConnectChanged,
      required this.onCheckUpdate,
      this.onOpenUpdate,
      this.updateStatus,
      this.checkingUpdate = false,
      required this.onCopyControllerSecret});
  final DesktopSettings value;
  final ValueChanged<DesktopSettings> onChanged;
  final bool busy, autoConnect, checkingUpdate;
  final ValueChanged<bool>? onAutoConnectChanged;
  final VoidCallback onCheckUpdate, onCopyControllerSecret;
  final VoidCallback? onOpenUpdate;
  final String? updateStatus;
  Widget _row(BuildContext context, String title, String description,
          Widget control) =>
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
          child: LayoutBuilder(builder: (context, c) {
            final text =
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500)),
              if (description.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(description, style: Theme.of(context).textTheme.bodySmall)
              ]
            ]);
            return c.maxWidth < 530
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [text, const SizedBox(height: 9), control])
                : Row(children: [
                    Expanded(child: text),
                    const SizedBox(width: 20),
                    control
                  ]);
          }));
  Widget _toggle(BuildContext c, String title, String help, bool current,
          ValueChanged<bool> change) =>
      _row(c, title, help,
          Switch(value: current, onChanged: busy ? null : change));
  Future<void> _ua(BuildContext context) async {
    final input = TextEditingController(text: value.userAgent);
    final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('订阅请求 User-Agent'),
                content: SizedBox(
                    width: 480,
                    child: TextField(
                        controller: input,
                        maxLength: 512,
                        decoration: const InputDecoration(
                            labelText: '留空使用 Tokiboshi 默认值',
                            hintText: 'Clash.Meta Tokiboshi/0.0.9'))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () =>
                          Navigator.pop(context, input.text.trim()),
                      child: const Text('保存'))
                ]));
    input.dispose();
    if (result != null) onChanged(value.copyWith(userAgent: result));
  }

  Future<void> _auth(BuildContext context) async {
    final user = TextEditingController(text: value.proxyUser),
        password = TextEditingController(text: value.proxyPassword);
    String? error;
    final result = await showDialog<(String, String)>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                    title: const Text('HTTP / SOCKS 代理认证'),
                    content: SizedBox(
                        width: 440,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          TextField(
                              controller: user,
                              decoration:
                                  const InputDecoration(labelText: '用户名')),
                          const SizedBox(height: 12),
                          TextField(
                              controller: password,
                              obscureText: true,
                              decoration:
                                  const InputDecoration(labelText: '密码')),
                          if (error != null) ...[
                            const SizedBox(height: 10),
                            Text(error!,
                                style: TextStyle(
                                    color: Theme.of(context).colorScheme.error))
                          ],
                          const SizedBox(height: 12),
                          const Text('本机与局域网使用此代理端口的应用都需要认证；凭据仅保存在本机配置。',
                              style: TextStyle(fontSize: 11))
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () {
                            if (user.text.trim().isEmpty ||
                                password.text.isEmpty) {
                              update(() => error = '请填写用户名与密码');
                              return;
                            }
                            Navigator.pop(
                                context, (user.text.trim(), password.text));
                          },
                          child: const Text('保存并启用'))
                    ])));
    user.dispose();
    password.dispose();
    if (result != null)
      onChanged(value.copyWith(
          proxyAuth: true, proxyUser: result.$1, proxyPassword: result.$2));
  }

  Future<void> _demand(BuildContext context) async {
    final input = TextEditingController(text: value.processes.join('\n'));
    var enabled = value.onDemand;
    String? error;
    final result = await showDialog<DesktopSettings>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                    title: const Text('按需运行'),
                    content: SizedBox(
                        width: 520,
                        child: SingleChildScrollView(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('按应用运行状态自动连接'),
                                  value: enabled,
                                  onChanged: (v) => update(() => enabled = v)),
                              TextField(
                                  controller: input,
                                  minLines: 4,
                                  maxLines: 8,
                                  decoration: const InputDecoration(
                                      labelText: '程序名（每行一个）',
                                      hintText: 'chrome.exe\nCode.exe')),
                              const SizedBox(height: 12),
                              const Text(
                                  '匹配任何一个程序时连接；全部退出后，仅停止由按需功能启动的连接。手动停止后，本轮匹配期间不再自动启动。TUN 需要管理员时会等待手动授权。',
                                  style: TextStyle(fontSize: 12)),
                              if (error != null) ...[
                                const SizedBox(height: 12),
                                Text(error!,
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error))
                              ]
                            ]))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () {
                            final names = input.text
                                .split(RegExp(r'[\n,;]+'))
                                .map((s) => s.trim())
                                .where((s) => s.isNotEmpty)
                                .toSet()
                                .toList();
                            if ((enabled && names.isEmpty) ||
                                names.length > 100 ||
                                names.any((s) =>
                                    s.contains(RegExp(r'[\\/:*?"<>|]')))) {
                              update(() => error = '请填写程序文件名，不要包含路径；最多 100 个');
                              return;
                            }
                            Navigator.pop(
                                context,
                                value.copyWith(
                                    onDemand: enabled, processes: names));
                          },
                          child: const Text('保存'))
                    ])));
    input.dispose();
    if (result != null) onChanged(result);
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('启动与后台',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Panel(
            padding: EdgeInsets.zero,
            child: Column(children: [
              _toggle(
                  context,
                  '开机自启',
                  '当前 Windows 用户登录后启动，不需要管理员权限。',
                  value.launchAtLogin,
                  (v) => onChanged(value.copyWith(launchAtLogin: v))),
              const Divider(height: 1),
              _toggle(
                  context,
                  '静默启动',
                  '开机自启时，托盘就绪后隐藏主窗口；托盘不可用时保持窗口可见。',
                  value.silentStart,
                  (v) => onChanged(value.copyWith(silentStart: v))),
              const Divider(height: 1),
              _toggle(context, '打开应用自动连接', '每次打开尝试连接已选节点；虚拟网卡仍遵守管理员授权。',
                  value.autoRun, (v) => onChanged(value.copyWith(autoRun: v))),
              const Divider(height: 1),
              _toggle(context, '恢复上次运行状态', '未开启上方自动连接时，仅恢复正常退出前的运行状态。',
                  autoConnect, (v) => onAutoConnectChanged?.call(v)),
              const Divider(height: 1),
              _row(
                  context,
                  '按需运行',
                  value.onDemand
                      ? '已启用 · ${value.processes.length} 个程序'
                      : '根据程序运行状态连接与停止',
                  OutlinedButton.icon(
                      onPressed: busy ? null : () => _demand(context),
                      icon: const Icon(Icons.tune, size: 15),
                      label: const Text('配置'))),
            ])),
        const SizedBox(height: 22),
        const Text('请求与更新',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Panel(
            padding: EdgeInsets.zero,
            child: Column(children: [
              _row(
                  context,
                  'User-Agent',
                  value.userAgent.isEmpty
                      ? '默认 · Clash.Meta Tokiboshi/0.0.9'
                      : value.userAgent,
                  OutlinedButton(
                      onPressed: busy ? null : () => _ua(context),
                      child: const Text('修改'))),
              const Divider(height: 1),
              _toggle(
                  context,
                  '校验 TLS 证书',
                  '影响订阅与规则下载，不修改节点自身 TLS 设置。',
                  value.verifyTls,
                  (v) => onChanged(value.copyWith(verifyTls: v))),
              if (!value.verifyTls)
                const Padding(
                    padding: EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: Text('证书校验已关闭：不可信证书也会被接受，请仅用于你信任的订阅服务。',
                        style: TextStyle(fontSize: 11, color: gold))),
              const Divider(height: 1),
              _toggle(
                  context,
                  '自动检查更新',
                  '启动后查询 GitHub 最新正式发布，不自动安装或覆盖。',
                  value.autoCheckUpdates,
                  (v) => onChanged(value.copyWith(autoCheckUpdates: v))),
              const Divider(height: 1),
              _row(
                  context,
                  '应用更新',
                  updateStatus ?? '尚未检查',
                  Wrap(spacing: 8, children: [
                    OutlinedButton(
                        onPressed: checkingUpdate ? null : onCheckUpdate,
                        child: Text(checkingUpdate ? '检查中…' : '检查更新')),
                    if (onOpenUpdate != null)
                      FilledButton(
                          onPressed: onOpenUpdate, child: const Text('打开下载页'))
                  ]))
            ])),
        const SizedBox(height: 22),
        const Text('入站与控制',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Panel(
            padding: EdgeInsets.zero,
            child: Column(children: [
              _toggle(
                  context,
                  '局域网代理',
                  '启用后 HTTP / SOCKS 监听所有 IPv4 网卡；请在可信网络中使用。',
                  value.allowLan,
                  (v) => onChanged(value.copyWith(allowLan: v))),
              const Divider(height: 1),
              _toggle(
                  context,
                  '代理端口认证',
                  '对 HTTP / SOCKS 接入启用用户名与密码，浏览器等应用可能提示登录。',
                  value.proxyAuth, (v) {
                if (v &&
                    (value.proxyUser.isEmpty || value.proxyPassword.isEmpty)) {
                  _auth(context);
                } else {
                  onChanged(value.copyWith(proxyAuth: v));
                }
              }),
              if (value.proxyAuth)
                _row(
                    context,
                    '认证信息',
                    value.proxyUser,
                    TextButton(
                        onPressed: busy ? null : () => _auth(context),
                        child: const Text('修改密码'))),
              const Divider(height: 1),
              _toggle(
                  context,
                  '局域网控制器',
                  '启用后允许其他设备通过控制端口管理内核；始终需要密钥认证。',
                  value.remoteController,
                  (v) => onChanged(value.copyWith(remoteController: v))),
              const Divider(height: 1),
              _row(
                  context,
                  '控制器密钥',
                  '本地控制始终保留且鉴权，供应用切换节点、测速和显示流量。',
                  OutlinedButton(
                      onPressed: busy ? null : onCopyControllerSecret,
                      child: const Text('复制密钥'))),
            ])),
        const Padding(
            padding: EdgeInsets.only(top: 10, bottom: 22),
            child: Text('网络接入设置在运行时修改会重启内核；保存失败会保留提示。',
                style: TextStyle(fontSize: 11)))
      ]);
}
