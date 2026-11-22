import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../services/clash_api.dart';
import '../services/store.dart';
import '../services/client_preferences.dart';
import '../services/rule_resources.dart';
import '../ui/design.dart';

class RulesPage extends StatefulWidget {
  const RulesPage(
      {super.key,
      required this.subscriptions,
      required this.running,
      required this.busy,
      required this.api,
      required this.onApply,
      required this.onSources,
      required this.blockAds,
      required this.bypassCn,
      this.templateRouting = const {},
      this.targets = const {},
      this.ruleResources = const [],
      this.onResources,
      this.onTemplateRouting,
      this.activeProcesses = const [],
      this.onAddProcessRule,
      this.dataDir,
      this.activeProfileId,
      this.customRules = const [],
      this.onEdit});
  final List<Subscription> subscriptions;
  final bool running, busy, blockAds, bypassCn;
  final ClashApiClient api;
  final VoidCallback onApply, onSources;
  final List<RoutingRule> customRules;
  final VoidCallback? onEdit;
  final String? dataDir;
  final String? activeProfileId;

  /// 内置模板规则的用户配置（见 Store.templateRouting 注释）。
  final Map<String, String> templateRouting;
  final Map<String, String> targets;
  final List<RuleResource> ruleResources;
  final VoidCallback? onResources;
  final void Function(String id, String value)? onTemplateRouting;

  /// 活跃进程（来自内核连接元数据；内核未启用进程识别时为空）。
  final List<String> activeProcesses;
  final void Function(String process, String target)? onAddProcessRule;
  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> {
  List<Map<String, dynamic>>? _rules;
  String? _error;
  int? _ready;
  Timer? _timer;
  bool _fetching = false;
  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void didUpdateWidget(covariant RulesPage old) {
    super.didUpdateWidget(old);
    if (old.running != widget.running || old.api.port != widget.api.port)
      _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_fetching) return;
    _fetching = true;
    try {
      if (widget.dataDir != null) {
        var ready = 0;
        for (final name in const [
          'geosite-category-ads-all.srs',
          'geosite-cn.srs',
          'geoip-cn.srs'
        ]) {
          if (await File(
                  '${widget.dataDir}${Platform.pathSeparator}rules${Platform.pathSeparator}$name')
              .exists()) ready++;
        }
        if (mounted) setState(() => _ready = ready);
      }
      if (!widget.running) {
        if (mounted)
          setState(() {
            _rules = null;
            _error = null;
          });
        return;
      }
      final rules = await widget.api.rules();
      if (mounted && widget.running)
        setState(() {
          _rules = rules;
          _error = null;
        });
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取运行规则；下方仅显示已保存配置。');
    } finally {
      _fetching = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final profiles = widget.subscriptions
        .where((s) => s.profileJson != null && s.id == widget.activeProfileId)
        .toList();
    final conflict = widget.activeProfileId == null;
    Map<String, dynamic> profile = {};
    if (profiles.length == 1) {
      try {
        profile =
            jsonDecode(profiles.single.profileJson!) as Map<String, dynamic>;
      } catch (_) {}
    }
    final rows = <List<String>>[];
    final live = widget.running && _rules != null && _error == null;
    if (live) {
      for (final r in _rules!) {
        rows.add([
          '${r['type'] ?? '—'}',
          '${r['payload'] ?? ''}',
          '${r['proxy'] ?? '—'}',
          '运行内核'
        ]);
      }
    } else if (profile.isNotEmpty) {
      for (final raw in profile['route_rules'] as List? ?? []) {
        if (raw is Map) {
          final rule = Map<String, dynamic>.from(raw);
          final target =
              rule.remove('outbound') ?? rule.remove('action') ?? '—';
          rows.add([
            rule.keys.where((k) => !k.startsWith('__')).join(' + '),
            jsonEncode(rule),
            '$target',
            profiles.single.name
          ]);
        }
      }
      if (profile['final_outbound'] != null)
        rows.add([
          'FINAL',
          '其余流量',
          '${profile['final_outbound']}',
          profiles.single.name
        ]);
    } else if (profiles.isEmpty && !conflict) {
      rows.add(['IP-PRIVATE', '私有 / 局域网地址', 'DIRECT', '内置模板']);
      if (widget.blockAds)
        rows.add([
          'RULE-SET',
          'geosite-category-ads-all',
          'REJECT',
          '内置模板 · 依赖本地规则集'
        ]);
      if (widget.bypassCn) {
        rows.add(
            ['RULE-SET', 'geosite-cn / geoip-cn', 'DIRECT', '内置模板 · 依赖本地规则集']);
      }
      rows.add(['FINAL', '其余流量', 'proxy', '内置模板']);
    }
    if (!live)
      rows.insertAll(0, [
        for (final rule in widget.customRules.where((r) => r.enabled))
          [
            RoutingRule.kinds[rule.kind] ?? rule.kind,
            rule.value,
            rule.target,
            '应用自定义 · 待应用'
          ]
      ]);
    final unsupported =
        (profile['unsupported'] as List? ?? []).map((e) => '$e').toList();
    return SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PageHeading('分流规则', '按配置顺序匹配，展示来源与目标。',
              eyebrow: 'KNOW WHERE YOUR TRAFFIC GOES.',
              actions: [
                if (widget.onEdit != null)
                  OutlinedButton.icon(
                      onPressed: widget.busy ? null : widget.onEdit,
                      icon: const Icon(Icons.tune, size: 16),
                      label: const Text('自定义规则')),
                OutlinedButton.icon(
                    onPressed: widget.onSources,
                    icon: const Icon(Icons.inventory_2_outlined, size: 16),
                    label: const Text('查看来源')),
                FilledButton(
                    onPressed: widget.busy || conflict ? null : widget.onApply,
                    child: Text(widget.running ? '重启并应用配置' : '启动并应用配置'))
              ]),
          LayoutBuilder(
              builder: (context, c) =>
                  Wrap(spacing: 12, runSpacing: 12, children: [
                    _meta(
                        '规则来源',
                        conflict
                            ? '请选择配置'
                            : profiles.firstOrNull?.name ?? '内置分流模板',
                        profiles.isEmpty ? '仅节点订阅使用应用模板' : '订阅携带规则与 DNS',
                        c),
                    _meta('本地规则集', _ready == null ? '尚未读取' : '$_ready / 3 已缓存',
                        '文件已落盘；是否生效以下方运行规则为准', c),
                    _meta(
                        '应用状态',
                        live
                            ? '运行内核规则'
                            : widget.running
                                ? '尚未确认'
                                : '未运行',
                        live ? '已从当前控制器读取' : '下方为已保存配置预览，不代表已生效',
                        c),
                  ])),
          const SizedBox(height: 16),
          if (widget.onAddProcessRule != null)
            Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: _PerAppRoutingCard(
                  targets: widget.targets,
                  activeProcesses: widget.activeProcesses,
                  existing: widget.customRules
                      .where((rule) => rule.kind == 'process_name')
                      .toList(),
                  busy: widget.busy,
                  onAdd: widget.onAddProcessRule!,
                )),
          if (widget.onTemplateRouting != null && profiles.isEmpty && !conflict)
            Panel(
                padding: EdgeInsets.zero,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Padding(
                          padding: EdgeInsets.fromLTRB(18, 16, 18, 4),
                          child: Text('内置分流模板',
                              style: TextStyle(fontWeight: FontWeight.w600))),
                      const Padding(
                          padding: EdgeInsets.fromLTRB(18, 0, 18, 6),
                          child: Text('每条规则可单独开关并指定出口；改动后需重启内核生效。',
                              style:
                                  TextStyle(fontSize: 12, color: Colors.grey))),
                      for (final (id, title, desc) in const [
                        ('private', '私有 / 局域网直连', '私有地址与局域网流量'),
                        ('ads', '广告拦截', '广告域名拒绝（geosite-ads-all）'),
                        ('cn', '国内直连', '国内域名与 IP 直连（geosite-cn / geoip-cn）'),
                      ])
                        _TemplateRuleRow(
                          id: id,
                          title: title,
                          desc: desc,
                          allowReject: id == 'ads',
                          enabled: widget.templateRouting.containsKey(id)
                              ? widget.templateRouting[id] != 'off'
                              : id == 'ads'
                                  ? widget.blockAds
                                  : id == 'cn'
                                      ? widget.bypassCn
                                      : true,
                          outbound: widget.templateRouting[id] ?? 'default',
                          targets: widget.targets,
                          onChanged: (enabled, outbound) =>
                              widget.onTemplateRouting!(
                                  id, enabled ? outbound : 'off'),
                        ),
                    ])),
          if (widget.onTemplateRouting != null &&
              widget.ruleResources.isNotEmpty &&
              !conflict)
            Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Panel(
                  padding: EdgeInsets.zero,
                  child: ExpansionTile(
                    title: const Text('内置服务分流'),
                    subtitle: const Text('流媒体、AI、通讯与软件服务可各自选择出口'),
                    children: [
                      for (final resource in widget.ruleResources
                          .where((r) => serviceRuleNames.containsKey(r.tag)))
                        if (widget.dataDir != null &&
                            File(resource.path(widget.dataDir!)).existsSync())
                          _TemplateRuleRow(
                              id: resource.tag,
                              title: serviceRuleNames[resource.tag]!,
                              desc: resource.group,
                              allowReject: true,
                              targets: widget.targets,
                              enabled: (widget.templateRouting[resource.tag] ??
                                      'off') !=
                                  'off',
                              outbound: widget.templateRouting[resource.tag] ??
                                  'default',
                              onChanged: (enabled, outbound) =>
                                  widget.onTemplateRouting!(
                                      resource.tag, enabled ? outbound : 'off'))
                        else
                          ListTile(
                              title: Text(serviceRuleNames[resource.tag]!),
                              subtitle: const Text('需先下载本地规则集'),
                              trailing: TextButton(
                                  onPressed: widget.onResources,
                                  child: const Text('打开工具箱'))),
                    ],
                  ),
                )),
          const SizedBox(height: 16),
          if (conflict || _error != null || unsupported.isNotEmpty)
            Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Panel(
                    accent: true,
                    child: Text(
                        conflict
                            ? '未指定有效激活配置，请在工作台选择来源；启动会拒绝隐式切换。'
                            : _error ??
                                '存在 ${unsupported.length} 项不兼容配置：\n${unsupported.join('\n')}',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.error)))),
          Panel(
              padding: EdgeInsets.zero,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                        padding: const EdgeInsets.all(18),
                        child: Row(children: [
                          Text('规则顺序  ${rows.length}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                          const Spacer(),
                          Text('FIRST MATCH WINS',
                              style: mono.copyWith(fontSize: 9))
                        ])),
                    if (rows.isEmpty)
                      const Padding(
                          padding: EdgeInsets.all(30),
                          child: Text('当前没有可展示的规则'))
                    else
                      SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                              headingRowHeight: 39,
                              dataRowMinHeight: 45,
                              dataRowMaxHeight: 65,
                              columnSpacing: 24,
                              columns: [
                                for (final s in [
                                  '#',
                                  '匹配类型',
                                  '匹配内容',
                                  '目标',
                                  '来源'
                                ])
                                  DataColumn(
                                      label: Text(s,
                                          style: const TextStyle(fontSize: 11)))
                              ],
                              rows: [
                                for (var i = 0; i < rows.length; i++)
                                  DataRow(cells: [
                                    DataCell(Text('${i + 1}', style: mono)),
                                    for (var j = 0; j < 4; j++)
                                      DataCell(SizedBox(
                                          width: j == 1
                                              ? 260
                                              : j == 3
                                                  ? 160
                                                  : 110,
                                          child: Tooltip(
                                              message: rows[i][j],
                                              child: Text(rows[i][j],
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                      fontSize: 11,
                                                      fontFamily: j == 1
                                                          ? 'Consolas'
                                                          : null)))))
                                  ])
                              ])),
                    const Divider(height: 1),
                    Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                            live
                                ? '展示当前运行内核返回的规则。'
                                : '预览包含已保存配置；本地文件未就绪的内置规则不会被视为生效。',
                            style: Theme.of(context).textTheme.bodySmall))
                  ])),
          const SizedBox(height: 14),
          Text('规则模式按顺序命中；全局与直连模式会改变路由。订阅规则的兼容性诊断保留在来源详情。',
              style: Theme.of(context).textTheme.bodySmall)
        ]));
  }

  Widget _meta(String title, String value, String hint, BoxConstraints c) =>
      SizedBox(
          width: c.maxWidth < 730 ? c.maxWidth : (c.maxWidth - 24) / 3,
          child: Panel(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 9),
                Text(value,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 6),
                Text(hint, style: Theme.of(context).textTheme.bodySmall)
              ])));
}

/// 内置模板规则的可配置行：开关 + 出站选择。
class _TemplateRuleRow extends StatelessWidget {
  const _TemplateRuleRow({
    required this.id,
    required this.title,
    required this.desc,
    required this.allowReject,
    required this.enabled,
    required this.outbound,
    required this.targets,
    required this.onChanged,
  });
  final String id, title, desc;
  final bool allowReject, enabled;
  final String outbound;
  final Map<String, String> targets;
  final void Function(bool enabled, String outbound) onChanged;

  @override
  Widget build(BuildContext context) {
    // 节点可能已被删除：当前值不在可选项里时回退到"模板默认"。
    final options = <String, String>{
      'default': '模板默认',
      if (allowReject) 'reject': '拒绝',
      'direct': '直连',
      'proxy': '默认出口（proxy）',
      ...targets,
    };
    final current = options.containsKey(outbound) ? outbound : 'default';
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
        child: Row(children: [
          Switch(
              value: enabled,
              onChanged: (v) => onChanged(
                  v,
                  v
                      ? (options.containsKey(outbound) ? outbound : 'default')
                      : 'off')),
          const SizedBox(width: 4),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color:
                            enabled ? null : Theme.of(context).disabledColor)),
                Text(desc,
                    style: TextStyle(
                        fontSize: 11,
                        color: enabled
                            ? Colors.grey
                            : Theme.of(context).disabledColor)),
              ])),
          SizedBox(
              width: 160,
              child: DropdownButton<String>(
                  isExpanded: true,
                  value: enabled ? current : null,
                  hint: enabled ? null : const Text('已关闭'),
                  items: [
                    for (final e in options.entries)
                      DropdownMenuItem(
                          value: e.key,
                          child:
                              Text(e.value, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged:
                      enabled ? (v) => onChanged(true, v ?? 'default') : null)),
        ]));
  }
}

const _apps = <String, String>{
  'Chrome': 'chrome.exe',
  'Edge': 'msedge.exe',
  'Firefox': 'firefox.exe',
  'Brave': 'brave.exe',
  'Vivaldi': 'vivaldi.exe',
  'Discord': 'Discord.exe',
  'Telegram': 'Telegram.exe',
  '微信': 'WeChat.exe',
  'QQ': 'QQ.exe',
  'Slack': 'slack.exe',
  'Signal': 'Signal.exe',
  'Teams': 'ms-teams.exe',
  'VS Code': 'Code.exe',
  'Git': 'git.exe',
  'GitHub Desktop': 'GitHubDesktop.exe',
  'OneDrive': 'OneDrive.exe',
  'Dropbox': 'Dropbox.exe',
  'Postman': 'Postman.exe',
  'Spotify': 'Spotify.exe',
  'Steam': 'steam.exe',
  'Epic Games': 'EpicGamesLauncher.exe',
  'Battle.net': 'Battle.net.exe',
  'EA App': 'EADesktop.exe',
  'qBittorrent': 'qbittorrent.exe',
  'aria2': 'aria2c.exe',
};

class _PerAppRoutingCard extends StatefulWidget {
  const _PerAppRoutingCard({
    required this.targets,
    required this.activeProcesses,
    required this.existing,
    required this.onAdd,
    required this.busy,
  });
  final Map<String, String> targets;
  final List<String> activeProcesses;
  final List<RoutingRule> existing;
  final bool busy;
  final void Function(String process, String target) onAdd;
  @override
  State<_PerAppRoutingCard> createState() => _PerAppRoutingCardState();
}

class _PerAppRoutingCardState extends State<_PerAppRoutingCard> {
  final _process = TextEditingController();
  String _target = 'proxy';
  bool _catalog = true;

  @override
  void dispose() {
    _process.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final options = <String, String>{
      'proxy': '默认代理出口',
      'direct': '直连',
      'reject': '拒绝',
      ...widget.targets,
    };
    final selected = options.containsKey(_target) ? _target : 'proxy';
    return Panel(
        child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('按软件分流', style: Theme.of(context).textTheme.titleMedium),
              TextButton.icon(
                  onPressed: () => setState(() => _catalog = !_catalog),
                  icon: Icon(_catalog ? Icons.expand_less : Icons.expand_more),
                  label: Text(_catalog ? '收起应用' : '打开内置应用')),
            ]),
        if (_catalog)
          Wrap(spacing: 7, runSpacing: 7, children: [
            for (final app in _apps.entries)
              ActionChip(
                  label: Text(app.key),
                  onPressed: widget.busy
                      ? null
                      : () => setState(() => _process.text = app.value)),
          ]),
        const SizedBox(height: 12),
        if (widget.activeProcesses.isNotEmpty)
          Wrap(spacing: 7, children: [
            for (final proc in widget.activeProcesses.take(12))
              ActionChip(
                  avatar: const Icon(Icons.monitor_heart_outlined, size: 14),
                  label: Text(proc),
                  onPressed: widget.busy
                      ? null
                      : () => setState(() => _process.text = proc)),
          ]),
        Row(children: [
          Expanded(
              child: TextField(
                  controller: _process,
                  decoration: const InputDecoration(
                      labelText: '软件进程（exe）', hintText: '从上方选择或手工填写'))),
          const SizedBox(width: 10),
          Expanded(
              child: DropdownButton<String>(
                  value: selected,
                  isExpanded: true,
                  items: [
                    for (final option in options.entries)
                      DropdownMenuItem(
                          value: option.key,
                          child: Text(option.value,
                              overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: widget.busy
                      ? null
                      : (value) => setState(() => _target = value ?? 'proxy'))),
          const SizedBox(width: 10),
          FilledButton(
              onPressed: widget.busy
                  ? null
                  : () {
                      if (_process.text.trim().isNotEmpty)
                        widget.onAdd(_process.text.trim(), selected);
                    },
              child: const Text('保存分流')),
        ]),
        const SizedBox(height: 8),
        const Text('在规则模式和可识别进程的流量上匹配。保存后点「应用配置」，跟随常规规则可删除单项。'),
        for (final rule in widget.existing)
          ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(rule.value),
              subtitle: Text(options[rule.target] ??
                  (rule.target.startsWith('node:')
                      ? '出口已缺失或歧义，重新选择'
                      : rule.target)),
              onTap: widget.busy
                  ? null
                  : () => setState(() {
                        _process.text = rule.value;
                        _target = rule.target;
                      }),
              trailing: IconButton(
                  tooltip: '移除软件规则',
                  icon: const Icon(Icons.delete_outline),
                  onPressed:
                      widget.busy ? null : () => widget.onAdd(rule.value, ''))),
      ],
    ));
  }
}
