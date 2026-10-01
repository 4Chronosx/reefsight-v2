import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/screens/app_shell.dart';
import 'package:reefsight_mobile/screens/summary_screen.dart';
import 'package:reefsight_mobile/screens/transect_setup_screen.dart';
import 'package:reefsight_mobile/services/device_checks.dart';
import 'package:reefsight_mobile/services/tracked_colony_record.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

import '../support/fake_device.dart';

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
    final device = FakeDevice();

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
      MaterialPageRoute(
        builder: (_) => TransectSetupScreen(
          storageInfo: device,
          batteryInfo: device,
          thermalInfo: device,
        ),
      ),
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

  // Sub-plan 10, step 3: prevalence is computed over confidently classified
  // colonies only, so the denominator is shown, not hidden.
  testWidgets('shows "N colonies · M classified · K uncertain"',
      (tester) async {
    final db = await TransectDatabase.openInMemoryForTest();
    addTearDown(db.close);
    final sessionId = await db.insertSession(
      TransectSession(startedAt: DateTime.utc(2026, 1, 1), tapeLengthMeters: 50),
    );
    final labels = ['CORAL', 'CORAL_BL', null, null];
    for (var i = 0; i < labels.length; i++) {
      await db.upsertColony(
        TrackedColonyRecord(
          sessionId: sessionId,
          trackId: i + 1,
          healthLabel: labels[i],
          healthHistory: const [],
          firstSeenAt: DateTime.utc(2026, 1, 1),
          lastSeenAt: DateTime.utc(2026, 1, 1),
        ),
      );
    }

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: SummaryScreen(sessionId: sessionId, openDatabase: () async => db),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(
      find.text('4 colonies · 2 classified · 2 uncertain'),
      findsOneWidget,
    );
  });

  // Sub-plan 11 step 4: an incomplete session is labelled with what was
  // kept, not hidden or edited.
  group('incomplete session banner', () {
    Future<int> seed(
      TransectDatabase db, {
      DateTime? endedAt,
      DateTime? lastCheckpointAt,
      int interruptions = 0,
      int colonies = 2,
    }) async {
      final sessionId = await db.insertSession(
        TransectSession(
          startedAt: DateTime.utc(2026, 10, 1, 9),
          endedAt: endedAt,
          tapeLengthMeters: 50,
        ),
      );
      for (var i = 0; i < colonies; i++) {
        await db.upsertColony(
          TrackedColonyRecord(
            sessionId: sessionId,
            trackId: i + 1,
            healthHistory: const [],
            firstSeenAt: DateTime.utc(2026, 10, 1, 9),
            lastSeenAt: DateTime.utc(2026, 10, 1, 9),
          ),
        );
      }
      if (lastCheckpointAt != null) {
        await db.recordCheckpoint(sessionId, lastCheckpointAt);
      }
      for (var i = 0; i < interruptions; i++) {
        await db.recordInterruption(sessionId, DateTime.utc(2026, 10, 1, 9, i));
      }
      return sessionId;
    }

    Future<void> pumpSummary(
      WidgetTester tester,
      TransectDatabase db,
      int sessionId,
    ) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home:
                SummaryScreen(sessionId: sessionId, openDatabase: () async => db),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
    }

    testWidgets('says when the app stopped and how many colonies were saved',
        (tester) async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final checkpointAt = DateTime.utc(2026, 10, 1, 9, 42);
      final sessionId = await seed(db, lastCheckpointAt: checkpointAt);

      await pumpSummary(tester, db, sessionId);

      final local = checkpointAt.toLocal();
      final hhmm = '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
      expect(
        find.text('Incomplete — the app stopped at $hhmm. '
            '2 colonies were saved up to then.'),
        findsOneWidget,
      );
    });

    testWidgets('without a checkpoint time, still says what was saved',
        (tester) async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await seed(db, colonies: 1);

      await pumpSummary(tester, db, sessionId);

      expect(find.text('Incomplete — 1 colony was saved.'), findsOneWidget);
    });

    testWidgets('reports how often the app was interrupted', (tester) async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await seed(
        db,
        lastCheckpointAt: DateTime.utc(2026, 10, 1, 9, 42),
        interruptions: 2,
      );

      await pumpSummary(tester, db, sessionId);

      expect(
        find.text('The app was interrupted twice during this transect.'),
        findsOneWidget,
      );
    });

    testWidgets('a completed session shows no banner', (tester) async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await seed(
        db,
        endedAt: DateTime.utc(2026, 10, 1, 9, 50),
        lastCheckpointAt: DateTime.utc(2026, 10, 1, 9, 42),
        interruptions: 1,
      );

      await pumpSummary(tester, db, sessionId);

      expect(find.textContaining('Incomplete'), findsNothing);
      // Interruptions are still worth knowing on a finished survey.
      expect(
        find.text('The app was interrupted once during this transect.'),
        findsOneWidget,
      );
    });

    // Sub-plan 13 step 4: the Technical tab says when the device got hot,
    // so a frame-rate drop in the report can be explained.
    group('thermal note on the Technical tab', () {
      Future<void> openTechnicalTab(WidgetTester tester) async {
        await tester.tap(find.text('Technical Detail'));
        await tester.pumpAndSettle();
      }

      for (final (peak, expected) in [
        (ThermalLevel.serious, 'Device got hot (serious) during this transect.'),
        (ThermalLevel.critical, 'Device got hot (critical) during this transect.'),
      ]) {
        testWidgets('a ${peak.name} peak is reported', (tester) async {
          final db = await TransectDatabase.openInMemoryForTest();
          addTearDown(db.close);
          final sessionId = await seed(db, endedAt: DateTime.utc(2026, 10, 1, 9, 50));
          await db.recordThermal(sessionId, peak, 1);

          await pumpSummary(tester, db, sessionId);
          await openTechnicalTab(tester);

          expect(find.text(expected), findsOneWidget);
        });
      }

      testWidgets('a fair peak, or no reading, says nothing', (tester) async {
        final db = await TransectDatabase.openInMemoryForTest();
        addTearDown(db.close);
        final warm = await seed(db, endedAt: DateTime.utc(2026, 10, 1, 9, 50));
        await db.recordThermal(warm, ThermalLevel.fair, 1);
        final unknown = await seed(db, endedAt: DateTime.utc(2026, 10, 1, 9, 50));

        for (final sessionId in [warm, unknown]) {
          await pumpSummary(tester, db, sessionId);
          await openTechnicalTab(tester);
          expect(find.textContaining('Device got hot'), findsNothing);
        }
      });
    });
  });
}
