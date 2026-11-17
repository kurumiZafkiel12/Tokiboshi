import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../ui/design.dart';
import '../ui/diagnostics.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.fetchLogs, this.onExport});
  final Future<List<String>> Function() fetchLogs;
  final Future<String> Function(String)? onExport;
  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  List<String> _lines = [], _cleared = [];
  String _level = 'ALL', _query = '';
  Timer? _timer;
  bool _follow = true, _fetching = false;
  String? _error;
  final _scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_fetching) return;
    _fetching = true;
    try {
      final lines = (await widget.fetchLogs()).map(redactDiagnostics).toList();
      if (!mounted) return;
      final changed = lines.length != _lines.length ||
          (lines.isNotEmpty && (_lines.isEmpty || lines.last != _lines.last));
      if (changed) {
        setState(() {
          _lines = lines;
          _error = null;
        });
        if (_follow)
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _scroll.hasClients)
              _scroll.jumpTo(_scroll.position.maxScrollExtent);
          });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '日志读取失败，正在重试。');
    } finally {
      _fetching = false;
    }
  }

  List<String> get _visible {
    var start = 0;
    if (_cleared.isNotEmpty) {
      final match = _lines.indexOf(_cleared.last);
      if (match >= 0)
        start = match + 1;
      else if (_cleared.length == _lines.length &&
          _lines.isNotEmpty &&
          _cleared.last == _lines.last) start = _lines.length;
    }
    return _lines
        .skip(start)
        .where((s) =>
            (_level == 'ALL' || s.toUpperCase().contains(_level)) &&
            s.toLowerCase().contains(_query))
        .toList();
  }

  Future<void> _export() async {
    final text = _visible.join('\n');
    if (widget.onExport == null) {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已复制脱敏日志')));
      return;
    }
    try {
      final path = await widget.onExport!(text);
      if (mounted)
        showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('日志已导出'),
                    content: SelectableText(path),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('关闭'))
                    ]));
    } catch (_) {
      if (mounted) setState(() => _error = '日志导出失败，请检查写入权限。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = _visible;
    return Padding(
        padding: const EdgeInsets.all(22),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PageHeading('运行日志', '诊断持续可见，敏感链接和凭据默认隐藏。',
              eyebrow: 'THE DETAILS THAT MATTER.',
              actions: [
                OutlinedButton.icon(
                    onPressed: lines.isEmpty ? null : _export,
                    icon: const Icon(Icons.download_outlined, size: 16),
                    label: const Text('导出')),
                OutlinedButton(
                    onPressed: () => setState(() => _cleared = List.of(_lines)),
                    child: const Text('清空视图'))
              ]),
          Wrap(
              spacing: 8,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final level in ['ALL', 'INFO', 'WARN', 'ERROR'])
                  ChoiceChip(
                      label: Text(level == 'ALL' ? '全部' : level),
                      selected: _level == level,
                      onSelected: (_) => setState(() => _level = level)),
                SizedBox(
                    width: 250,
                    child: TextField(
                        decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.search, size: 16),
                            hintText: '搜索日志…'),
                        onChanged: (v) =>
                            setState(() => _query = v.toLowerCase()))),
                FilterChip(
                    label: const Text('自动跟随'),
                    selected: _follow,
                    onSelected: (v) => setState(() => _follow = v))
              ]),
          const SizedBox(height: 14),
          if (_error != null)
            Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          Expanded(
              child: Panel(
                  padding: EdgeInsets.zero,
                  child: lines.isEmpty
                      ? const EmptyView('暂无匹配日志', '内核输出和错误会显示在这里。',
                          icon: Icons.terminal_outlined)
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.all(16),
                          itemCount: lines.length,
                          itemBuilder: (context, i) {
                            final line = lines[i], upper = line.toUpperCase();
                            final error = upper.contains('ERROR') ||
                                    upper.contains('FATAL'),
                                warn = upper.contains('WARN');
                            return Container(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 6),
                                decoration: BoxDecoration(
                                    border: Border(
                                        bottom: BorderSide(
                                            color: Theme.of(context)
                                                .dividerColor
                                                .withValues(alpha: .3)))),
                                child: SelectableText(line,
                                    style: mono.copyWith(
                                        fontSize: 11,
                                        height: 1.6,
                                        color: error
                                            ? Theme.of(context)
                                                .colorScheme
                                                .error
                                            : warn
                                                ? gold
                                                : Theme.of(context)
                                                    .colorScheme
                                                    .onSurfaceVariant)));
                          }))),
          const SizedBox(height: 9),
          Row(children: [
            Text('显示 ${lines.length} 条',
                style: Theme.of(context).textTheme.bodySmall),
            const Spacer(),
            Text('清空仅影响视图 · 导出自动脱敏',
                style: Theme.of(context).textTheme.bodySmall)
          ])
        ]));
  }
}
