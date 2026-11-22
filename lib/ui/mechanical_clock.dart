import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'preferences.dart';
import 'design.dart';

/// 机械钟主题模块（委托：2026-11-22《Tokiboshi Windows 机械钟样稿与交接》）。
///
/// - 盘面（同心环 / 60 刻线 / 罗马数字 / 滚花 / 夹板 / 螺钉 / 文字）为静态层，
///   尺寸与档位不变时不重画。
/// - 指针与五枚慢转齿轮：完整档每帧滑动，标准 / 精简档整秒跳；精简档齿轮静止。
/// - 时间取本机 [DateTime.now]；最小化 / 切页时 Ticker 停止（静默不绘制），
///   恢复时对齐墙钟。折叠态只保留小时分度、指针与文字时间。
class MechanicalClock extends StatefulWidget {
  const MechanicalClock(
      {super.key,
      this.size = 232,
      this.initiallyOpen = true,
      this.dashboard = false});

  /// 展开时的钟面直径（逻辑像素）。
  final double size;
  final bool initiallyOpen;
  final bool dashboard;

  @override
  State<MechanicalClock> createState() => _MechanicalClockState();
}

class _MechanicalClockState extends State<MechanicalClock>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  late bool _open = widget.initiallyOpen;
  Ticker? _ticker;
  Timer? _secondTimer;
  bool _visible = true;
  bool _movementOpen = false;
  final _frames = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _visible = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    // 首次启动放到 didChangeDependencies：_tier() 读取 UiScope / MediaQuery
    // 等 inherited widget，不能在 initState 里 dependOnInheritedElement。
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 最小化 / 失焦时停绘；恢复时对齐本机时间。
    _visible = state == AppLifecycleState.resumed;
    if (_visible) {
      setState(_start);
    } else {
      _stop();
    }
  }

  String _tier(BuildContext context) {
    final reduce = UiScope.duration(context) == Duration.zero ||
        (MediaQuery.maybeReduceMotionOf(context) ?? false);
    if (reduce) return 'reduced';
    return UiScope.of(context).motion;
  }

  void _start() {
    _stop();
    if ((!_open && !widget.dashboard) ||
        !_visible ||
        _movementOpen ||
        !TickerMode.of(context)) {
      return;
    }
    if (_tier(context) == 'full' && !widget.dashboard) {
      _ticker = createTicker((_) => _frames.value++)..start();
    }
    _nextSecond();
  }

  void _nextSecond() {
    _secondTimer =
        Timer(Duration(milliseconds: 1000 - DateTime.now().millisecond), () {
      setState(() {});
      _nextSecond();
    });
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
    if (old.dashboard != widget.dashboard) _start();
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
    _frames.dispose();
    super.dispose();
  }

  String _textTime(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  String _textDate(DateTime now) {
    const wd = ['一', '二', '三', '四', '五', '六', '日'];
    return '${now.month}月${now.day}日 星期${wd[now.weekday - 1]}';
  }

  Widget _dial(double size, String tier, DateTime now,
          {bool compact = false}) =>
      SizedBox(
        width: size,
        height: size,
        child: ExcludeSemantics(
            child: Stack(fit: StackFit.expand, children: [
          RepaintBoundary(
            child: CustomPaint(
                painter: _ClockPainter(
                    tier: tier, now: now, compact: compact, staticLayer: true)),
          ),
          RepaintBoundary(
            child: CustomPaint(
                painter: _ClockPainter(
                    tier: tier,
                    now: now,
                    compact: compact,
                    frames: tier == 'full' ? _frames : null)),
          ),
        ])),
      );

  Future<void> _showMovement() async {
    if (_movementOpen) return;
    _movementOpen = true;
    _stop();
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => Dialog(
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: WorkbenchGlass(
              radius: 20,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      tooltip: '关闭机芯',
                      onPressed: () => Navigator.pop(dialogContext),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                  LayoutBuilder(
                      builder: (context, bounds) => MechanicalClock(
                          size: math.min(300, bounds.maxWidth - 22))),
                ]),
              ),
            ),
          ),
        ),
      );
    } finally {
      _movementOpen = false;
      if (mounted) setState(_start);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tier = _tier(context);
    final now = DateTime.now();
    if (widget.dashboard) {
      return SizedBox(
          height: 168,
          child: Panel(
              child: Column(children: [
            Row(children: [
              const Expanded(
                  child: Text('机械钟',
                      style: TextStyle(fontWeight: FontWeight.w600))),
              OutlinedButton(
                  onPressed: _showMovement, child: const Text('展开机芯')),
            ]),
            const SizedBox(height: 4),
            Expanded(
              child: LayoutBuilder(
                  builder: (context, bounds) => Row(children: [
                        _dial(
                            math.min(
                                widget.size,
                                math.min(
                                    bounds.maxHeight, bounds.maxWidth * .41)),
                            tier == 'full' ? 'standard' : tier,
                            now),
                        const SizedBox(width: 12),
                        Expanded(
                            child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_textTime(now),
                                style: Theme.of(context)
                                    .textTheme
                                    .titleLarge
                                    ?.copyWith(fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ])),
                            Text(_textDate(now),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall),
                          ],
                        )),
                      ])),
            ),
          ])));
    }
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF30171D), Color(0xFF211317), Color(0xFF472029)],
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
              visualDensity: widget.dashboard
                  ? VisualDensity.compact
                  : VisualDensity.standard,
              onPressed: () {
                setState(() => _open = !_open);
                _start();
              },
              icon: Icon(_open ? Icons.expand_less : Icons.expand_more,
                  size: 18, color: const Color(0xFFFFC1D5))),
        ]),
        const SizedBox(height: 4),
        if (_open) ...[
          Center(child: _dial(widget.size, tier, now)),
          const SizedBox(height: 6),
          Text(_textTime(now),
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFF8EFF5),
                  fontFeatures: [FontFeature.tabularFigures()])),
          if (!widget.dashboard)
            Text(_textDate(now),
                style:
                    const TextStyle(fontSize: 10.5, color: Color(0xFFBDB0BD))),
        ] else ...[
          Row(children: [
            _dial(64, tier, now, compact: true),
            const SizedBox(width: 10),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_textTime(now),
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFF8EFF5),
                      fontFeatures: [FontFeature.tabularFigures()])),
              Text(_textDate(now),
                  style:
                      const TextStyle(fontSize: 10, color: Color(0xFFBDB0BD))),
            ]),
          ]),
        ],
        const SizedBox(height: 2),
        if (!widget.dashboard)
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
  _ClockPainter(
      {required this.tier,
      required this.now,
      required this.compact,
      this.frames,
      this.staticLayer = false})
      : super(repaint: frames);
  final String tier;
  final DateTime now;
  final Listenable? frames;
  final bool compact;
  final bool staticLayer;

  static const rose = Color(0xFFFFC1D5);
  static const ink = Color(0xFFF8EFF5);
  static const face = Color(0xFF211317);

  static const _gearLayout = [
    (.28, -.18, .16, 12, 7),
    (-.34, .22, .13, 10, -9),
    (.36, .30, .11, 10, 11),
    (-.10, .42, .085, 8, -13),
    (.05, .05, .07, 8, 11),
  ];
  static final _gearProfiles = {
    for (final teeth in [8, 10, 12]) teeth: _gearProfile(teeth)
  };
  static final _gearMetal = Paint()
    ..shader = const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFFAC7382), Color(0xFF724653), Color(0xFF462731)],
    ).createShader(const Rect.fromLTWH(-1, -1, 2, 2));
  static final _gearEdge = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = .045
    ..color = rose.withValues(alpha: .55);
  static final _gearHub = Paint()..color = const Color(0xFF28151C);
  static final _gearPin = Paint()..color = const Color(0xFFD4A3AF);

  static Path _gearProfile(int teeth) {
    final path = Path()..fillType = PathFillType.evenOdd;
    for (var tooth = 0; tooth < teeth; tooth++) {
      for (final (phase, radius) in const [
        (0.0, .77),
        (.22, .77),
        (.34, .985),
        (.62, .985),
        (.76, .77)
      ]) {
        final angle = (tooth + phase) * 2 * math.pi / teeth;
        final x = radius * math.cos(angle), y = radius * math.sin(angle);
        if (tooth == 0 && phase == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
    }
    path.close();
    for (var opening = 0; opening < 3; opening++) {
      final angle = opening * 2 * math.pi / 3;
      path.addOval(Rect.fromCircle(
        center: Offset(math.cos(angle) * .44, math.sin(angle) * .44),
        radius: .155,
      ));
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final R = math.min(size.width, size.height) / 2 - 2;
    final now = frames == null ? this.now : DateTime.now();
    final t = now.millisecond / 1000.0;
    final sec = now.second + (tier == 'full' ? t : 0.0);
    final minute = now.minute + sec / 60;
    final hour = now.hour % 12 + minute / 60;

    final faceR = R - R * .10;
    if (staticLayer) {
      // ---- 金属边环 ----
      final ring = Paint()
        ..shader = SweepGradient(
            startAngle: -math.pi / 2,
            endAngle: 3 * math.pi / 2,
            colors: const [
              Color(0xFFBE6676),
              rose,
              Color(0xFF823B4A),
              rose,
              Color(0xFFBE6676)
            ]).createShader(Rect.fromCircle(center: c, radius: R));
      canvas.drawCircle(c, R, ring);
      canvas.drawCircle(c, R - 3, Paint()..color = const Color(0xFF30171D));
      if (R >= 80 && !compact) {
        final bevel = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..shader = const SweepGradient(
            colors: [
              Color(0x88FFC1D5),
              Color(0x00462731),
              Color(0xAAC87E95),
              Color(0x00462731),
              Color(0x88FFC1D5),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: R));
        canvas.drawCircle(c, R - 1.6, bevel);
        canvas.drawCircle(c, R - 11, bevel);
      }
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
      canvas.drawCircle(
          c,
          faceR,
          Paint()
            ..shader = RadialGradient(colors: const [
              Color(0xFF2D1A20),
              face,
              Color(0xFF160F13),
            ], stops: const [
              0,
              .55,
              1
            ]).createShader(Rect.fromCircle(center: c, radius: faceR)));
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
          'XII',
          'I',
          'II',
          'III',
          'IV',
          'V',
          'VI',
          'VII',
          'VIII',
          'IX',
          'X',
          'XI'
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
                      fontFamily: 'Segoe UI',
                      fontSize: (isMain ? faceR * .12 : faceR * .085)
                          .clamp(8.0, 22.0),
                      color: ink.withValues(alpha: isMain ? .92 : .55),
                      fontWeight: isMain ? FontWeight.w700 : FontWeight.w500)),
              textDirection: TextDirection.ltr);
          tp2.layout();
          tp2.paint(canvas, tp - Offset(tp2.width / 2, tp2.height / 2));
          tp2.dispose();
        }
        final brand = TextPainter(
            text: const TextSpan(
                text: 'TOKIBOSHI',
                style: TextStyle(
                    fontFamily: 'Segoe UI',
                    fontSize: 8,
                    color: rose,
                    letterSpacing: 1.4,
                    fontWeight: FontWeight.w600)),
            textDirection: TextDirection.ltr);
        brand.layout();
        brand.paint(canvas, c - Offset(brand.width / 2, faceR * .42));
        brand.dispose();
        final sub = TextPainter(
            text: TextSpan(
                text: '時の星',
                style: TextStyle(
                    fontFamily: 'Segoe UI',
                    fontSize: 8,
                    color: rose.withValues(alpha: .6))),
            textDirection: TextDirection.ltr);
        sub.layout();
        sub.paint(canvas, c + Offset(-sub.width / 2, faceR * .38));
        sub.dispose();
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
          canvas.drawCircle(sp, faceR * .055, Paint()..color = face);
          canvas.drawCircle(
              sp,
              faceR * .045,
              Paint()
                ..shader = const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFD6A6B2), Color(0xFF5E3945)],
                ).createShader(
                    Rect.fromCircle(center: sp, radius: faceR * .045)));
          canvas.drawLine(
              sp - Offset(faceR * .03, 0),
              sp + Offset(faceR * .03, 0),
              Paint()
                ..color = const Color(0xFF160F13)
                ..strokeWidth = 1.4);
        }
      }

      if (!compact) {
        for (var i = 0; i < 90; i++) {
          final a = i * math.pi / 45;
          final axis = Offset(math.cos(a), math.sin(a));
          canvas.drawLine(c + axis * (faceR * .51), c + axis * (faceR * .63),
              Paint()..color = rose.withValues(alpha: i.isEven ? .06 : .03));
        }
      }
      return;
    }

    // ---- 可见机芯：五枚慢转齿轮 ----
    if (!compact) {
      final withinMinute = tier == 'reduced' ? 0.0 : sec / 60;
      for (final (dx, dy, radius, teeth, rpm) in _gearLayout) {
        final path = _gearProfiles[teeth]!;
        canvas.save();
        canvas.translate(c.dx + faceR * dx, c.dy + faceR * dy);
        canvas.rotate(2 * math.pi * withinMinute * rpm);
        canvas.scale(faceR * radius);
        canvas.drawPath(path, _gearMetal);
        canvas.drawPath(path, _gearEdge);
        canvas.drawCircle(Offset.zero, .23, _gearHub);
        canvas.drawCircle(Offset.zero, .105, _gearPin);
        canvas.restore();
      }
    }

    // ---- 指针 ----
    double handAngle(double v) => v * 2 * math.pi / 60;
    void hand(double value, double len, double w, Color color,
        {double tail = 0}) {
      final a = handAngle(value);
      final dir = Offset(math.sin(a), -math.cos(a));
      canvas.drawLine(
          c - dir * (tail * faceR),
          c + dir * (len * faceR),
          Paint()
            ..color = color
            ..strokeWidth = w
            ..strokeCap = StrokeCap.round);
    }

    hand(hour, .48, faceR * .045, ink.withValues(alpha: .92), tail: .06);
    hand(minute, .66, faceR * .032, ink.withValues(alpha: .92), tail: .08);
    hand(sec, .72, math.max(1.0, faceR * .016).toDouble(), rose, tail: .12);

    canvas.drawCircle(c, faceR * .05, Paint()..color = rose);
    canvas.drawCircle(
        c, faceR * .022, Paint()..color = const Color(0xFF160F13));
  }

  @override
  bool shouldRepaint(covariant _ClockPainter old) =>
      old.staticLayer != staticLayer ||
      old.compact != compact ||
      (!staticLayer && (old.now != now || old.tier != tier));
}
