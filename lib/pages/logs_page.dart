import 'dart:async';

import 'package:flutter/material.dart';

/// Live core log view: polls the Rust log buffer while visible.
class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.fetchLogs});

  final Future<List<String>> Function() fetchLogs;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  List<String> _lines = const [];
  Timer? _timer;
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
    try {
      final lines = await widget.fetchLogs();
      if (!mounted) return;
      final grew = lines.length != _lines.length;
      setState(() => _lines = lines);
      if (grew && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    } catch (_) {
      // Logs are best-effort; the next tick retries.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Text('日志', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: _lines.isEmpty
              ? const Center(child: Text('暂无日志（内核未运行或尚无输出）'))
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  itemCount: _lines.length,
                  itemBuilder: (context, i) => SelectableText(
                    _lines[i],
                    style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                  ),
                ),
        ),
      ],
    );
  }
}
