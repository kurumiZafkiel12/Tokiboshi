import 'dart:async';
import 'package:flutter/material.dart';
import 'preferences.dart';

/// A bounded entrance, never an idle ticker. Reused controllers survive sorting.
class MotionEntrance extends StatefulWidget {
  const MotionEntrance({super.key, required this.child, this.order = 0});
  final Widget child;
  final int order;
  @override
  State<MotionEntrance> createState() => _MotionEntranceState();
}

class _MotionEntranceState extends State<MotionEntrance>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 300));
  late final CurvedAnimation _curve =
      CurvedAnimation(parent: _controller, curve: const Cubic(.16, 1, .3, 1));
  Timer? _delay;
  bool _started = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final duration = UiScope.duration(context, 300);
    if (duration == Duration.zero) {
      _delay?.cancel();
      _controller.stop();
      _controller.value = 1;
      _started = true;
      return;
    }
    if (_started) return;
    _started = true;
    _controller.duration = duration;
    final ui = UiScope.of(context);
    final ms = ui.motion == 'full' ? (widget.order * 18).clamp(0, 140) : 0;
    _delay = Timer(Duration(milliseconds: ms), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _delay?.cancel();
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = _curve;
    return FadeTransition(
        opacity: curve,
        child: SlideTransition(
            position: Tween(begin: const Offset(0, .025), end: Offset.zero)
                .animate(curve),
            child: widget.child));
  }
}

class MotionHover extends StatefulWidget {
  const MotionHover(
      {super.key, required this.child, this.enabled = true, this.lift = false});
  final Widget child;
  final bool enabled, lift;
  @override
  State<MotionHover> createState() => _MotionHoverState();
}

class _MotionHoverState extends State<MotionHover> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return MouseRegion(
        onEnter: (_) {
          if (widget.enabled) setState(() => _hover = true);
        },
        onExit: (_) {
          if (_hover) setState(() => _hover = false);
        },
        child: AnimatedSlide(
            duration: UiScope.duration(context, 180),
            curve: Curves.easeOutCubic,
            offset:
                widget.lift && _hover ? const Offset(0, -.008) : Offset.zero,
            child: AnimatedContainer(
                duration: UiScope.duration(context, 180),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(7),
                    color: _hover
                        ? color.withValues(alpha: .035)
                        : Colors.transparent,
                    boxShadow: widget.lift && _hover
                        ? [
                            BoxShadow(
                                color: color.withValues(alpha: .08),
                                blurRadius: 16,
                                spreadRadius: 0)
                          ]
                        : const []),
                child: widget.child)));
  }
}

class AnimatedMetric extends StatelessWidget {
  const AnimatedMetric(
      {super.key, required this.value, required this.format, this.style});
  final double value;
  final String Function(double) format;
  final TextStyle? style;
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
      tween: Tween(begin: value, end: value),
      duration: UiScope.duration(context, 340),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => Text(format(v), style: style));
}
