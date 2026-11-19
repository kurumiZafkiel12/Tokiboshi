import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/store.dart';
import 'design.dart';
import 'preferences.dart';

Future<Subscription?> editSubscription(
        BuildContext context, Subscription source,
        {Future<void> Function(Subscription)? onSave, bool mobile = false}) =>
    showGeneralDialog<Subscription>(
        context: context,
        barrierDismissible: false,
        barrierLabel: '编辑订阅',
        transitionDuration: UiScope.duration(context, 280),
        transitionBuilder: (_, animation, __, child) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
                position: Tween(begin: const Offset(.08, 0), end: Offset.zero)
                    .animate(CurvedAnimation(
                        parent: animation, curve: Curves.easeOutCubic)),
                child: child)),
        pageBuilder: (_, __, ___) => _SubscriptionEditor(
            source: source, onSave: onSave, mobile: mobile));

class _SubscriptionEditor extends StatefulWidget {
  const _SubscriptionEditor(
      {required this.source, this.onSave, required this.mobile});
  final bool mobile;
  final Subscription source;
  final Future<void> Function(Subscription)? onSave;
  @override
  State<_SubscriptionEditor> createState() => _SubscriptionEditorState();
}

class _SubscriptionEditorState extends State<_SubscriptionEditor> {
  late final name = TextEditingController(text: widget.source.name);
  late final url = TextEditingController(text: widget.source.url);
  late int interval = widget.source.refreshMinutes;
  bool reveal = false, saving = false;
  String? error;
  bool get dirty =>
      name.text != widget.source.name ||
      url.text != widget.source.url ||
      interval != widget.source.refreshMinutes;
  @override
  void dispose() {
    name.dispose();
    url.dispose();
    super.dispose();
  }

  Future<void> close() async {
    if (saving) return;
    if (dirty) {
      final yes = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(title: const Text('放弃未保存的修改？'), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text('继续编辑')),
                FilledButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: const Text('放弃修改'))
              ]));
      if (yes != true || !mounted) return;
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> save() async {
    if (saving) return;
    if (name.text.trim().isEmpty || name.text.trim().length > 100) {
      setState(() => error = '订阅名称需为 1–100 个字符');
      return;
    }
    if (widget.source.isRemote) {
      final uri = Uri.tryParse(url.text.trim());
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.fragment.isNotEmpty) {
        setState(() => error = '请填写有效的 HTTP(S) 订阅地址');
        return;
      }
    }
    final next = widget.source.copyWith(
        name: name.text.trim(),
        url: url.text.trim(),
        refreshMinutes: interval,
        profileState: url.text.trim() != widget.source.url
            ? 'pending-update'
            : widget.source.profileState);
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.onSave?.call(next);
      if (mounted) Navigator.pop(context, next);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Align(
      alignment: Alignment.centerRight,
      child: Material(
          color: Theme.of(context).colorScheme.surface,
          child: SizedBox(
              width: math.min(MediaQuery.sizeOf(context).width, 620),
              height: double.infinity,
              child: SafeArea(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                    Padding(
                        padding: const EdgeInsets.all(24),
                        child: Row(children: [
                          const Icon(Icons.rss_feed, color: wine),
                          const SizedBox(width: 12),
                          const Expanded(
                              child: Text('编辑订阅源',
                                  style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700))),
                          IconButton(
                              tooltip: '关闭编辑',
                              onPressed: saving ? null : close,
                              icon: const Icon(Icons.close))
                        ])),
                    const Divider(height: 1),
                    Expanded(
                        child: SingleChildScrollView(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text('来源信息',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium),
                                  const SizedBox(height: 16),
                                  TextField(
                                      controller: name,
                                      decoration: const InputDecoration(
                                          labelText: '订阅名称'),
                                      maxLength: 100),
                                  const SizedBox(height: 16),
                                  if (widget.source.isRemote)
                                    TextField(
                                        controller: url,
                                        obscureText: !reveal,
                                        autocorrect: false,
                                        enableSuggestions: false,
                                        decoration: InputDecoration(
                                            labelText: '订阅地址',
                                            suffixIcon: IconButton(
                                                tooltip:
                                                    reveal ? '隐藏地址' : '显示地址',
                                                onPressed: () => setState(
                                                    () => reveal = !reveal),
                                                icon: Icon(reveal
                                                    ? Icons
                                                        .visibility_off_outlined
                                                    : Icons
                                                        .visibility_outlined))))
                                  else
                                    Text(widget.mobile
                                        ? '手机保留导入时的内容。重新解析会使用已保存的副本。'
                                        : '本地来源保留原文件或粘贴内容。更新时重新读取该来源。'),
                                  if (!widget.mobile ||
                                      widget.source.isRemote) ...[
                                    const SizedBox(height: 24),
                                    DropdownButtonFormField<int>(
                                        initialValue: interval,
                                        decoration: const InputDecoration(
                                            labelText: '自动更新'),
                                        items: [
                                          for (final n in {
                                            0,
                                            30,
                                            60,
                                            180,
                                            360,
                                            720,
                                            1440,
                                            interval
                                          })
                                            DropdownMenuItem(
                                                value: n,
                                                child: Text(n == 0
                                                    ? '仅手动更新'
                                                    : n < 60
                                                        ? '每 $n 分钟'
                                                        : '每 ${n ~/ 60} 小时'))
                                        ],
                                        onChanged: (v) =>
                                            setState(() => interval = v ?? 0)),
                                    const SizedBox(height: 16),
                                    Text(
                                        widget.mobile
                                            ? '应用在前台且 VPN 已断开时检查更新。更新失败会保留上次有效节点和规则。'
                                            : '应用运行时检查更新时间。代理运行中将延后更新，停止后自动处理，避免中断当前连接。失败保留上次有效节点和规则。',
                                        style: TextStyle(fontSize: 13)),
                                  ],
                                  const SizedBox(height: 24),
                                  Panel(
                                      child: Text(widget.source.isRemote
                                          ? '保存名称、地址和更新计划不会立即替换节点。地址修改后，请执行一次更新以验证新来源。'
                                          : '保存名称后，现有节点与规则保持原样。')),
                                  if (error != null)
                                    Padding(
                                        padding: const EdgeInsets.only(top: 16),
                                        child: Text(error!,
                                            style: TextStyle(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .error)))
                                ]))),
                    const Divider(height: 1),
                    Padding(
                        padding: const EdgeInsets.all(20),
                        child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                  onPressed: saving ? null : close,
                                  child: const Text('取消')),
                              const SizedBox(width: 12),
                              FilledButton.icon(
                                  onPressed: saving ? null : save,
                                  icon: const Icon(Icons.check, size: 17),
                                  label: Text(saving ? '正在保存…' : '保存设置'))
                            ]))
                  ])))));
}
