import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/ui/mechanical_clock.dart';
import 'package:tokiboshi/ui/motion.dart';
import 'package:tokiboshi/ui/preferences.dart';
import 'package:tokiboshi/ui/traffic_chart.dart';
import 'package:tokiboshi/ui/import_dialog.dart';

void main() {
  testWidgets('full clock motion pauses under reduced motion and window hide',
      (t) async {
    final dispatcher = t.platformDispatcher;
    dispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures();
    addTearDown(() => dispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true));
    final preferences = ValueNotifier(const UiPreferences(motion: 'full'));
    addTearDown(preferences.dispose);
    await t.pumpWidget(UiScope(
        controller: preferences,
        onChanged: (value) => preferences.value = value,
        child: const MaterialApp(home: Center(child: MechanicalClock()))));
    await t.pump(const Duration(milliseconds: 16));
    expect(t.hasRunningAnimations, true);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await t.pump();
    expect(t.hasRunningAnimations, false);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump(const Duration(milliseconds: 16));
    expect(t.hasRunningAnimations, true);
    dispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    await t.pumpAndSettle();
    expect(t.hasRunningAnimations, false);
    expect(find.text('钟面动效：整秒跳 · 齿轮静止'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('hover remains visible above an opaque card and stops when idle',
      (t) async {
    await t.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: Center(
                child: RepaintBoundary(
                    key: ValueKey('opaque-card'),
                    child: MotionHover(
                        child: SizedBox(
                            width: 200,
                            height: 100,
                            child: ColoredBox(
                                color: Colors.black,
                                child: Center(child: Text('卡片'))))))))));
    await t.pumpAndSettle();
    Future<Uint8List> pixels() async => (await t.runAsync(() async {
          final frame = await t
              .renderObject<RenderRepaintBoundary>(
                  find.byKey(const ValueKey('opaque-card')))
              .toImage();
          final bytes =
              await frame.toByteData(format: ui.ImageByteFormat.rawRgba);
          frame.dispose();
          return bytes!.buffer.asUint8List();
        }))!;
    final before = await pixels();
    final mouse = await t.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(t.getCenter(find.byKey(const ValueKey('opaque-card'))));
    await t.pumpAndSettle();
    expect(listEquals(before, await pixels()), false);
    expect(t.hasRunningAnimations, false);
    await mouse.moveTo(Offset.zero);
    await t.pumpAndSettle();
    expect(listEquals(before, await pixels()), true);
    await mouse.removePointer();
    await t.pumpWidget(const SizedBox());
  });
  for (final mode in ['full', 'standard', 'reduced']) {
    testWidgets('motion $mode survives rapid updates and becomes idle',
        (t) async {
      final preferences = ValueNotifier(UiPreferences(motion: mode));
      addTearDown(preferences.dispose);
      final series = ValueNotifier<List<double>>([0, 1024, 2048]);
      addTearDown(series.dispose);
      await t.pumpWidget(UiScope(
          controller: preferences,
          onChanged: (v) => preferences.value = v,
          child: MaterialApp(
              home: Scaffold(
                  body: ValueListenableBuilder(
                      valueListenable: series,
                      builder: (context, value, _) => Column(children: [
                            MotionEntrance(
                                order: 5,
                                child: MotionHover(
                                    lift: true,
                                    child: AnimatedMetric(
                                        value: value.last,
                                        format: (n) => n.round().toString()))),
                            SizedBox(
                                height: 120,
                                child: SmoothTrafficChart(
                                    down: value, up: const [0, 512, 1024])),
                          ]))))));
      await t.pump(const Duration(milliseconds: 40));
      series.value = [1024, 4096, 8192];
      await t.pump(const Duration(milliseconds: 80));
      series.value = [1024, 4096, 16384];
      await t.pumpAndSettle();
      expect(find.text('16384'), findsOneWidget);
      expect(t.takeException(), isNull);
      expect(t.hasRunningAnimations, false);
      preferences.value = preferences.value.copyWith(motion: 'reduced');
      series.value = [0, 1, 2];
      await t.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);
      expect(t.hasRunningAnimations, false);
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
    });
    testWidgets(
        'import pane $mode fits small window through repeated tab switches',
        (t) async {
      t.view.physicalSize = const Size(800, 600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final preferences = ValueNotifier(UiPreferences(motion: mode));
      addTearDown(preferences.dispose);
      await t.pumpWidget(UiScope(
          controller: preferences,
          onChanged: (_) {},
          child: const MaterialApp(home: Scaffold(body: ImportDialog()))));
      await t.pumpAndSettle();
      for (final tooltip in [
        '自定义节点 JSON',
        '二维码',
        '从文件导入',
        '自定义节点 JSON',
        '从文件导入'
      ]) {
        await t.tap(find.byTooltip(tooltip));
        await t.pump(const Duration(milliseconds: 30));
        expect(t.takeException(), isNull);
      }
      await t.pumpAndSettle();
      expect(t.hasRunningAnimations, false);
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
    });
  }
}
