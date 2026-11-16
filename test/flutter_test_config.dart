import 'dart:async';
import 'package:flutter_test/flutter_test.dart';

/// Respect the same OS reduce-motion feature in production and widget tests.
/// Continuous flow tests opt back in explicitly and pump a bounded duration.
Future<void> testExecutable(FutureOr<void> Function() main) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  binding.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  await main();
}
