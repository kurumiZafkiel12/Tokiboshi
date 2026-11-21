import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'preferences.dart';

const brand = Color(0xFFFFB1C0);
const wine = Color(0xFFB83B5E);
const gold = Color(0xFFDBBB80);
const good = Color(0xFF60DCB2);
const danger = Color(0xFFF19592);
const mono = TextStyle(
    fontFamily: 'Cascadia Code',
    fontFamilyFallback: ['Consolas', 'monospace'],
    fontSize: 11);

ThemeData workbenchTheme(UiPreferences ui) {
  final light = ui.light;
  final character = ui.character;
  // Clash Party 语言：深色近黑底 + 中性层次面 + 大圆角；品牌粉更饱和。
  final bg = light
      ? (character ? const Color(0xFFF6F2F5) : const Color(0xFFF2F3F6))
      : (character ? const Color(0xFF121016) : const Color(0xFF0F1014));
  final surface = light
      ? const Color(0xFFFFFFFF)
      : (character ? const Color(0xFF1C1A22) : const Color(0xFF181A20));
  final surfaceLow = light
      ? const Color(0xFFFBF8FA)
      : (character ? const Color(0xFF16141B) : const Color(0xFF121318));
  final surfaceHigh = light
      ? const Color(0xFFF3E8EE)
      : (character ? const Color(0xFF262430) : const Color(0xFF24272F));
  final line = light
      ? const Color(0xFFE4D3DC)
      : (character ? const Color(0xFF2E2A38) : const Color(0xFF262A33));
  final ink = light ? const Color(0xFF2E2027) : const Color(0xFFF4F1F4);
  final sub = light ? const Color(0xFF7A5F6E) : const Color(0xFF9C93A3);
  final accent = light ? const Color(0xFFC23A66) : const Color(0xFFFF8FA8);
  final scheme = ColorScheme.fromSeed(
          seedColor: wine,
          brightness: light ? Brightness.light : Brightness.dark)
      .copyWith(
          primary: accent,
          onPrimary: light ? Colors.white : const Color(0xFF20101A),
          primaryContainer: wine.withValues(alpha: light ? .10 : .18),
          surface: surface,
          onSurface: ink,
          onSurfaceVariant: sub,
          outline: line,
          outlineVariant: line.withValues(alpha: .65),
          error: light ? const Color(0xFFB3473B) : danger,
          surfaceContainerLow: surfaceLow,
          surfaceContainerHighest: surfaceHigh);
  const radius = BorderRadius.all(Radius.circular(14));
  const radiusLg = BorderRadius.all(Radius.circular(18));
  return ThemeData(
      useMaterial3: true,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      brightness: scheme.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      fontFamily: 'Segoe UI',
      fontFamilyFallback: const [
        'Microsoft YaHei',
        'Noto Sans CJK SC',
        'sans-serif'
      ],
      textTheme: Typography.material2021()
          .black
          .apply(bodyColor: ink, displayColor: ink)
          .copyWith(
              bodyMedium: TextStyle(fontSize: 14, color: ink, height: 1.5),
              bodySmall: TextStyle(fontSize: 12, color: sub, height: 1.5),
              titleMedium: TextStyle(
                  fontSize: 14, color: ink, fontWeight: FontWeight.w600),
              labelLarge: TextStyle(
                  fontSize: 12, color: ink, fontWeight: FontWeight.w500))
          .apply(fontFamily: 'Segoe UI', fontFamilyFallback: const [
        'Microsoft YaHei',
        'Noto Sans CJK SC',
        'sans-serif'
      ]),
      dividerColor: line,
      splashFactory: InkSparkle.splashFactory,
      cardTheme: CardThemeData(
          color: surface,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: BorderSide(
                  color: light ? line : line.withValues(alpha: .55)))),
      inputDecorationTheme: InputDecorationTheme(
          isDense: true,
          filled: true,
          fillColor: surfaceLow,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          border: OutlineInputBorder(
              borderRadius: radius, borderSide: BorderSide(color: line)),
          enabledBorder: OutlineInputBorder(
              borderRadius: radius, borderSide: BorderSide(color: line)),
          focusedBorder: OutlineInputBorder(
              borderRadius: radius, borderSide: BorderSide(color: accent)),
          hintStyle: TextStyle(fontSize: 12, color: sub)),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
              backgroundColor: light ? wine : const Color(0xFFF45B87),
              foregroundColor: Colors.white,
              textStyle: const TextStyle(fontFamily: 'Segoe UI', fontSize: 12),
              minimumSize: const Size(36, 38),
              shape: RoundedRectangleBorder(borderRadius: radius),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10))),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
              foregroundColor: ink,
              textStyle: const TextStyle(fontFamily: 'Segoe UI', fontSize: 12),
              minimumSize: const Size(36, 36),
              side: BorderSide(color: line),
              shape: RoundedRectangleBorder(borderRadius: radius))),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: accent, textStyle: const TextStyle(fontFamily: 'Segoe UI', fontSize: 12))),
      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: sub, iconSize: 18, shape: RoundedRectangleBorder(borderRadius: radius))),
      switchTheme: SwitchThemeData(thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : sub), trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? (light ? wine : const Color(0xFFF45B87)) : line)),
      chipTheme: ChipThemeData(backgroundColor: surfaceLow, selectedColor: (light ? wine : const Color(0xFFF45B87)).withValues(alpha: .28), side: BorderSide(color: line.withValues(alpha: .8)), shape: const StadiumBorder(), labelStyle: TextStyle(fontFamily: 'Segoe UI', fontSize: 11, color: ink), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, width: 420),
      dialogTheme: DialogThemeData(backgroundColor: surface, shape: RoundedRectangleBorder(borderRadius: radiusLg, side: BorderSide(color: line.withValues(alpha: .55)))),
      tooltipTheme: TooltipThemeData(decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: radius, border: Border.all(color: line)), textStyle: TextStyle(fontSize: 11, color: ink)));
}

class Panel extends StatelessWidget {
  const Panel(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(16),
      this.accent = false});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool accent;
  @override
  Widget build(BuildContext context) => Container(
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: accent
                  ? Theme.of(context).colorScheme.primary.withValues(alpha: .38)
                  : Theme.of(context)
                      .dividerColor
                      .withValues(alpha: .55)),
          boxShadow: accent
              ? [BoxShadow(color: wine.withValues(alpha: .04), blurRadius: 24)]
              : null),
      child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Material(
              color: Colors.transparent,
              child: Padding(padding: padding, child: child))));
}

class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.color});
  final String text;
  final Color? color;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
          color: color?.withValues(alpha: .09),
          border: Border.all(
              color: color?.withValues(alpha: .35) ??
                  Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(999)),
      child: Text(text,
          style: TextStyle(
              fontSize: 10,
              color: color ?? Theme.of(context).colorScheme.onSurfaceVariant)));
}

class StatusDot extends StatelessWidget {
  const StatusDot(this.text, {super.key, this.color = good});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 7),
        Flexible(
            child: Text(text,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: color)))
      ]);
}

class PageHeading extends StatelessWidget {
  const PageHeading(this.title, this.subtitle,
      {super.key, this.eyebrow, this.actions = const []});
  final String title, subtitle;
  final String? eyebrow;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: LayoutBuilder(builder: (context, c) {
        final copy =
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (eyebrow != null) ...[
            Text(eyebrow!,
                style: mono.copyWith(
                    fontSize: 9,
                    letterSpacing: 1.3,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 6)
          ],
          Text(title,
              style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -.6)),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall)
          ]
        ]);
        final buttons = Wrap(spacing: 8, runSpacing: 8, children: actions);
        return c.maxWidth < 650
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                copy,
                if (actions.isNotEmpty) ...[const SizedBox(height: 12), buttons]
              ])
            : Row(children: [Expanded(child: copy), buttons]);
      }));
}

class EmptyView extends StatelessWidget {
  const EmptyView(this.title, this.description,
      {super.key, this.icon = Icons.inbox_outlined, this.action});
  final String title, description;
  final IconData icon;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
      child: SingleChildScrollView(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon,
                    size: 34,
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: .6)),
                const SizedBox(height: 14),
                Text(title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w500)),
                const SizedBox(height: 7),
                Text(description,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall),
                if (action != null) ...[const SizedBox(height: 14), action!]
              ]))));
}

class Ribbon extends StatelessWidget {
  const Ribbon({super.key, this.size = 20});
  final double size;
  @override
  Widget build(BuildContext context) => CustomPaint(
      size: Size(size, size * .65),
      painter: _RibbonPainter(Theme.of(context).colorScheme.primary));
}

class _RibbonPainter extends CustomPainter {
  _RibbonPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 20, size.height / 12);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = .9;
    canvas.drawPath(
        Path()
          ..moveTo(9, 5)
          ..cubicTo(6, 1, 2, 1, 1, 2)
          ..lineTo(1, 9)
          ..cubicTo(3, 10, 6, 8, 9, 6)
          ..moveTo(11, 5)
          ..cubicTo(14, 1, 18, 1, 19, 2)
          ..lineTo(19, 9)
          ..cubicTo(17, 10, 14, 8, 11, 6)
          ..moveTo(8, 5)
          ..lineTo(5, 11)
          ..moveTo(12, 5)
          ..lineTo(15, 11),
        p);
    canvas.drawRect(const Rect.fromLTWH(8.5, 4.5, 3, 3), p);
  }

  @override
  bool shouldRepaint(_RibbonPainter old) => old.color != color;
}

/// Repaints only its own layer. Full motion loops; light/reduced are static.
class FlowLines extends StatefulWidget {
  const FlowLines({super.key, required this.active});
  final bool active;
  @override
  State<FlowLines> createState() => _FlowLinesState();
}

class _FlowLinesState extends State<FlowLines>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock =
      AnimationController(vsync: this, duration: const Duration(seconds: 7));
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant FlowLines old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.active && UiScope.of(context).flow && UiScope.loops(context)) {
      if (!_clock.isAnimating) _clock.repeat();
    } else {
      _clock.stop();
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
      child: RepaintBoundary(
          child: CustomPaint(
              painter: _FlowPainter(
                  _clock,
                  Theme.of(context).colorScheme.primary,
                  widget.active && UiScope.of(context).flow))));
}

class _FlowPainter extends CustomPainter {
  _FlowPainter(this.clock, this.color, this.active) : super(repaint: clock);
  final Animation<double> clock;
  final Color color;
  final bool active;
  @override
  void paint(Canvas canvas, Size s) {
    if (!active) return;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .7;
    for (var i = 0; i < 4; i++) {
      final y = s.height * (.25 + i * .16);
      final path = Path()
        ..moveTo(0, y)
        ..cubicTo(
            s.width * .32, y - 35, s.width * .58, y + 30, s.width, y - 10);
      canvas.drawPath(path, p..color = color.withValues(alpha: .07));
      for (final metric in path.computeMetrics()) {
        final start = ((clock.value + i * .22) % 1) * metric.length;
        canvas.drawPath(
            metric.extractPath(start, math.min(start + 60, metric.length)),
            p..color = color.withValues(alpha: .32));
      }
    }
  }

  @override
  bool shouldRepaint(_FlowPainter old) =>
      old.color != color || old.active != active;
}

String bytesLabel(num bytes) {
  if (bytes >= 1073741824)
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(2)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${bytes.round()} B';
}
