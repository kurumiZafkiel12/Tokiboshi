import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/ui/motion.dart';
import 'package:tokiboshi/ui/preferences.dart';
import 'package:tokiboshi/ui/traffic_chart.dart';
import 'package:tokiboshi/ui/import_dialog.dart';

void main() {
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
      for (final title in ['自定义', '二维码', '文件', '链接', '自定义', '链接']) {
        await t.tap(find.widgetWithText(ChoiceChip, title));
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
