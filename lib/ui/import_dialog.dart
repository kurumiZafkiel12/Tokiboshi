import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/import_content.dart';
import '../services/import_io.dart';
import 'design.dart';
import 'preferences.dart';

enum ImportRouting { smart, nodesOnly, full }

class ImportRequest {
  const ImportRequest(
      {required this.text,
      this.name = '',
      this.routing = ImportRouting.smart,
      this.localPath,
      this.forceUrl = false,
      this.manual = false});
  final String text, name;
  final ImportRouting routing;
  final String? localPath;
  final bool forceUrl, manual;
}

class ImportDialog extends StatefulWidget {
  const ImportDialog(
      {super.key, this.io = const ImportIo(), this.initialMethod = 'link'});
  final ImportIo io;
  final String initialMethod;
  @override
  State<ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<ImportDialog> {
  late String _method = widget.initialMethod;
  final _name = TextEditingController(),
      _text = TextEditingController(),
      _server = TextEditingController(),
      _port = TextEditingController(text: '443'),
      _uuid = TextEditingController(),
      _password = TextEditingController(),
      _user = TextEditingController(),
      _sni = TextEditingController(),
      _advanced = TextEditingController();
  String _protocol = 'vless', _cipher = 'aes-128-gcm';
  bool _tls = true, _json = false, _working = false, _submitted = false;
  ImportRouting _routing = ImportRouting.smart;
  String? _path, _filename, _error, _fileContent;
  @override
  void dispose() {
    for (final c in [
      _name,
      _text,
      _server,
      _port,
      _uuid,
      _password,
      _user,
      _sni,
      _advanced
    ]) c.dispose();
    super.dispose();
  }

  Future<void> _read(Future<void> Function() action) async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted)
        setState(
            () => _error = e is FormatException ? e.message : '读取失败，请检查文件或剪贴板');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _file() => _read(() async {
        final file = await widget.io.readConfigFile();
        if (file == null) return;
        if (mounted)
          setState(() {
            _path = file.path;
            _filename = file.name;
            _fileContent = file.text;
            _text.text = file.text.length > 12000
                ? '${file.text.substring(0, 12000)}\n…（预览已截短，导入会使用完整文件）'
                : file.text;
            if (_name.text.isEmpty) _name.text = file.name;
          });
      });
  Future<void> _qr(bool clipboard) => _read(() async {
        final text = clipboard
            ? await widget.io.readClipboardQr()
            : await widget.io.readQrFile();
        if (text == null) {
          if (mounted) setState(() => _error = '剪贴板里没有二维码图片');
          return;
        }
        if (mounted) setState(() => _text.text = normalizeImportText(text));
      });
  Future<void> _clipboard() => _read(() async {
        final text = await widget.io.readClipboard();
        if (text == null || text.trim().isEmpty) {
          if (mounted) setState(() => _error = '剪贴板里没有可导入的文字或二维码');
          return;
        }
        if (mounted) setState(() => _text.text = normalizeImportText(text));
      });
  String _manual() {
    if (_json) {
      final value = jsonDecode(_advanced.text);
      if (value is! Map || value['type'] is! String)
        throw const FormatException('出站 JSON 需要 type 字段');
      return jsonEncode({
        'outbounds': [
          {
            ...value,
            'tag': _name.text.trim().isEmpty ? '自定义节点' : _name.text.trim()
          }
        ]
      });
    }
    final server = _server.text.trim(), port = int.tryParse(_port.text);
    if (server.isEmpty || port == null || port < 1 || port > 65535)
      throw const FormatException('请填写服务器与有效端口（1–65535）');
    final node = <String, dynamic>{
      'type': _protocol,
      'tag': _name.text.trim().isEmpty ? '自定义 $_protocol' : _name.text.trim(),
      'server': server,
      'server_port': port
    };
    if (['vless', 'vmess', 'tuic'].contains(_protocol)) {
      if (!RegExp(r'^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')
          .hasMatch(_uuid.text.trim()))
        throw const FormatException('请填写有效 UUID');
      node['uuid'] = _uuid.text.trim();
    }
    if (['shadowsocks', 'trojan', 'hysteria2', 'tuic', 'anytls']
            .contains(_protocol) &&
        _password.text.isEmpty) throw const FormatException('此协议需要密码');
    if (_password.text.isNotEmpty) node['password'] = _password.text;
    if (_user.text.isNotEmpty && ['socks', 'http'].contains(_protocol))
      node['username'] = _user.text;
    if (_protocol == 'shadowsocks') node['method'] = _cipher;
    if (_protocol == 'vmess') node['security'] = 'auto';
    if (_protocol == 'tuic') node['congestion_control'] = 'cubic';
    if (_tls || ['hysteria2', 'tuic', 'anytls'].contains(_protocol))
      node['tls'] = {
        'enabled': true,
        'server_name': _sni.text.trim().isEmpty ? server : _sni.text.trim(),
        if (_protocol == 'tuic') 'alpn': ['h3']
      };
    return jsonEncode({
      'outbounds': [node]
    });
  }

  void _submit() {
    if (_submitted || _working) return;
    try {
      if (_method == 'file' && (_path == null || _fileContent == null))
        throw const FormatException('请先选择配置文件');
      final text = _method == 'custom'
          ? _manual()
          : normalizeImportText(_method == 'file' ? _fileContent! : _text.text);
      if (text.isEmpty) throw const FormatException('请先填写或读取导入内容');
      if (_method == 'link') {
        for (final line in text.split('\n').where((s) => s.trim().isNotEmpty)) {
          if (!isSubscriptionUrl(normalizeImportText(line)) &&
              !RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://')
                  .hasMatch(normalizeImportText(line)))
            throw const FormatException('请填写有效的 HTTP/HTTPS 订阅地址或节点分享链接，每行一条');
        }
      }
      setState(() => _submitted = true);
      Navigator.pop(
          context,
          ImportRequest(
              text: text,
              name: _name.text.trim(),
              routing: _routing,
              localPath: _method == 'file' ? _path : null,
              manual: _method == 'custom',
              forceUrl: _method == 'link'));
    } catch (e) {
      setState(
          () => _error = e is FormatException ? e.message : '自定义 JSON 格式无效');
    }
  }

  Widget _field(String label, TextEditingController c,
          {bool secret = false, String? hint}) =>
      Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
              controller: c,
              obscureText: secret,
              decoration: InputDecoration(labelText: label, hintText: hint)));
  @override
  Widget build(BuildContext context) => Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: _PaneSize(
          child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxWidth: 820,
                  maxHeight: MediaQuery.sizeOf(context).height - 60),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                    padding: const EdgeInsets.fromLTRB(22, 16, 12, 12),
                    child: Row(children: [
                      const Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text('导入节点 / 订阅',
                                style: TextStyle(
                                    fontSize: 20, fontWeight: FontWeight.w600)),
                            SizedBox(height: 4),
                            Text('多种方式导入，兼容性与应用方式始终可见。',
                                style: TextStyle(fontSize: 11))
                          ])),
                      IconButton(
                          tooltip: '关闭导入',
                          onPressed:
                              _working ? null : () => Navigator.pop(context),
                          icon: const Icon(Icons.close))
                    ])),
                const Divider(height: 1),
                Flexible(
                    child: SingleChildScrollView(
                        padding: const EdgeInsets.all(22),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Wrap(spacing: 7, runSpacing: 7, children: [
                                for (final m in const [
                                  ('qr', '二维码', Icons.qr_code_2),
                                  ('file', '文件', Icons.upload_file_outlined),
                                  ('link', '链接', Icons.link),
                                  (
                                    'clipboard',
                                    '剪贴板 / 文本',
                                    Icons.content_paste
                                  ),
                                  ('custom', '自定义', Icons.tune)
                                ])
                                  ChoiceChip(
                                      avatar: Icon(m.$3, size: 16),
                                      label: Text(m.$2),
                                      selected: _method == m.$1,
                                      onSelected: _working
                                          ? null
                                          : (_) => setState(() {
                                                _method = m.$1;
                                                _error = null;
                                                if (_fileContent != null)
                                                  _text.clear();
                                                _path = null;
                                                _filename = null;
                                                _fileContent = null;
                                              }))
                              ]),
                              const SizedBox(height: 20),
                              _field('名称（可选）', _name),
                              if (_method == 'file') ...[
                                Panel(
                                    child: Row(children: [
                                  const Icon(Icons.description_outlined),
                                  const SizedBox(width: 12),
                                  Expanded(
                                      child: Text(
                                          _filename ??
                                              '选择 YAML / JSON / TXT / CONF 配置文件',
                                          style:
                                              const TextStyle(fontSize: 12))),
                                  OutlinedButton(
                                      onPressed: _working ? null : _file,
                                      child: const Text('选择文件'))
                                ])),
                                const SizedBox(height: 12),
                                const Text('远程节点源可展开；本地内容中的相对网络地址需要明确基准。',
                                    style: TextStyle(fontSize: 11)),
                                const SizedBox(height: 10)
                              ],
                              if (_method == 'qr') ...[
                                Panel(
                                    child: Column(children: [
                                  Icon(Icons.qr_code_2,
                                      size: 48,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary),
                                  const SizedBox(height: 12),
                                  const Text('二维码图片中的订阅或节点链接',
                                      style: TextStyle(fontSize: 13)),
                                  const SizedBox(height: 12),
                                  Wrap(spacing: 9, runSpacing: 8, children: [
                                    OutlinedButton.icon(
                                        onPressed:
                                            _working ? null : () => _qr(false),
                                        icon: const Icon(Icons.image_outlined,
                                            size: 16),
                                        label: const Text('选择二维码图片')),
                                    OutlinedButton.icon(
                                        onPressed:
                                            _working ? null : () => _qr(true),
                                        icon: const Icon(Icons.content_paste,
                                            size: 16),
                                        label: const Text('读取剪贴板图片'))
                                  ])
                                ])),
                                const SizedBox(height: 14)
                              ],
                              if (_method == 'custom') ...[
                                SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('高级出站 JSON',
                                        style: TextStyle(fontSize: 13)),
                                    subtitle: const Text(
                                        '支持直接填写 sing-box 出站对象。',
                                        style: TextStyle(fontSize: 11)),
                                    value: _json,
                                    onChanged: (v) =>
                                        setState(() => _json = v)),
                                if (_json)
                                  TextField(
                                      controller: _advanced,
                                      maxLines: 8,
                                      decoration: const InputDecoration(
                                          labelText: '出站 JSON',
                                          hintText:
                                              '{"type":"socks","server":"127.0.0.1","server_port":1080}'))
                                else ...[
                                  DropdownButtonFormField<String>(
                                      initialValue: _protocol,
                                      decoration: const InputDecoration(
                                          labelText: '协议'),
                                      items: [
                                        for (final t in [
                                          'vless',
                                          'vmess',
                                          'trojan',
                                          'hysteria2',
                                          'shadowsocks',
                                          'socks',
                                          'http',
                                          'tuic',
                                          'anytls'
                                        ])
                                          DropdownMenuItem(
                                              value: t,
                                              child: Text(t.toUpperCase()))
                                      ],
                                      onChanged: (v) => setState(() {
                                            _protocol = v!;
                                            _tls = [
                                              'vless',
                                              'vmess',
                                              'trojan',
                                              'hysteria2',
                                              'tuic',
                                              'anytls'
                                            ].contains(v);
                                          })),
                                  const SizedBox(height: 12),
                                  Row(children: [
                                    Expanded(
                                        flex: 3, child: _field('服务器', _server)),
                                    const SizedBox(width: 12),
                                    Expanded(child: _field('端口', _port))
                                  ]),
                                  if (['vless', 'vmess', 'tuic']
                                      .contains(_protocol))
                                    _field('UUID', _uuid),
                                  if (['socks', 'http'].contains(_protocol))
                                    _field('用户名（可选）', _user),
                                  if (!['vless', 'vmess'].contains(_protocol))
                                    _field(
                                        ['socks', 'http'].contains(_protocol)
                                            ? '密码（可选）'
                                            : '密码',
                                        _password,
                                        secret: true),
                                  if (_protocol == 'shadowsocks') ...[
                                    DropdownButtonFormField<String>(
                                        initialValue: _cipher,
                                        decoration: const InputDecoration(
                                            labelText: '加密方法'),
                                        items: [
                                          for (final m in [
                                            'aes-128-gcm',
                                            'aes-256-gcm',
                                            'chacha20-ietf-poly1305',
                                            '2022-blake3-aes-128-gcm',
                                            '2022-blake3-aes-256-gcm'
                                          ])
                                            DropdownMenuItem(
                                                value: m, child: Text(m))
                                        ],
                                        onChanged: (v) =>
                                            setState(() => _cipher = v!)),
                                    const SizedBox(height: 12)
                                  ],
                                  SwitchListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: const Text('TLS',
                                          style: TextStyle(fontSize: 13)),
                                      value: _tls,
                                      onChanged: ['hysteria2', 'tuic', 'anytls']
                                              .contains(_protocol)
                                          ? null
                                          : (v) => setState(() => _tls = v)),
                                  if (_tls) _field('SNI（可选，默认服务器）', _sni),
                                ]
                              ] else ...[
                                if (['link', 'clipboard'].contains(_method))
                                  Align(
                                      alignment: Alignment.centerRight,
                                      child: TextButton.icon(
                                          onPressed:
                                              _working ? null : _clipboard,
                                          icon: const Icon(Icons.content_paste,
                                              size: 15),
                                          label: const Text('从剪贴板读取'))),
                                TextField(
                                    controller: _text,
                                    readOnly:
                                        _method == 'file' && _path != null,
                                    maxLines: _method == 'link' ? 4 : 7,
                                    minLines: 3,
                                    decoration: InputDecoration(
                                        labelText: _method == 'link'
                                            ? '订阅 / 节点链接（每行一个）'
                                            : '导入内容',
                                        hintText: _method == 'link'
                                            ? 'https://example.com/subscription\n可粘贴 Markdown 或客户端导入链接'
                                            : '分享链接 / Base64 / Clash YAML / sing-box JSON')),
                              ],
                              const SizedBox(height: 18),
                              DropdownButtonFormField<ImportRouting>(
                                  initialValue: _routing,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                      labelText: '导入规则方式'),
                                  items: [
                                    DropdownMenuItem(
                                        value: ImportRouting.smart,
                                        child: Text(
                                            MediaQuery.sizeOf(context).width <
                                                    600
                                                ? '智能（不兼容时询问）'
                                                : '智能：兼容时使用完整配置，不兼容时询问')),
                                    DropdownMenuItem(
                                        value: ImportRouting.nodesOnly,
                                        child: Text(
                                            MediaQuery.sizeOf(context).width <
                                                    600
                                                ? '仅节点（不使用规则 / DNS）'
                                                : '仅导入节点（不使用来源的规则 / DNS）')),
                                    DropdownMenuItem(
                                        value: ImportRouting.full,
                                        child: Text(
                                            MediaQuery.sizeOf(context).width <
                                                    600
                                                ? '完整配置（不兼容时拒绝）'
                                                : '完整配置（不兼容时保留原配置并报告）'))
                                  ],
                                  onChanged: _working
                                      ? null
                                      : (v) => setState(() => _routing = v!)),
                              if (_working) ...[
                                const SizedBox(height: 12),
                                const LinearProgressIndicator(minHeight: 2)
                              ],
                              if (_error != null) ...[
                                const SizedBox(height: 12),
                                Text(_error!,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error))
                              ],
                            ]))),
                const Divider(height: 1),
                Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(children: [
                      Expanded(
                          child: Text('导入前不会更改已有连接或配置。',
                              style: Theme.of(context).textTheme.bodySmall)),
                      TextButton(
                          onPressed:
                              _working ? null : () => Navigator.pop(context),
                          child: const Text('取消')),
                      const SizedBox(width: 8),
                      FilledButton(
                          onPressed: _working || _submitted ? null : _submit,
                          child: const Text('导入'))
                    ]))
              ]))));
}

/// Avoid Flutter RenderAnimatedSize zero-duration relayout during reduced motion.
class _PaneSize extends StatelessWidget {
  const _PaneSize({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final duration = UiScope.duration(context, 240);
    if (duration == Duration.zero) return child;
    return AnimatedSize(
        duration: duration,
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: child);
  }
}
