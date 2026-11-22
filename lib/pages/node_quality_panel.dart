import 'package:flutter/material.dart';
import '../bridge/core_bridge.dart';
import '../ui/design.dart';
import '../ui/node_widgets.dart';

class NodeQualityPanel extends StatefulWidget {
  const NodeQualityPanel(
      {super.key, required this.node, required this.measure});
  final NodeInfo node;
  final Future<int?> Function(NodeInfo) measure;

  @override
  State<NodeQualityPanel> createState() => _NodeQualityPanelState();
}

class _NodeQualityPanelState extends State<NodeQualityPanel> {
  final _samples = <int?>[];
  bool _busy = false;
  int _run = 0;

  @override
  void didUpdateWidget(NodeQualityPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node != widget.node) {
      _run++;
      _samples.clear();
      _busy = false;
    }
  }

  Future<void> _start() async {
    final run = ++_run;
    final node = widget.node;
    setState(() {
      _samples.clear();
      _busy = true;
    });
    try {
      for (var i = 0; i < 5; i++) {
        int? delay;
        try {
          delay = await widget.measure(node);
        } catch (_) {
          // A failed sample remains visible without aborting the other requests.
        }
        if (!mounted || run != _run) return;
        setState(() => _samples.add(delay));
      }
    } finally {
      if (mounted && run == _run) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final delays = _samples.whereType<int>().toList()..sort();
    final middle = delays.length ~/ 2;
    final median = delays.isEmpty
        ? null
        : delays.length.isOdd
            ? delays[middle].toDouble()
            : (delays[middle - 1] + delays[middle]) / 2;
    final differences = [
      for (var i = 1; i < _samples.length; i++)
        if (_samples[i - 1] != null && _samples[i] != null)
          (_samples[i]! - _samples[i - 1]!).abs(),
    ];
    final jitter = differences.isEmpty
        ? null
        : differences.reduce((a, b) => a + b) / differences.length;
    return Panel(
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
      child: Wrap(
          spacing: 9,
          runSpacing: 7,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            RegionMark(widget.node),
            Text('节点质量 · ${widget.node.name}',
                overflow: TextOverflow.ellipsis, maxLines: 1),
            if (_samples.isNotEmpty) ...[
              Tag('${delays.length}/${_samples.length} 成功',
                  color: delays.isEmpty ? danger : good),
              if (median != null) Tag('中位数 ${median.toStringAsFixed(0)} ms'),
              if (jitter != null) Tag('抖动 ${jitter.toStringAsFixed(1)} ms'),
              for (final value in _samples)
                Tooltip(
                    message: value == null ? '请求失败或超时' : '$value ms',
                    child: Icon(
                        value == null
                            ? Icons.error_outline
                            : Icons.check_circle_outline,
                        size: 15,
                        color: value == null ? danger : good)),
            ],
            TextButton.icon(
                onPressed: _busy
                    ? () => setState(() {
                          _run++;
                          _busy = false;
                        })
                    : _start,
                icon: Icon(_busy ? Icons.stop_circle_outlined : Icons.speed,
                    size: 16),
                label: Text(_busy ? '取消' : '测量 5 次')),
          ]),
    );
  }
}
