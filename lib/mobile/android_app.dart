import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import '../pages/connections_page.dart';
import '../services/config_backup.dart';
import '../ui/client_settings.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_version.dart';
import '../bridge/core_bridge.dart';
import '../services/store.dart';
import '../services/subscription_resolver.dart';
import '../services/active_profile.dart';
import '../services/import_io.dart';
import '../ui/design.dart';
import '../ui/preferences.dart';
import '../ui/motion.dart';
import '../ui/traffic_chart.dart';
import '../ui/import_dialog.dart';
import '../ui/subscription_editor.dart';
import '../ui/diagnostics.dart';
import 'android_bridge.dart';
import 'android_controller.dart';
import 'android_import_io.dart';
import 'android_vpn_settings.dart';

class AndroidApp extends StatefulWidget {
  const AndroidApp({
    super.key,
    required this.controller,
    this.importIo = const AndroidImportIo(),
    this.initialize = true,
  });
  final AndroidController controller;
  final ImportIo importIo;
  final bool initialize;
  static Future<AndroidApp> create() async {
    final directories =
        await androidVpnChannel.invokeMapMethod<String, dynamic>('directories');
    final path = directories?['files'] as String?;
    if (path == null) throw const FileSystemException('无法打开应用私有目录');
    LicenseRegistry.addLicense(() async* {
      for (final path in [
        'assets/licenses/Android-NOTICE.txt',
        'assets/licenses/sing-box-GPL-3.0.txt',
      ]) {
        yield LicenseEntryWithLineBreaks([
          'Tokiboshi Android / sing-box',
        ], await rootBundle.loadString(path));
      }
    });
    final store = Store(File('$path/data.json'));
    return AndroidApp(
      controller: AndroidController(
        bridge: AndroidCoreBridge(),
        store: store,
        data: await store.load(),
      ),
    );
  }

  @override
  State<AndroidApp> createState() => _AndroidAppState();
}

class _AndroidAppState extends State<AndroidApp> with WidgetsBindingObserver {
  late final ui = ValueNotifier(widget.controller.data.ui);
  AndroidController get controller => widget.controller;
  Future<void>? _ready;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(changed);
    if (widget.initialize) {
      _ready = controller.initialize().catchError(
            (Object e) => controller.report('初始化失败：$e'),
          );
    }
  }

  void changed() {
    ui.value = controller.data.ui;
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    controller.setForeground(state == AppLifecycleState.resumed);
    if (controller.foreground) {
      unawaited(
        controller.refresh().then((_) => controller.refreshDueSources()),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(changed);
    controller.dispose();
    ui.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = workbenchTheme(ui.value);
    return UiScope(
      controller: ui,
      onChanged: controller.appearance,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: kAppName,
        theme: base.copyWith(
          materialTapTargetSize: MaterialTapTargetSize.padded,
          visualDensity: VisualDensity.standard,
          textTheme: base.textTheme
              .copyWith(
                bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 14),
                bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 12),
                titleMedium: base.textTheme.titleMedium?.copyWith(fontSize: 16),
              )
              .apply(fontFamily: 'Roboto'),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 44)),
          ),
        ),
        home: AndroidShell(
            controller: controller, importIo: widget.importIo, ready: _ready),
      ),
    );
  }
}

class AndroidShell extends StatefulWidget {
  const AndroidShell({
    super.key,
    required this.controller,
    required this.importIo,
    this.ready,
  });
  final AndroidController controller;
  final ImportIo importIo;
  final Future<void>? ready;
  @override
  State<AndroidShell> createState() => _AndroidShellState();
}

class _AndroidShellState extends State<AndroidShell> {
  AndroidController get c => widget.controller;
  int page = 0;
  String search = '';
  String? source;
  String? providerGroup;
  NodeInfo? policyFilter;
  String? get activeId {
    try {
      return activeProfile(c.data)?.id ?? '';
    } catch (_) {
      return null;
    }
  }

  bool _drainingEntry = false;

  @override
  void initState() {
    super.initState();
    if (widget.ready != null) {
      androidVpnChannel.setMethodCallHandler((call) async {
        if (call.method == 'entryChanged') await _drainEntries();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _drainEntries());
    }
  }

  @override
  void dispose() {
    if (widget.ready != null) androidVpnChannel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _drainEntries() async {
    if (_drainingEntry || !mounted) return;
    _drainingEntry = true;
    try {
      await widget.ready;
      while (mounted) {
        final entry = await androidVpnChannel
            .invokeMapMethod<String, String>('takeEntry');
        if (!mounted || entry == null) break;
        if (entry['type'] == 'connect') await c.connectIfStopped();
        if (entry['type'] == 'share') await import('link', entry['text'] ?? '');
      }
    } catch (e) {
      if (mounted) c.report('无法处理系统操作：$e');
    } finally {
      _drainingEntry = false;
    }
  }

  Future<void> import([String method = 'link', String initialText = '']) async {
    if (c.busy) {
      if (initialText.isNotEmpty) c.report('操作进行中，请完成后再次分享');
      return;
    }
    final request = await showDialog<ImportRequest>(
      context: context,
      builder: (_) => ImportDialog(
        io: widget.importIo,
        initialMethod: method,
        initialText: initialText,
        canPreview: true,
      ),
    );
    if (request != null && mounted) {
      await c.importRequest(request,
          approve: request.preview ? _approveImport : null);
    }
  }

  Future<bool> _approveImport(String summary) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('仅节点导入预览'),
            content: SingleChildScrollView(child: Text(summary)),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('确认保存')),
            ],
          ),
        ) ??
        false;
  }

  Future<bool> confirm(String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认操作'),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ??
      false;
  void info(String title, String text) => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: SelectableText(text)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
  Widget section(String title, Widget child, {int order = 0}) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: MotionEntrance(
          order: order,
          child: MobilePanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 14),
                child,
              ],
            ),
          ),
        ),
      );
  Widget addButton() => PopupMenuButton<String>(
        tooltip: '导入节点或订阅',
        enabled: !c.busy,
        onSelected: import,
        itemBuilder: (_) => [
          for (final item in [
            ('qr', '二维码', Icons.qr_code_2),
            ('file', '文件', Icons.upload_file),
            ('link', '链接', Icons.link),
            ('clipboard', '剪贴板 / 文本', Icons.content_paste),
            ('custom', '自定义', Icons.tune),
          ])
            PopupMenuItem(
              value: item.$1,
              child: Row(
                children: [
                  Icon(item.$3, size: 21),
                  const SizedBox(width: 14),
                  Text(item.$2),
                ],
              ),
            ),
        ],
        icon: const Icon(Icons.add),
      );
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          titleSpacing: 16,
          title: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset('assets/icon.png', width: 30, height: 30),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  kInAppName,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          actions: [
            if (MediaQuery.sizeOf(context).height -
                    MediaQuery.viewInsetsOf(context).bottom <
                460)
              IconButton(
                tooltip: c.running ? '停止 VPN' : '启动 VPN',
                onPressed: c.busy ? null : c.toggle,
                icon: Icon(
                  Icons.power_settings_new,
                  color: c.running ? good : null,
                ),
              ),
            addButton(),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              if (c.busy) const LinearProgressIndicator(minHeight: 2),
              if (c.message != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: MobilePanel(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: InkWell(
                            onTap: () => info('运行通知', c.message!),
                            child: Text(
                              c.message!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        if (c.importing)
                          TextButton(
                            onPressed: c.cancelling ? null : c.cancelImport,
                            child: Text(c.cancelling ? '取消中' : '取消导入'),
                          )
                        else
                          IconButton(
                            tooltip: '关闭通知',
                            onPressed: () {
                              c.message = null;
                              c.emit();
                            },
                            icon: const Icon(Icons.close, size: 17),
                          ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: UiScope.duration(context, 160),
                  reverseDuration: Duration.zero,
                  switchInCurve: Curves.easeOutCubic,
                  layoutBuilder: (current, _) =>
                      current ?? const SizedBox.shrink(),
                  transitionBuilder: (child, animation) => SlideTransition(
                    position:
                        Tween(begin: const Offset(.018, 0), end: Offset.zero)
                            .animate(animation),
                    child: child,
                  ),
                  child: KeyedSubtree(
                    key: ValueKey(page),
                    child: switch (page) {
                      0 => home(),
                      1 => nodes(),
                      2 => subscriptions(),
                      _ => settings(),
                    },
                  ),
                ),
              ),
              if (page != 0 &&
                  MediaQuery.sizeOf(context).height -
                          MediaQuery.viewInsetsOf(context).bottom >=
                      460)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: connection(compact: true),
                ),
            ],
          ),
        ),
        bottomNavigationBar: MediaQuery.viewInsetsOf(context).bottom > 0
            ? null
            : NavigationBar(
                height: MediaQuery.sizeOf(context).height < 480 ? 56 : 68,
                selectedIndex: page,
                onDestinationSelected: (v) => setState(() => page = v),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.dashboard_outlined),
                    selectedIcon: Icon(Icons.dashboard),
                    label: '连接',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.dns_outlined),
                    selectedIcon: Icon(Icons.dns),
                    label: '节点',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.inventory_2_outlined),
                    selectedIcon: Icon(Icons.inventory_2),
                    label: '订阅',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: '设置',
                  ),
                ],
              ),
      );
  Widget connection({bool compact = false}) => MobilePanel(
        accent: true,
        padding: EdgeInsets.all(compact ? 12 : 18),
        child: Stack(
          children: [
            if (!compact)
              Positioned.fill(
                child: IgnorePointer(child: FlowLines(active: c.running)),
              ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      c.running
                          ? Icons.verified_user_outlined
                          : Icons.shield_outlined,
                      color: c.running
                          ? good
                          : Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            c.running ? 'VPN 已连接' : 'VPN 未连接',
                            style: TextStyle(
                              fontSize: compact ? 15 : 22,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (!compact)
                            const Text(
                              'sing-box 1.14.4 · Android VPN',
                              style: TextStyle(fontSize: 12),
                            ),
                        ],
                      ),
                    ),
                    if (!compact) const Tag(kAndroidAppVersion),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => setState(() => page = 1),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              c.data.selected?.name ?? '请选择出口节点',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            Text(
                              c.data.selected?.protocol.toUpperCase() ??
                                  '先导入订阅或分享链接',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: c.busy ? null : c.toggle,
                      icon: c.busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.power_settings_new, size: 21),
                      label: Text(
                        c.busy
                            ? '处理中…'
                            : c.running
                                ? '停止 VPN'
                                : '启动 VPN',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      );
  Widget home() => ListView(
        key: const PageStorageKey('home'),
        padding: const EdgeInsets.all(14),
        children: [
          MotionEntrance(child: connection()),
          const SizedBox(height: 14),
          section(
            '实时流量',
            ListenableBuilder(
              listenable: c.monitor,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('↓ 下载', style: TextStyle(fontSize: 12)),
                            AnimatedMetric(
                              value: c.monitor.downSpeed / 1024,
                              format: (n) => c.monitor.available
                                  ? '${n.toStringAsFixed(1)} KB/s'
                                  : '—',
                              style: const TextStyle(fontSize: 23),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('↑ 上传', style: TextStyle(fontSize: 12)),
                            AnimatedMetric(
                              value: c.monitor.upSpeed / 1024,
                              format: (n) => c.monitor.available
                                  ? '${n.toStringAsFixed(1)} KB/s'
                                  : '—',
                              style: const TextStyle(fontSize: 23),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 90,
                    child: SmoothTrafficChart(
                      down: c.monitor.downHistory,
                      up: c.monitor.upHistory,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    c.monitor.available
                        ? '会话下载 ${bytes(c.monitor.download)} · 上传 ${bytes(c.monitor.upload)}'
                        : '连接成功后显示真实采样',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            order: 1,
          ),
          section(
            '当前配置',
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  key: ValueKey(activeId),
                  initialValue: activeId,
                  isExpanded: true,
                  hint: const Text('请选择完整配置'),
                  items: [
                    const DropdownMenuItem(
                        value: '', child: Text('内置分流模板 / 节点源')),
                    for (final s in c.data.subscriptions.where(
                      (s) => s.profileJson != null,
                    ))
                      DropdownMenuItem(
                        value: s.id,
                        child: Text(s.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: c.busy || c.running
                      ? null
                      : (v) {
                          if (v != null) c.activate(v);
                        },
                ),
                const SizedBox(height: 10),
                Text(
                  c.running ? '停止 VPN 后可切换完整配置。' : '完整配置负责规则与 DNS；仅节点来源提供出口选择。',
                  style: const TextStyle(fontSize: 12),
                ),
                if (c.data.nodes.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: OutlinedButton.icon(
                      onPressed: c.busy ? null : () => import(),
                      icon: const Icon(Icons.add_link),
                      label: const Text('导入第一个来源'),
                    ),
                  ),
              ],
            ),
            order: 2,
          ),
          section(
            '路由模式',
            Wrap(
              spacing: 8,
              children: [
                for (final item in [
                  ('rule', '规则'),
                  ('global', '全局'),
                  ('direct', '直连'),
                ])
                  ChoiceChip(
                    label: Text(item.$2),
                    selected: c.mode == item.$1,
                    onSelected:
                        !c.running || c.busy ? null : (_) => c.setMode(item.$1),
                  ),
              ],
            ),
            order: 3,
          ),
          section(
            '运行信息',
            Column(
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.route),
                  title: const Text('分流规则'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: showRules,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.swap_vert),
                  title: const Text('当前请求'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: showConnections,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.terminal),
                  title: const Text('运行日志'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: showLogs,
                ),
              ],
            ),
            order: 4,
          ),
        ],
      );
  Widget nodes() {
    final all = c.data.nodes;
    final sourceId =
        c.data.subscriptions.any((s) => s.id == source) ? source : null;
    final scoped = all.where((n) => sourceId == null || n.source == sourceId);
    final groups = scoped
        .where((n) => !n.isPolicy && n.group.isNotEmpty)
        .map((n) => n.group)
        .toSet();
    final policies = scoped.where((n) => n.isPolicy).toList();
    final group = groups.contains(providerGroup) ? providerGroup : null;
    final policy = policies.contains(policyFilter) ? policyFilter : null;
    final members =
        policy == null ? null : policyNodeIndices(all, all.indexOf(policy));
    final query = search.toLowerCase();
    final filtered = all.indexed.where((entry) {
      final n = entry.$2;
      return (sourceId == null || n.source == sourceId) &&
          (group == null || n.group == group) &&
          (members == null || members.contains(entry.$1) || n == policy) &&
          '${n.name} ${n.server} ${n.group} ${n.protocol}'
              .toLowerCase()
              .contains(query);
    }).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: '查找节点、服务器或分组',
            ),
            onChanged: (v) => setState(() => search = v),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(
                    '全部 ${c.data.nodes.where((n) => !n.isPolicy).length}',
                  ),
                  selected: sourceId == null,
                  onSelected: (_) => setState(() {
                    source = null;
                    providerGroup = null;
                    policyFilter = null;
                  }),
                ),
              ),
              for (final s in c.data.subscriptions)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(s.name),
                    selected: sourceId == s.id,
                    onSelected: (_) => setState(() {
                      source = s.id;
                      providerGroup = null;
                      policyFilter = null;
                    }),
                  ),
                ),
            ],
          ),
        ),
        if (groups.isNotEmpty || policies.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
            child: Row(children: [
              for (final name in groups)
                Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                        label: Text(name),
                        selected: group == name,
                        onSelected: (on) => setState(() {
                              providerGroup = on ? name : null;
                              policyFilter = null;
                            }))),
              for (final item in policies)
                Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                        label: Text(item.name),
                        avatar: const Icon(Icons.alt_route, size: 16),
                        selected: policy == item,
                        onSelected: (on) => setState(() {
                              policyFilter = on ? item : null;
                              providerGroup = null;
                            }))),
            ]),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: filtered.isEmpty
              ? empty(Icons.dns_outlined, '还没有匹配的节点', '通过右上角 + 导入订阅、文件或分享链接。')
              : ListView.builder(
                  itemCount: filtered.length,
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                  itemBuilder: (context, i) {
                    final index = filtered[i].$1, n = filtered[i].$2;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 9),
                      child: MotionEntrance(
                        key: ValueKey('${n.source}:$index'),
                        order: i < 8 ? i : 0,
                        child: MobilePanel(
                          accent: c.data.selectedIndex == index,
                          padding: EdgeInsets.zero,
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 13,
                              vertical: 5,
                            ),
                            leading: Icon(
                              c.data.selectedIndex == index
                                  ? Icons.check_circle
                                  : Icons.circle_outlined,
                              color:
                                  c.data.selectedIndex == index ? good : null,
                            ),
                            title: Text(
                              n.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${n.isPolicy ? '策略组' : n.protocol.toUpperCase()}${n.group.isEmpty ? '' : ' · ${n.group}'}${c.delays.containsKey(index) ? ' · ${c.delays[index] == null ? '测速失败' : '${c.delays[index]} ms'}' : ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: c.busy ? null : () => c.select(index),
                            trailing: PopupMenuButton<String>(
                              tooltip: '节点操作',
                              onSelected: (v) async {
                                if (v == 'detail')
                                  info(
                                    n.name,
                                    '协议：${n.protocol}\n服务器：${n.server}\n端口：${n.serverPort}\n分组：${n.group.isEmpty ? '未分组' : n.group}',
                                  );
                                if (v == 'delay') c.measure(index);
                                if (v == 'delete' &&
                                    await confirm('删除节点「${n.name}」？')) {
                                  final current = c.data.nodes.indexOf(n);
                                  if (mounted && current >= 0)
                                    c.removeNode(current);
                                }
                              },
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                  value: 'detail',
                                  child: Text('详情'),
                                ),
                                PopupMenuItem(
                                  value: 'delay',
                                  enabled: !c.busy && c.running,
                                  child: const Text('内核测速'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  enabled: !c.busy && !c.running,
                                  child: const Text('删除'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget subscriptions() => c.data.subscriptions.isEmpty
      ? empty(
          Icons.inventory_2_outlined,
          '还没有订阅',
          '支持链接、文件、二维码图片、剪贴板和自定义节点。',
          action: OutlinedButton(
            onPressed: c.busy ? null : () => import(),
            child: const Text('添加来源'),
          ),
        )
      : ListView(
          padding: const EdgeInsets.all(14),
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 14),
              child: Text(
                '来源更新失败会保留先前数据。订阅地址和凭据默认隐藏。',
                style: TextStyle(fontSize: 12),
              ),
            ),
            for (final (index, s) in c.data.subscriptions.indexed)
              MotionEntrance(
                order: index < 8 ? index : 0,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: MobilePanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.inventory_2_outlined, color: gold),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                s.name,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Tag(s.profileJson == null ? '节点源' : '完整配置'),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          s.isRemote
                              ? Uri.tryParse(s.url)?.host ?? '远程来源'
                              : '本地保存的配置副本',
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${c.data.nodes.where((n) => n.source == s.id && !n.isPolicy).length} 个节点${s.nodesOnly ? ' · 仅节点方式' : ''}',
                        ),
                        if (s.isRemote && s.refreshMinutes > 0)
                          Text('自动更新 · 每 ${s.refreshMinutes} 分钟'),
                        if (s.lastError != null)
                          Text(
                            '更新失败，已保留原配置：${redactDiagnostics(s.lastError!)}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            OutlinedButton.icon(
                              onPressed: c.busy || c.running
                                  ? null
                                  : () => c.updateSource(s),
                              icon: const Icon(Icons.refresh, size: 18),
                              label: Text(s.isRemote ? '更新' : '重新解析'),
                            ),
                            TextButton(
                              onPressed: () => info(
                                '识别诊断',
                                redactDiagnostics(
                                  s.lastReport?.isNotEmpty == true
                                      ? s.lastReport!
                                      : '当前来源没有额外诊断。',
                                ),
                              ),
                              child: const Text('诊断'),
                            ),
                            TextButton(
                              onPressed:
                                  c.busy || c.running ? null : () => editSub(s),
                              child: const Text('编辑'),
                            ),
                            TextButton(
                              onPressed: c.busy || c.running
                                  ? null
                                  : () async {
                                      if (await confirm('删除来源「${s.name}」及其节点？'))
                                        c.removeSource(s);
                                    },
                              child: const Text('删除'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
  Widget settings() => ListView(
        padding: const EdgeInsets.all(14),
        children: [
          section(
            '外观与动效',
            Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('浅色主题'),
                  value: c.data.ui.light,
                  onChanged: c.busy
                      ? null
                      : (v) => c.appearance(c.data.ui.copyWith(light: v)),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final m in [
                        ('full', '流畅'),
                        ('standard', '轻量'),
                        ('reduced', '精简'),
                      ])
                        ChoiceChip(
                          label: Text(m.$2),
                          selected: c.data.ui.motion == m.$1,
                          onSelected: c.busy
                              ? null
                              : (_) => c
                                  .appearance(c.data.ui.copyWith(motion: m.$1)),
                        ),
                    ],
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('跟随系统减少动态'),
                  value: c.data.ui.followSystem,
                  onChanged: c.busy
                      ? null
                      : (v) =>
                          c.appearance(c.data.ui.copyWith(followSystem: v)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('连接光流'),
                  value: c.data.ui.flow,
                  onChanged: c.busy
                      ? null
                      : (v) => c.appearance(c.data.ui.copyWith(flow: v)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('角色细节'),
                  value: c.data.ui.character,
                  onChanged: c.busy
                      ? null
                      : (v) => c.appearance(c.data.ui.copyWith(character: v)),
                ),
              ],
            ),
          ),
          section(
            '连接与订阅',
            Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('打开应用自动连接'),
                  subtitle: const Text('首次连接仍需要系统 VPN 授权。'),
                  value: c.data.autoConnect,
                  onChanged:
                      c.busy ? null : (v) => c.saveOptions(autoConnect: v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('校验 TLS 证书'),
                  subtitle: const Text('影响订阅和规则下载，默认开启。'),
                  value: c.data.desktop.verifyTls,
                  onChanged: c.busy
                      ? null
                      : (v) async {
                          if (v ||
                              await confirm('关闭后将接受不可信证书。仅对你信任的订阅服务使用，确定关闭？'))
                            c.saveOptions(verifyTls: v);
                        },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('订阅 User-Agent'),
                  subtitle: Text(
                    c.data.desktop.userAgent.isEmpty
                        ? '默认 Clash.Meta Tokiboshi/$kAndroidAppVersion'
                        : c.data.desktop.userAgent,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: c.busy ? null : editAgent,
                ),
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.shield_outlined),
                  title: const Text('Android VPN 设置'),
                  subtitle: const Text('应用排除、网卡 MTU、系统 VPN 与通知'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => AndroidVpnSettings(controller: c))),
                ),
              ],
            ),
            order: 1,
          ),
          section(
            '工具与关于',
            Column(
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.route),
                  title: const Text('分流规则'),
                  onTap: showRules,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.swap_vert),
                  title: const Text('当前请求'),
                  onTap: showConnections,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.terminal),
                  title: const Text('运行日志'),
                  onTap: showLogs,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.tune),
                  title: const Text('分流、DNS 与测速'),
                  onTap: c.busy ? null : showClientSettings,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.save_alt),
                  title: const Text('导出配置备份'),
                  onTap: c.busy ? null : exportBackup,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.restore),
                  title: const Text('恢复配置备份'),
                  subtitle: c.running ? const Text('断开 VPN 后可恢复') : null,
                  onTap: c.busy || c.running ? null : restoreBackup,
                ),
                const Divider(),
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(kInAppName),
                  subtitle: Text(
                    'Android $kAndroidAppVersion · build $kAndroidBuild\nsing-box / libbox 1.14.4',
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('项目与下载'),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => androidVpnChannel.invokeMethod<void>('openUrl', {
                    'url':
                        'https://github.com/kurumiZafkiel12/Tokiboshi/releases',
                  }),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('开源许可证'),
                  trailing: const Icon(Icons.description_outlined),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: kInAppName,
                    applicationVersion: '$kAndroidAppVersion · Android',
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Android 构建依赖 sing-box / libbox，按 GPL-3.0 分发；源码、许可证与校验文件见项目仓库。',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
            order: 2,
          ),
        ],
      );
  Widget empty(
    IconData icon,
    String title,
    String subtitle, {
    Widget? action,
  }) =>
      Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 42, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                title,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              Text(subtitle, textAlign: TextAlign.center),
              if (action != null) ...[const SizedBox(height: 18), action],
            ],
          ),
        ),
      );
  Future<void> editSub(Subscription s) async {
    await editSubscription(context, s,
        mobile: true, onSave: (next) => c.editSource(s, next));
  }

  Future<void> editAgent() async {
    final text = TextEditingController(text: c.data.desktop.userAgent);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('订阅 User-Agent'),
        content: TextField(
          controller: text,
          decoration: const InputDecoration(hintText: '留空使用默认值'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, text.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    text.dispose();
    if (value != null) c.saveOptions(userAgent: value);
  }

  void showRules() {
    String body;
    if (c.running)
      body = c.rules.map((r) => jsonEncode(r)).join('\n\n');
    else {
      try {
        final profile = activeProfile(c.data);
        body = profile?.profileJson ?? '当前使用内置模板。实际运行规则在连接后由内核返回。';
      } catch (e) {
        body = '$e';
      }
    }
    info(c.running ? '内核运行规则' : '已保存配置预览', body.isEmpty ? '当前没有运行规则' : body);
  }

  void showLogs() =>
      info('运行日志', c.logs.isEmpty ? '暂无内核运行日志。' : c.logs.join('\n'));
  void showClientSettings() => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('分流、DNS 与测速')),
            body: SafeArea(
              child: ListenableBuilder(
                listenable: c,
                builder: (_, __) => ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    ClientSettings(
                      mobile: true,
                      value: c.data.client,
                      busy: c.busy,
                      onSave: c.saveClient,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  Future<void> exportBackup() async {
    if (!await confirm('备份包含订阅地址及节点凭据。确认导出到你选择的文件位置？') || !mounted) return;
    Directory? temp;
    try {
      temp = await c.store.dir.createTemp('backup-export-');
      final file = File('${temp.path}/backup.json');
      await file.writeAsString(encodeBackup(c.data), flush: true);
      final saved = await androidVpnChannel.invokeMethod<bool>('exportBackup', {
        'path': file.path,
      });
      if (saved == true) c.report('配置备份已导出');
    } catch (error) {
      c.report('导出失败：$error');
    } finally {
      await temp?.delete(recursive: true);
    }
  }

  Future<void> restoreBackup() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: '配置备份',
            mimeTypes: ['application/json'],
            extensions: ['json'],
          ),
          const XTypeGroup(label: '所有文件'),
        ],
      );
      if (file == null || !mounted) return;
      if (await file.length() > backupMaxBytes)
        throw const FormatException('备份文件超过 64 MiB');
      final restored = decodeBackup(await file.readAsString(), c.data);
      if (!mounted ||
          !await confirm(
            '用备份中的 ${restored.nodes.where((node) => !node.isPolicy).length} 个节点和 ${restored.subscriptions.length} 个来源替换当前配置？恢复后保持断开。',
          )) return;
      await c.restoreData(restored);
    } catch (error) {
      c.report('恢复失败：$error');
    }
  }

  void showConnections() => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('当前请求')),
            body: SafeArea(
              child: ListenableBuilder(
                listenable: c,
                builder: (_, __) => ConnectionsPage(
                  monitor: c.monitor,
                  running: c.running,
                  compact: true,
                ),
              ),
            ),
          ),
        ),
      );
  String bytes(int n) => n >= 1024 * 1024
      ? '${(n / 1024 / 1024).toStringAsFixed(1)} MiB'
      : n >= 1024
          ? '${(n / 1024).toStringAsFixed(1)} KiB'
          : '$n B';
}

/// Keep mobile ink effects above the card decoration.
class MobilePanel extends StatelessWidget {
  const MobilePanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.accent = false,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool accent;
  @override
  Widget build(BuildContext context) => Panel(
        padding: padding,
        accent: accent,
        child: Material(type: MaterialType.transparency, child: child),
      );
}
