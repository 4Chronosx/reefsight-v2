import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/screens/app_shell.dart';
import 'package:reefsight_mobile/screens/transect_setup_screen.dart';

// Sub-plan 6 (ui-ux-overhaul), step 8: "The shell renders all three tabs,
// and the centre action pushes Transect Setup." AppShell's own tabs use the
// real `openAppDatabase` (no injection seam at this level -- Home/Surveys/
// Settings each take their own `openDatabase` when constructed directly).
// Under `flutter test` that DB open never resolves (no `path_provider`
// platform channel and no mock registered), so Home/Surveys stay on their
// `CircularProgressIndicator` loading state -- an indeterminate spinner, so
// `pumpAndSettle` would hang forever. These tests use bounded `pump()` calls
// instead and don't assert on DB-derived content; that's covered directly
// against injected in-memory DBs in `surveys_screen_test.dart` and
// `home_screen_test.dart`.

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('AppShell renders all three tabs', (tester) async {
    await tester.pumpWidget(_wrap(const AppShell()));
    await tester.pump();

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Surveys'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('the centre action pushes Transect Setup', (tester) async {
    await tester.pumpWidget(_wrap(const AppShell()));
    await tester.pump();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(TransectSetupScreen), findsOneWidget);
  });

  testWidgets('tapping a tab switches the visible IndexedStack child',
      (tester) async {
    await tester.pumpWidget(_wrap(const AppShell()));
    await tester.pump();

    final stackBefore = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(stackBefore.index, 0);

    await tester.tap(find.text('Settings'));
    await tester.pump();

    final stackAfter = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(stackAfter.index, 2);
  });
}
