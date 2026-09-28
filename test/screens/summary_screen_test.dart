import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/screens/app_shell.dart';
import 'package:reefsight_mobile/screens/summary_screen.dart';
import 'package:reefsight_mobile/screens/transect_setup_screen.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Sub-plan 6 (ui-ux-overhaul), step 8: "Summary's 'Done' returns to the
// shell, not to Setup." Builds the same route shape the real app produces
// (`main.dart`'s `SplashScreen` names the shell route `AppShell.routeName`,
// exactly like this test's `pushReplacement` below) so
// `ModalRoute.withName(AppShell.routeName)` in `SummaryScreen._done()`
// resolves against a route that's actually named that.
//
// `AppShell`'s own Home/Surveys/Settings tabs use the real `openAppDatabase`
// (no `path_provider` platform channel under `flutter test`), so once
// control returns to it, assertions use bounded `pump()` calls rather than
// `pumpAndSettle()`, which would hang on Home/Surveys' indefinite loading
// spinner (see `app_shell_test.dart`'s doc comment).

void main() {
  testWidgets("Summary's Done returns to the shell, not Setup", (tester) async {
    final db = await TransectDatabase.openInMemoryForTest();
    addTearDown(db.close);
    final sessionId = await db.insertSession(
      TransectSession(startedAt: DateTime.utc(2026, 1, 1), tapeLengthMeters: 50),
    );

    // A lightweight stand-in for the shell route, not the real `AppShell`:
    // the real one's Home/Surveys tabs call the real `openAppDatabase` (no
    // `path_provider` platform channel under `flutter test`), which never
    // resolves and leaves their loading spinner's `AnimationController`
    // ticking indefinitely -- that live ticker, combined with the frame
    // jump needed to let `SummaryScreen`'s "Done" pop-transition finish,
    // reproducibly trips `AnimationController`'s internal "elapsedInSeconds
    // >= 0.0" assertion. What this test actually verifies is the
    // route-name-based pop mechanism (`ModalRoute.withName(AppShell.
    // routeName)`, sub-plan 6 step 4) -- that's exercised identically
    // against a route merely *named* `AppShell.routeName`, without needing
    // the real widget behind it.
    const shellPlaceholder = Key('shell-placeholder');

    await tester.pumpWidget(
      MaterialApp(navigatorObservers: [routeObserver], home: const SizedBox()),
    );
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));

    navigator.pushReplacement(
      MaterialPageRoute(
        settings: const RouteSettings(name: AppShell.routeName),
        builder: (_) => const Scaffold(key: shellPlaceholder),
      ),
    );
    await tester.pump();

    // Mirrors the real Setup -> Live -> End Transect chain (minus the
    // camera pipeline, which can't run headlessly): Setup pushed first,
    // then Summary pushed on top -- exactly the shape `pushReplacement` used
    // to leave broken (`live_transect_screen.dart`'s pre-sub-plan-6 bug).
    navigator.push(
      MaterialPageRoute(builder: (_) => const TransectSetupScreen()),
    );
    await tester.pump();
    // `SummaryScreen`'s own report load (real `sqflite_common_ffi` I/O)
    // briefly shows an indeterminate `CircularProgressIndicator`.
    // `pumpAndSettle()` alone has reproducibly hung here; `runAsync()` lets
    // that real I/O actually resolve on the real event loop first.
    await tester.runAsync(() async {
      navigator.push(
        MaterialPageRoute(
          builder: (_) =>
              SummaryScreen(sessionId: sessionId, openDatabase: () async => db),
        ),
      );
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(find.byType(SummaryScreen), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.byKey(shellPlaceholder), findsOneWidget);
    expect(find.byType(TransectSetupScreen), findsNothing);
    expect(find.byType(SummaryScreen), findsNothing);
  });

  testWidgets('loads and renders the report header (site, date, tape length)',
      (tester) async {
    final db = await TransectDatabase.openInMemoryForTest();
    addTearDown(db.close);
    final sessionId = await db.insertSession(
      TransectSession(
        startedAt: DateTime.utc(2026, 1, 1),
        tapeLengthMeters: 75,
        siteName: 'Marigondon Reef',
      ),
    );

    // `SummaryScreen`'s own report load (real `sqflite_common_ffi` I/O)
    // briefly shows an indeterminate `CircularProgressIndicator`.
    // `pumpAndSettle()` alone has reproducibly hung here; `runAsync()` lets
    // that real I/O actually resolve on the real event loop first.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: SummaryScreen(sessionId: sessionId, openDatabase: () async => db),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(find.text('Marigondon Reef'), findsOneWidget);
    expect(find.textContaining('75m transect'), findsOneWidget);
  });
}
