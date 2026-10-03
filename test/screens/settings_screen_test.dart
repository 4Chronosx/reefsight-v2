import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/screens/settings_screen.dart';
import 'package:reefsight_mobile/services/app_settings.dart';
import 'package:reefsight_mobile/services/classification_policy.dart';
import 'package:reefsight_mobile/services/transect_database.dart';

// Settings -> Diagnostics' classification threshold overrides: each
// dropdown writes AppSettings.classificationThresholds (read by Live at the
// next transect), and Reset puts the sub-plan 10 defaults back.

Future<void> _open(WidgetTester tester) async {
  // Tall enough that the whole Diagnostics card fits without scrolling.
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: SettingsScreen(openDatabase: TransectDatabase.openInMemoryForTest),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, String key, String item) async {
  final dropdown = find.byKey(ValueKey(key));
  await tester.ensureVisible(dropdown);
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

void main() {
  final settings = AppSettings.instance.classificationThresholds;
  setUp(() => settings.value = ClassificationThresholds.defaults);
  tearDown(() => settings.value = ClassificationThresholds.defaults);

  testWidgets('each dropdown overrides its threshold', (tester) async {
    await _open(tester);

    await _pick(tester, 'threshold-segFloor', '0.5');
    await _pick(tester, 'threshold-minCoverage', '0.4');
    await _pick(tester, 'threshold-confFloor', '0.6');
    await _pick(tester, 'threshold-minConfidentSamples', '1');

    expect(
      settings.value,
      const ClassificationThresholds(
        segFloor: 0.5,
        minCoverage: 0.4,
        confFloor: 0.6,
        minConfidentSamples: 1,
      ),
    );
  });

  testWidgets('defaults are marked, and Reset is enabled only once changed',
      (tester) async {
    await _open(tester);
    final reset = find.byKey(const ValueKey('threshold-reset'));
    await tester.ensureVisible(reset);

    expect(find.text('0.7 (default)'), findsOneWidget);
    expect(tester.widget<TextButton>(reset).onPressed, isNull);

    await _pick(tester, 'threshold-confFloor', '0.6');
    await tester.ensureVisible(reset);
    expect(tester.widget<TextButton>(reset).onPressed, isNotNull);

    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(settings.value, ClassificationThresholds.defaults);
  });
}
