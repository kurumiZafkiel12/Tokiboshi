import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/ui/design.dart';
import 'package:tokiboshi/ui/preferences.dart';

void main() {
  testWidgets(
      'flow moves in full, stops in light/reduced and respects system reduction',
      (t) async {
    final prefs = ValueNotifier(const UiPreferences(followSystem: false));
    await t.pumpWidget(UiScope(
        controller: prefs,
        onChanged: (v) => prefs.value = v,
        child: const MaterialApp(
            home: Scaffold(
                body: RepaintBoundary(
                    key: ValueKey('flow'),
                    child: SizedBox(
                        width: 400,
                        height: 180,
                        child: FlowLines(active: true)))))));
    Future<Uint8List> pixels() async => (await t.runAsync(() async {
          final image = await t
              .renderObject<RenderRepaintBoundary>(
                  find.byKey(const ValueKey('flow')))
              .toImage();
          final data =
              await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          image.dispose();
          return data!.buffer.asUint8List();
        }))!;
    await t.pump(const Duration(milliseconds: 200));
    final first = await pixels();
    await t.pump(const Duration(milliseconds: 400));
    final second = await pixels();
    expect(listEquals(first, second), false);
    for (final mode in ['standard', 'reduced']) {
      prefs.value = prefs.value.copyWith(motion: mode);
      await t.pumpAndSettle();
      final frozen = await pixels();
      await t.pump(const Duration(milliseconds: 400));
      expect(listEquals(frozen, await pixels()), true);
      expect(t.binding.hasScheduledFrame, false);
    }
    prefs.value = prefs.value.copyWith(motion: 'full', followSystem: true);
    await t.pumpAndSettle();
    expect(t.binding.hasScheduledFrame, false);
    await t.pumpWidget(const SizedBox());
    prefs.dispose();
  });
}
