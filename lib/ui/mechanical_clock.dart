import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'preferences.dart';

/// 机械钟主题模块（委托：2026-11-22《Tokiboshi Windows 机械钟样稿与交接》）。
///
/// - 盘面（同心环 / 60 刻线 / 罗马数字 / 滚花 / 夹板 / 螺钉 / 文字）为静态层，
///   尺寸与档位不变时不重画。
/// - 指针与五枚慢转齿轮：完整档每帧滑动，标准 / 精简档整秒跳；精简档齿轮静止。
/// - 时间取本机 [DateTime.now]；最小化 / 切页时 Ticker 停止（静默不绘制），
///   恢复时对齐墙钟。折叠态只保留小时分度、指针与文字时间。
class MechanicalClock extends StatefulWidget {
  const MechanicalClock(
      {super.key, this.size = 232, this.initiallyOpen = true});

  /// 展开时的钟面直径（逻辑像素）。
  final double size;
  final bool initiallyOpen;

  @override
  State<MechanicalClock> createState() => _MechanicalClockState();
}

class _MechanicalClockState extends State<MechanicalClock>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late bool _open = widget.initiallyOpen;
  Ticker? _ticker;
  Timer? _secondTimer;
  bool _visible = true;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 首次启动放到 didChangeDependencies：_tier() 读取 UiScope / MediaQuery
    // 等 inherited widget，不能在 initState 里 dependOnInheritedElement。
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 最小化 / 失焦时停绘；恢复时对齐本机时间。
    _visible = state == AppLifecycleState.resumed;
    if (_visible) {
      _start();
    } else {
      _stop();
    }
  }

  String _tier(BuildContext context) {
    final reduce = MediaQuery.maybeReduceMotionOf(context) ?? false;
    if (reduce) return 'reduced';
    return UiScope.of(context).motion;
  }

  void _start() {
    _stop();
    if (!_open || !_visible) return;
    if (_tier(context) == 'full') {
      _ticker = createTicker((_) {
        if (mounted) setState(() => _tick++);
      })
        ..start();
    } else {
      _secondTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _tick++);
      });
    }
  }

  void _stop() {
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;
    _secondTimer?.cancel();
    _secondTimer = null;
  }

  @override
  void didUpdateWidget(covariant MechanicalClock old) {
    super.didUpdateWidget(old);
    _start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stop();
    super.dispose();
  }

  String _textTime() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  String _textDate() {
    final now = DateTime.now();
    const wd = ['一', '二', '三', '四', '五', '六', '日'];
    return '${now.month}月${now.day}日 星期${wd[now.weekday - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final tier = _tier(context);
    final now = DateTime.now();
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2A1420), Color(0xFF1B1521), Color(0xFF3A1F2E)],
        ),
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: const Color(0xFFFFC1D5).withValues(alpha: .18)),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(children: [
        Row(children: [
          const Text('机械钟',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFF8EFF5))),
          const Spacer(),
          IconButton(
              tooltip: _open ? '折叠模块' : '展开机芯',
              onPressed: () {
                setState(() => _open = !_open);
                _start();
              },
              icon: Icon(_open ? Icons.expand_less : Icons.expand_more,
                  size: 18, color: const Color(0xFFFFC1D5))),
        ]),
        const SizedBox(height: 4),
        if (_open) ...[
          Center(
            child: SizedBox(
              width: widget.size,
              height: widget.size,
              child: CustomPaint(
                  painter: _ClockPainter(
                      tier: tier, now: now, tick: _tick, compact: false)),
            ),
          ),
          const SizedBox(height: 6),
          Text(_textTime(),
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFF8EFF5),
                  fontFeatures: [FontFeature.tabularFigures()])),
          Text(_textDate(),
              style:
                  const TextStyle(fontSize: 10.5, color: Color(0xFFBDB0BD))),
        ] else ...[
          Row(children: [
            SizedBox(
                width: 56,
                height: 56,
                child: CustomPaint(
                    painter: _ClockPainter(
                        tier: tier, now: now, tick: _tick, compact: true))),
            const SizedBox(width: 10),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_textTime(),
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFF8EFF5),
                      fontFeatures: [FontFeature.tabularFigures()])),
              Text(_textDate(),
                  style:
                      const TextStyle(fontSize: 10, color: Color(0xFFBDB0BD))),
            ]),
          ]),
        ],
        const SizedBox(height: 2),
        Text(
            tier == 'full'
                ? '钟面动效：滑动秒针 · 齿轮慢转'
                : tier == 'reduced'
                    ? '钟面动效：整秒跳 · 齿轮静止'
                    : '钟面动效：整秒跳',
            style: const TextStyle(fontSize: 10, color: Color(0xFFBDB0BD))),
      ]),
    );
  }
}

class _ClockPainter extends CustomPainter {
  _ClockPainter({required this.tier, required this.now, required this.tick, required this.compact});
  final String tier;
  final DateTime now;
  final int tick;
  final bool compact;

  static const rose = Color(0xFFFFC1D5);
  static const ink = Color(0xFFF8EFF5);
  static const face = Color(0xFF1B1521);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final R = math.min(size.width, size.height) / 2 - 2;
    final t = now.millisecond / 1000.0;
    final sec = now.second + (tier == 'full' ? t : 0.0);
    final minute = now.minute + sec / 60;
    final hour = now.hour % 12 + minute / 60;
    final secs = now.minute * 60 + now.second + t;

    // ---- 金属边环 ----
    final ring = Paint()
      ..shader = SweepGradient(
              startAngle: -math.pi / 2,
              endAngle: 3 * math.pi / 2,
              colors: const [
                Color(0xFFB4678A), rose, Color(0xFF8E4E70), rose, Color(0xFFB4678A)
              ])
          .createShader(Rect.fromCircle(center: c, radius: R));
    canvas.drawCircle(c, R, ring);
    canvas.drawCircle(c, R - 3, Paint()..color = const Color(0xFF2A1420));
    if (!compact) {
      // 外圈滚花：60 条径向短刻
      final knurl = Paint()
        ..color = rose.withValues(alpha: .5)
        ..strokeWidth = math.max(1, R * .012)
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < 60; i++) {
        final a = i * math.pi / 30;
        final r1 = R - 3.5, r2 = R - 3.5 - R * .045;
        canvas.drawLine(c + Offset(math.sin(a) * r1, -math.cos(a) * r1),
            c + Offset(math.sin(a) * r2, -math.cos(a) * r2), knurl);
      }
    }

    // ---- 盘面 ----
    final faceR = R - R * .10;
    canvas.drawCircle(
        c,
        faceR,
        Paint()
          ..shader = RadialGradient(colors: const [
            Color(0xFF241C2C), face, Color(0xFF14101A),
          ], stops: const [0, .55, 1]).createShader(Rect.fromCircle(center: c, radius: faceR)));
    final ring2 = Paint()
      ..style = PaintingStyle.stroke
      ..color = rose.withValues(alpha: .16)
      ..strokeWidth = 1;
    for (final rr in [.92, .80, .66]) {
      canvas.drawCircle(c, faceR * rr, ring2);
    }

    // ---- 60 刻线 ----
    final major = Paint()
      ..color = ink.withValues(alpha: .85)
      ..strokeWidth = compact ? 1.4 : 2
      ..strokeCap = StrokeCap.round;
    final minor = Paint()
      ..color = ink.withValues(alpha: .38)
      ..strokeWidth = 1;
    for (var i = 0; i < 60; i++) {
      final a = i * math.pi / 30;
      final isMajor = i % 5 == 0;
      final len = isMajor ? faceR * .10 : faceR * .05;
      final r1 = faceR * .93;
      canvas.drawLine(
          c + Offset(math.sin(a) * r1, -math.cos(a) * r1),
          c + Offset(math.sin(a) * (r1 - len), -math.cos(a) * (r1 - len)),
          isMajor ? major : minor);
    }

    // ---- 罗马数字 ----
    if (!compact) {
      const numerals = [
        'XII', 'I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X', 'XI'
      ];
      for (var i = 0; i < 12; i++) {
        final a = i * math.pi / 6;
        final r = faceR * .76;
        final tp = c + Offset(math.sin(a) * r, -math.cos(a) * r);
        final isMain = i % 3 == 0;
        final tp2 = TextPainter(
            text: TextSpan(
                text: numerals[i],
                style: TextStyle(
                    fontSize: (isMain ? faceR * .12 : faceR * .085)
                        .clamp(8.0, 22.0),
                    color: ink.withValues(alpha: isMain ? .92 : .55),
                    fontWeight: isMain ? FontWeight.w700 : FontWeight.w500)),
            textDirection: TextDirection.ltr);
        tp2.layout();
        tp2.paint(canvas, tp - Offset(tp2.width / 2, tp2.height / 2));
      }
      final brand = TextPainter(
          text: const TextSpan(
              text: 'TOKIBOSHI',
              style: TextStyle(
                  fontSize: 9,
                  color: rose,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w600)),
          textDirection: TextDirection.ltr);
      brand.layout();
      brand.paint(canvas, c - Offset(brand.width / 2, faceR * .42));
      final sub = TextPainter(
          text: TextSpan(
              text: '時の星',
              style: TextStyle(
                  fontSize: 8, color: rose.withValues(alpha: .6))),
          textDirection: TextDirection.ltr);
      sub.layout();
      sub.paint(canvas, c + Offset(-sub.width / 2, faceR * .38));
    }

    if (!compact) {
      // ---- 弧形夹板 + 螺钉 ----
      canvas.drawArc(
          Rect.fromCircle(center: c, radius: faceR),
          math.pi * 1.05,
          math.pi * .9,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = faceR * .12
            ..color = rose.withValues(alpha: .07));
      canvas.drawArc(
          Rect.fromCircle(center: c, radius: faceR),
          math.pi * 1.05,
          math.pi * .9,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = rose.withValues(alpha: .22));
      for (final (dx, dy) in [(-.42, -.55), (.34, -.62)]) {
        final sp = c + Offset(faceR * dx, faceR * dy);
        canvas.drawCircle(sp, faceR * .045,
            Paint()..color = rose.withValues(alpha: .5));
        canvas.drawLine(sp - Offset(faceR * .03, 0), sp + Offset(faceR * .03, 0),
            Paint()
              ..color = const Color(0xFF14101A)
              ..strokeWidth = 1.4);
      }
    }

    // ---- 可见机芯：五枚慢转齿轮 ----
    final gears = compact
        ? const <(double, double, double, double)>[]
        : const [
            (0.28, -0.18, 0.16, 0.9),
            (-0.34, 0.22, 0.13, -0.7),
            (0.36, 0.30, 0.11, 0.55),
            (-0.10, 0.42, 0.085, -1.1),
            (0.05, 0.05, 0.07, 0.4),
          ];
    final gearTurn = tier == 'reduced' ? 0.0 : secs;
    for (final (dx, dy, rr, speed) in gears) {
      final gc = c + Offset(faceR * dx, faceR * dy);
      final gr = faceR * rr;
      final angle = gearTurn * speed;
      final path = Path();
      const teeth = 10;
      for (var i = 0; i < teeth; i++) {
        final a0 = angle + i * 2 * math.pi / teeth;
        final a1 = a0 + math.pi / teeth;
        final ro = gr, ri = gr * .78;
        final p0 = gc + Offset(math.cos(a0) * ro, math.sin(a0) * ro);
        final p1 = gc +
            Offset(math.cos(a0 + math.pi / teeth) * ri,
                math.sin(a0 + math.pi / teeth) * ri);
        final p2 = gc + Offset(math.cos(a1) * ri, math.sin(a1) * ri);
        final p3 = gc + Offset(math.cos(a1 + math.pi / teeth) * ro,
            math.sin(a1 + math.pi / teeth) * ro);
        if (i == 0) path.moveTo(p0.dx, p0.dy);
        path.lineTo(p1.dx, p1.dy);
        path.lineTo(p2.dx, p2.dy);
        path.lineTo(p3.dx, p3.dy);
      }
      path.close();
      canvas.drawPath(path, Paint()..color = rose.withValues(alpha: .34));
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = rose.withValues(alpha: .5)
            ..strokeWidth = 1);
      canvas.drawCircle(gc, gr * .30,
          Paint()..color = const Color(0xFF14101A).withValues(alpha: .8));
      canvas.drawCircle(gc, gr * .12, Paint()..color = rose.withValues(alpha: .6));
      for (var i = 0; i < 3; i++) {
        final a = angle + i * 2 * math.pi / 3;
        canvas.drawLine(gc, gc + Offset(math.cos(a) * gr * .72, math.sin(a) * gr * .72),
            Paint()
              ..color = rose.withValues(alpha: .28)
              ..strokeWidth = 1.2);
      }
    }

    // ---- 指针 ----
    double handAngle(double v) => v * 2 * math.pi / 60;
    void hand(double value, double len, double w, Color color,
        {double tail = 0}) {
      final a = handAngle(value);
      final dir = Offset(math.sin(a), -math.cos(a));
      canvas.drawLine(c - dir * (tail * faceR), c + dir * (len * faceR),
          Paint()
            ..color = color
            ..strokeWidth = w
            ..strokeCap = StrokeCap.round);
    }
    hand(hour, .48, faceR * .045, ink.withValues(alpha: .92), tail: .06);
    hand(minute, .66, faceR * .032, ink.withValues(alpha: .92), tail: .08);
    hand(sec, .72, math.max(1.0, faceR * .016).toDouble(), rose, tail: .12);

    canvas.drawCircle(c, faceR * .05, Paint()..color = rose);
    canvas.drawCircle(c, faceR * .022, Paint()..color = const Color(0xFF14101A));
  }

  @override
  bool shouldRepaint(covariant _ClockPainter old) =>
      old.tick != tick || old.tier != tier || old.compact != compact;
}
