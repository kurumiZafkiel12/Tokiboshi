import 'dart:math' as math;
import 'dart:ui' show lerpDouble;
import 'package:flutter/material.dart';
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
