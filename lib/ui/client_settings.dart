import 'package:flutter/material.dart';
import '../services/client_preferences.dart';
import 'design.dart';

class ClientSettings extends StatefulWidget {
  const ClientSettings(
      {super.key,
      required this.value,
      required this.onSave,
      this.busy = false,
      this.mobile = false});
  final ClientPreferences value;
  final Future<void> Function(ClientPreferences) onSave;
  final bool busy, mobile;
  @override
  State<ClientSettings> createState() => _ClientSettingsState();
}

class _ClientSettingsState extends State<ClientSettings> {
  late final dns = TextEditingController(text: widget.value.dnsEndpoint);
  late final test = TextEditingController(text: widget.value.testUrl);
  late final timeout =
      TextEditingController(text: '${widget.value.testTimeoutMs}');
  late bool dnsEnabled = widget.value.dnsEnabled,
      viaProxy = widget.value.dnsViaProxy;
  late List<RoutingRule> rules = List.of(widget.value.rules);
  String? message;
  bool saving = false;
  @override
  void dispose() {
    dns.dispose();
    test.dispose();
    timeout.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      message = null;
    });
    try {
      final value = ClientPreferences(
          rules: List.of(rules),
          dnsEnabled: dnsEnabled,
          dnsEndpoint: dns.text.trim(),
          dnsViaProxy: viaProxy,
          testUrl: test.text.trim(),
          testTimeoutMs: int.tryParse(timeout.text) ?? 0);
      value.validate();
      await widget.onSave(value);
      if (mounted) setState(() => message = '已保存。分流和 DNS 在下次启动时应用。');
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> addRule() async {
    final rule = await showDialog<RoutingRule>(
        context: context, builder: (_) => const _RuleEditorDialog());
    if (rule != null && mounted) setState(() => rules = [...rules, rule]);
  }

  @override
  Widget build(BuildContext context) {
    final locked = widget.busy || saving;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!widget.mobile) ...[
        const SizedBox(height: 24),
        const Text('分流、DNS 与测速',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
      ],
      Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Expanded(
              child: Text('自定义分流规则',
                  style: TextStyle(fontWeight: FontWeight.w600))),
          OutlinedButton.icon(
              onPressed: locked ? null : addRule,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加规则'))
        ]),
        const SizedBox(height: 6),
        const Text('规则模式下按顺序匹配，优先于内置/订阅规则。全局和直连模式仍优先生效。仅保存不会中断正在运行的连接。',
            style: TextStyle(fontSize: 12)),
        const SizedBox(height: 12),
        if (rules.isEmpty)
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('暂无自定义规则')),
        for (var i = 0; i < rules.length; i++)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Checkbox(
                    value: rules[i].enabled,
                    onChanged: locked
                        ? null
                        : (v) => setState(() => rules[i] = RoutingRule(
                            kind: rules[i].kind,
                            value: rules[i].value,
                            target: rules[i].target,
                            enabled: v!))),
                Expanded(
                    child: Text(
                        '${RoutingRule.kinds[rules[i].kind]}  ${rules[i].value}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis)),
                Tag({
                  'proxy': '代理',
                  'direct': '直连',
                  'reject': '拦截'
                }[rules[i].target]!),
                IconButton(
                    tooltip: '上移规则',
                    onPressed: locked || i == 0
                        ? null
                        : () {
                            final index = i;
                            setState(() {
                              final r = rules.removeAt(index);
                              rules.insert(index - 1, r);
                            });
                          },
                    icon: const Icon(Icons.arrow_upward, size: 16)),
                IconButton(
                    tooltip: '删除规则',
                    onPressed: locked
                        ? null
                        : () {
                            final index = i;
                            setState(() => rules.removeAt(index));
                          },
                    icon: const Icon(Icons.close, size: 16))
              ])),
        const Divider(height: 28),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('自定义远程 DNS'),
            subtitle: const Text('仅覆盖内置模板的远程解析；完整订阅配置继续使用订阅 DNS。'),
            value: dnsEnabled,
            onChanged: locked ? null : (v) => setState(() => dnsEnabled = v)),
        if (dnsEnabled) ...[
          TextField(
              controller: dns,
              decoration: const InputDecoration(
                  labelText: 'DNS 地址', hintText: 'https://1.1.1.1/dns-query')),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('DNS 请求经代理出口'),
              value: viaProxy,
              onChanged: locked ? null : (v) => setState(() => viaProxy = v))
        ],
        const Divider(height: 28),
        TextField(
            controller: test,
            decoration: const InputDecoration(labelText: '内核测速目标 URL')),
        const SizedBox(height: 12),
        TextField(
            controller: timeout,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: '测速超时（毫秒）',
                helperMaxLines: 2,
                helperText: widget.mobile
                    ? '1000–30000，连接 VPN 后可测速。'
                    : '1000–30000；TCP 端口探测不等同代理连通性。')),
        if (message != null)
          Padding(
              padding: const EdgeInsets.only(top: 14), child: Text(message!)),
        const SizedBox(height: 14),
        Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
                onPressed: locked ? null : save,
                child: Text(saving ? '正在保存…' : '保存分流与测速设置')))
      ])),
    ]);
  }
}

class _RuleEditorDialog extends StatefulWidget {
  const _RuleEditorDialog();
  @override
  State<_RuleEditorDialog> createState() => _RuleEditorDialogState();
}

class _RuleEditorDialogState extends State<_RuleEditorDialog> {
  final value = TextEditingController();
  String kind = 'domain_suffix', target = 'proxy';
  String? error;
  @override
  void dispose() {
    value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('添加自定义规则'),
          scrollable: true,
          content: SizedBox(
              width: 420,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                DropdownButtonFormField<String>(
                    initialValue: kind,
                    decoration: const InputDecoration(labelText: '匹配类型'),
                    items: [
                      for (final entry in RoutingRule.kinds.entries)
                        DropdownMenuItem(
                            value: entry.key, child: Text(entry.value))
                    ],
                    onChanged: (v) => setState(() => kind = v!)),
                const SizedBox(height: 12),
                TextField(
                    controller: value,
                    decoration: const InputDecoration(
                        labelText: '匹配内容',
                        hintText: 'example.com / 10.0.0.0/8 / chrome.exe')),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                    initialValue: target,
                    decoration: const InputDecoration(labelText: '动作'),
                    items: const [
                      DropdownMenuItem(value: 'proxy', child: Text('当前代理出口')),
                      DropdownMenuItem(value: 'direct', child: Text('直连')),
                      DropdownMenuItem(value: 'reject', child: Text('拦截'))
                    ],
                    onChanged: (v) => setState(() => target = v!)),
                if (kind == 'process_name')
                  const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text('进程规则需要内核识别应用进程，通常在 TUN 模式下使用。')),
                if (error != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)))
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: () {
                  try {
                    final rule = RoutingRule(
                        kind: kind, value: value.text.trim(), target: target);
                    rule.validate();
                    Navigator.pop(context, rule);
                  } catch (e) {
                    setState(() => error = '$e');
                  }
                },
                child: const Text('添加'))
          ]);
}
