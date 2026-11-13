import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/main.dart';

void main() {
  testWidgets('home shows stopped state and start button', (tester) async {
    await tester.pumpWidget(TokiboshiApp(bridge: LocalCoreBridge()));
    expect(find.text('Tokiboshi'), findsWidgets);
    expect(find.text('sing-box 已停止'), findsOneWidget);
    expect(find.text('启动'), findsOneWidget);

    await tester.tap(find.text('启动'));
    await tester.pump();
    expect(find.text('sing-box 运行中'), findsOneWidget);
    expect(find.text('停止'), findsOneWidget);
  });
}
