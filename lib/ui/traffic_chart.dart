import 'dart:math' as math;
import 'dart:ui' show lerpDouble;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'preferences.dart';
import 'design.dart';

class SmoothTrafficChart extends StatefulWidget {
  const SmoothTrafficChart({super.key, required this.down, required this.up});
  final List<double> down, up;
  @override
  State<SmoothTrafficChart> createState() => _SmoothTrafficChartState();
}

class _SmoothTrafficChartState extends State<SmoothTrafficChart>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 340), value: 1);
  List<double> _previousDown = [], _previousUp = [];
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = UiScope.duration(context, 340);
    if (_controller.duration == Duration.zero) {
      _controller.stop();
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant SmoothTrafficChart old) {
    super.didUpdateWidget(old);
    if (old.down != widget.down || old.up != widget.up) {
      _previousDown = old.down;
      _previousUp = old.up;
      if (UiScope.duration(context) == Duration.zero) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
      label: '真实流量采样曲线',
      child: RepaintBoundary(
          child: CustomPaint(
              painter: _TrafficPainter(
                  widget.down,
                  widget.up,
                  _previousDown,
                  _previousUp,
                  _controller,
                  Theme.of(context).colorScheme.primary,
                  Theme.of(context).dividerColor))));
}

class _TrafficPainter extends CustomPainter {
  _TrafficPainter(this.down, this.up, this.oldDown, this.oldUp, this.animation,
      this.color, this.grid)
      : super(repaint: animation);
  final List<double> down, up, oldDown, oldUp;
  final Animation<double> animation;
  final Color color, grid;
  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final largest = math.max(
        1024.0, [...down, ...up, ...oldDown, ...oldUp, 0.0].reduce(math.max));
    for (var i = 1; i <= 3; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(
          Offset(0, y),
          Offset(size.width, y),
          Paint()
            ..color = grid.withValues(alpha: .25)
            ..strokeWidth = .5);
    }
    final progress = Curves.easeOutCubic.transform(animation.value);
    for (final series in [(down, oldDown, color), (up, oldUp, gold)]) {
      final path = Path();
      final count = math.max(2, series.$1.length);
      double sample(List<double> values, int i) =>
          values.isEmpty ? 0 : values[math.min(i, values.length - 1)];
      for (var i = 0; i < count; i++) {
        final x = i / (count - 1) * size.width;
        final v =
            lerpDouble(sample(series.$2, i), sample(series.$1, i), progress)!;
        final y = size.height - 1 - v / largest * (size.height - 3);
        if (i == 0)
          path.moveTo(x, y);
        else
          path.lineTo(x, y);
      }
      final fill = Path.from(path)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(
          fill,
          Paint()
            ..shader = LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  series.$3.withValues(alpha: .11),
                  series.$3.withValues(alpha: 0)
                ]).createShader(Offset.zero & size));
      canvas.drawPath(
          path,
          Paint()
            ..color = series.$3.withValues(alpha: .18)
            ..strokeWidth = 3
            ..style = PaintingStyle.stroke
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
      canvas.drawPath(
          path,
          Paint()
            ..color = series.$3.withValues(alpha: .86)
            ..strokeWidth = 1.25
            ..style = PaintingStyle.stroke);
    }
  }

  @override
  bool shouldRepaint(_TrafficPainter old) =>
      down != old.down ||
      up != old.up ||
      color != old.color ||
      grid != old.grid;
}

/// A small readout for a shared sample index, available to mouse and keyboard.
class TrafficReadout extends StatefulWidget {
  const TrafficReadout(
      {super.key,
      required this.down,
      required this.up,
      this.throughput = false});
  final List<double> down, up;
  final bool throughput;
  @override
  State<TrafficReadout> createState() => _TrafficReadoutState();
}

class _TrafficReadoutState extends State<TrafficReadout> {
  double? _cursor;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final down = widget.down, up = widget.up;
    final count = math.max(down.length, up.length);
    String value(double raw) => widget.throughput
        ? '${(raw * 8 / 1000000).toStringAsFixed(1)} Mb/s'
        : '${bytesLabel(raw)}/s';
    final max = [...down, ...up, 1024.0].reduce(math.max);
    if (count == 0) return const Center(child: Text('暂无有效采样'));
    final index = ((_cursor ?? 1.0) * (count - 1)).round();
    String at(List<double> values) =>
        index < values.length ? value(values[index]) : '—';
    void nudge(int offset) => setState(() => _cursor =
        ((index + offset).clamp(0, count - 1)) / math.max(1, count - 1));
    final caption = '↓ ${at(down)}   ↑ ${at(up)}';
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => nudge(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => nudge(1),
      },
      child: Focus(
        onFocusChange: (value) => setState(() {
          _focused = value;
          if (!value) _cursor = null;
        }),
        child: Semantics(
            label: '流量采样 $caption',
            child: LayoutBuilder(
              builder: (context, bounds) => MouseRegion(
                onHover: (event) => setState(() => _cursor =
                    (event.localPosition.dx / math.max(1, bounds.maxWidth))
                        .clamp(0, 1)
                        .toDouble()),
                onExit: (_) => setState(() => _cursor = null),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                      border: _focused
                          ? Border.all(
                              color: Theme.of(context).colorScheme.primary)
                          : null,
                      borderRadius: BorderRadius.circular(5)),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(children: [
                          Text(value(max),
                              style: Theme.of(context).textTheme.labelSmall),
                          const SizedBox(width: 7),
                          Expanded(
                              child: Text(caption,
                                  textAlign: TextAlign.right,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style:
                                      Theme.of(context).textTheme.labelSmall)),
                        ]),
                        Expanded(child: SmoothTrafficChart(down: down, up: up)),
                        Text(
                            _cursor == null
                                ? '最近采样 → 当前'
                                : '样本 ${index + 1}/$count',
                            style: Theme.of(context).textTheme.labelSmall),
                      ]),
                ),
              ),
            )),
      ),
    );
  }
}
