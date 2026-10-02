import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/screens/app_shell.dart';
import 'package:reefsight_mobile/screens/summary_screen.dart';
import 'package:reefsight_mobile/screens/transect_setup_screen.dart';
import 'package:reefsight_mobile/screens/video_player_screen.dart';
import 'package:reefsight_mobile/services/device_checks.dart';
import 'package:reefsight_mobile/services/geo_fix.dart';
import 'package:reefsight_mobile/services/health_aggregator.dart';
import 'package:reefsight_mobile/services/recount.dart';
import 'package:reefsight_mobile/services/tracked_colony_record.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

import '../support/fake_device.dart';
import '../support/fake_location.dart';

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
          locationProvider: FakeLocationProvider.failure(),
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
  // Sub-plan 17: every prevalence and density figure carries its 95%
  // interval; below `minClassifiedForPrevalence` classified colonies the
  // executive tab says "too few" while the technical tab keeps the number.
  group('prevalence and density intervals (sub-plan 17)', () {
    Future<void> pumpWithLabels(WidgetTester tester, List<String?> labels) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await db.insertSession(
        TransectSession(startedAt: DateTime.utc(2026, 1, 1), tapeLengthMeters: 50),
      );
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
    }

    List<String?> labels({required int bleached, required int healthy}) => [
          ...List.filled(bleached, 'CORAL_BL'),
          ...List.filled(healthy, 'CORAL'),
        ];

    testWidgets('below the threshold: too few on Executive, the number on Technical',
        (tester) async {
      await pumpWithLabels(tester, labels(bleached: 3, healthy: 3));

      expect(
        find.text('Too few classified colonies to estimate bleaching reliably (n = 6).'),
        findsOneWidget,
      );
      expect(find.textContaining('of classified colonies were bleached'), findsNothing);
      expect(find.textContaining('≈ 0.12 colonies/m² ('), findsOneWidget);

      await tester.tap(find.text('Technical Detail'));
      await tester.pumpAndSettle();

      expect(
        find.text('Bleaching prevalence: 50.0% (95% CI 18.8–81.2%, Wilson; n = 6 classified)'),
        findsOneWidget,
      );
      expect(find.textContaining('Density: 0.12 colonies/m² (95% CI '), findsOneWidget);
      expect(find.textContaining('sampling uncertainty only'), findsOneWidget);
    });

    testWidgets('at the threshold: the Executive sentence carries the interval',
        (tester) async {
      await pumpWithLabels(tester, labels(bleached: 5, healthy: 5));

      expect(
        find.text('About 50% of classified colonies were bleached '
            '(likely between 24% and 76%).'),
        findsOneWidget,
      );
      expect(find.textContaining('Too few classified'), findsNothing);
    });
  });

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

  // Sub-plan 12 step 4 + tests: "the exit button records once, and after
  // that the fix is shown read-only with no button." A temp-file database,
  // not in-memory: Summary closes every handle it opens, and recording the
  // exit fix opens one to write and another to reload.
  group('Exit position (sub-plan 12)', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('reefsight_summary_exit_');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    final exitGps = testGpsFix(lat: 10.25455, accuracyM: 6);

    /// File I/O runs inside `runAsync` -- in `testWidgets`' fake-async zone
    /// a file-backed open never completes.
    Future<int> seed(WidgetTester tester, {required DateTime endedAt, GeoFix? exitFix}) async {
      final id = await tester.runAsync(() async {
        final db = await TransectDatabase.open(dir.path);
        try {
          final id = await db.insertSession(
            TransectSession(
              startedAt: endedAt.subtract(const Duration(minutes: 40)),
              endedAt: endedAt,
              tapeLengthMeters: 50,
              siteName: 'Day-as',
              entryFix: testGpsFix(),
            ),
          );
          if (exitFix != null) await db.recordExitFix(id, exitFix);
          return id;
        } finally {
          await db.close();
        }
      });
      return id!;
    }

    Future<void> pumpSummary(
      WidgetTester tester,
      int sessionId,
      FakeLocationProvider location,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: SummaryScreen(
              sessionId: sessionId,
              openDatabase: () => TransectDatabase.open(dir.path),
              locationProvider: location,
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
    }

    testWidgets('records the exit GPS fix once, then shows it read-only', (tester) async {
      final sessionId =
          await seed(tester, endedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 10)));
      final location = FakeLocationProvider.fix(exitGps);

      await pumpSummary(tester, sessionId, location);

      expect(find.text('Entry: ${formatFix(testGpsFix())}'), findsOneWidget);
      expect(find.text('Record exit position'), findsOneWidget);

      await tester.tap(find.text('Record exit position'));
      await tester.pumpAndSettle();
      // Acquired, but nothing is stored until Save.
      expect(find.text(formatFix(exitGps)), findsOneWidget);

      // Save writes, closes, then reloads through two real file-backed
      // opens -- poll real time (bounded) until the reload has rendered.
      final exitLine = find.text('Exit: ${formatFix(exitGps)}');
      await tester.runAsync(() async {
        await tester.tap(find.text('Save exit position'));
        for (var i = 0; i < 50 && exitLine.evaluate().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();

      expect(find.text('Record exit position'), findsNothing);
      expect(find.text('Save exit position'), findsNothing);
      expect(find.text('Exit: ${formatFix(exitGps)}'), findsOneWidget);
      expect(
        find.text('entry–exit ${distanceMeters(testGpsFix(), exitGps).toStringAsFixed(0)} m'
            ' apart · tape 50 m'),
        findsOneWidget,
      );
      expect(location.calls, 1);

      final stored = await tester.runAsync(() async {
        final db = await TransectDatabase.open(dir.path);
        try {
          return (await db.sessionById(sessionId))!.exitFix;
        } finally {
          await db.close();
        }
      });
      expect(stored, exitGps);
    });

    testWidgets('a session with an exit fix shows it with no button', (tester) async {
      final sessionId = await seed(
        tester,
        endedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 10)),
        exitFix: exitGps,
      );

      await pumpSummary(tester, sessionId, FakeLocationProvider.fix());

      expect(find.text('Exit: ${formatFix(exitGps)}'), findsOneWidget);
      expect(find.text('Record exit position'), findsNothing);
      expect(find.text('Enter manually'), findsNothing);
    });

    testWidgets('a dive that ended over 12 h ago offers manual entry only', (tester) async {
      final sessionId = await seed(tester, endedAt: DateTime.utc(2026, 1, 1, 9));
      final location = FakeLocationProvider.fix();

      await pumpSummary(tester, sessionId, location);

      expect(find.text('Record exit position'), findsNothing);
      expect(find.textContaining('ended over 12 h ago'), findsOneWidget);
      expect(find.text('Enter manually'), findsOneWidget);
      expect(location.calls, 0);
    });
  });

  // Sub-plan 14: blinded manual recount. File-backed for the same reason as
  // the exit-fix group: saving opens one handle to write, another to reload.
  group('Manual recount (sub-plan 14)', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('reefsight_summary_recount_');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    Future<T> withDb<T>(WidgetTester tester, Future<T> Function(TransectDatabase) body) async {
      final result = await tester.runAsync(() async {
        final db = await TransectDatabase.open(dir.path);
        try {
          return await body(db);
        } finally {
          await db.close();
        }
      });
      return result as T;
    }

    /// Three colonies: one healthy, one bleached, one Uncertain -- so app
    /// prevalence is 1 of 2 classified (50 %).
    Future<int> seed(
      WidgetTester tester, {
      required bool resultsHidden,
      bool ended = true,
    }) =>
        withDb(tester, (db) async {
          final start = DateTime.now().toUtc().subtract(const Duration(hours: 1));
          final id = await db.insertSession(
            TransectSession(
              startedAt: start,
              endedAt: ended ? start.add(const Duration(minutes: 40)) : null,
              tapeLengthMeters: 50,
              siteName: 'Day-as',
              resultsHidden: resultsHidden,
            ),
          );
          final labels = [HealthAggregator.healthyLabel, HealthAggregator.bleachedLabel, null];
          for (var i = 0; i < labels.length; i++) {
            await db.upsertColony(
              TrackedColonyRecord(
                sessionId: id,
                trackId: i + 1,
                healthLabel: labels[i],
                healthHistory: const [],
                firstSeenAt: start,
                lastSeenAt: start,
              ),
            );
          }
          return id;
        });

    Future<void> pumpSummary(WidgetTester tester, int sessionId) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: SummaryScreen(
              sessionId: sessionId,
              openDatabase: () => TransectDatabase.open(dir.path),
              locationProvider: FakeLocationProvider.fix(),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
    }

    /// Taps [button] and polls real time (bounded) until [until] renders --
    /// a save writes, closes, then reloads through real file-backed opens.
    Future<void> tapAndWait(WidgetTester tester, Finder button, Finder until) async {
      await tester.runAsync(() async {
        await tester.tap(button);
        for (var i = 0; i < 50 && until.evaluate().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
    }

    Future<void> fillRecount(WidgetTester tester, String total, String bleached, String by) async {
      await tester.enterText(find.byKey(const ValueKey('recount-total')), total);
      await tester.enterText(find.byKey(const ValueKey('recount-bleached')), bleached);
      await tester.enterText(find.byKey(const ValueKey('recount-by')), by);
      await tester.pump();
    }

    Future<Recount?> storedRecount(WidgetTester tester, int id) =>
        withDb(tester, (db) async => (await db.sessionById(id))!.recount);

    void expectNoAppNumbers() {
      expect(find.byType(TabBar), findsNothing);
      expect(find.textContaining('Density'), findsNothing);
      expect(find.textContaining('classified'), findsNothing);
      expect(find.textContaining('prevalence'), findsNothing);
      expect(find.textContaining('colonies were saved'), findsNothing);
      expect(find.textContaining('Track #'), findsNothing);
    }

    testWidgets('hidden mode shows the header and the recount form, no numbers',
        (tester) async {
      final sessionId = await seed(tester, resultsHidden: true);

      await pumpSummary(tester, sessionId);

      expect(find.text('Day-as'), findsOneWidget);
      expect(find.text("The app's results are hidden until the recount is entered."),
          findsOneWidget);
      expect(find.byKey(const ValueKey('recount-total')), findsOneWidget);
      expect(find.text('Reveal without recount'), findsOneWidget);
      expectNoAppNumbers();
    });

    testWidgets('an incomplete hidden session says so without a colony count',
        (tester) async {
      final sessionId = await seed(tester, resultsHidden: true, ended: false);

      await pumpSummary(tester, sessionId);

      expect(find.text('Incomplete.'), findsOneWidget);
      expectNoAppNumbers();
    });

    testWidgets('bleached above total is rejected before saving', (tester) async {
      final sessionId = await seed(tester, resultsHidden: true);
      await pumpSummary(tester, sessionId);

      await fillRecount(tester, '3', '4', 'B. Counter');

      expect(find.text("Bleached can't be more than the total."), findsOneWidget);
      expect(
        tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Save recount')).onPressed,
        isNull,
      );
    });

    testWidgets('a recount saved while hidden is blind and reveals the report',
        (tester) async {
      final sessionId = await seed(tester, resultsHidden: true);
      await pumpSummary(tester, sessionId);

      await fillRecount(tester, '4', '1', 'B. Counter');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save recount'));
      await tester.pumpAndSettle();
      expect(find.textContaining("can't be changed"), findsOneWidget);
      await tapAndWait(tester, find.text('Confirm'), find.byType(TabBar));

      expect(find.byType(TabBar), findsOneWidget);
      expect(find.text('Reveal without recount'), findsNothing);
      final recount = (await storedRecount(tester, sessionId))!;
      expect(recount.blinded, isTrue);
      expect(recount.total, 4);
      expect(recount.countedBy, 'B. Counter');

      await tester.tap(find.text('Technical Detail'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Manual recount (blind)'), findsOneWidget);
      expect(find.text('Add recount'), findsNothing);
    });

    testWidgets('"Reveal without recount" makes a later recount unblinded', (tester) async {
      final sessionId = await seed(tester, resultsHidden: true);
      await pumpSummary(tester, sessionId);

      await tester.tap(find.text('Reveal without recount'));
      await tester.pumpAndSettle();
      expect(find.textContaining('not blind'), findsOneWidget);
      await tapAndWait(tester, find.text('Reveal'), find.byType(TabBar));
      expect(find.byType(TabBar), findsOneWidget);

      await tester.tap(find.text('Technical Detail'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add recount'));
      await tester.pumpAndSettle();
      await fillRecount(tester, '4', '1', 'B. Counter');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save recount'));
      await tester.pumpAndSettle();
      final comparison = find.byKey(const ValueKey('recount-comparison'));
      await tapAndWait(tester, find.text('Confirm'), comparison);

      expect((await storedRecount(tester, sessionId))!.blinded, isFalse);
    });

    testWidgets('the comparison is correct and names both denominators', (tester) async {
      final sessionId = await seed(tester, resultsHidden: false);
      await withDb(
        tester,
        (db) => db.recordRecount(sessionId,
            total: 4, bleached: 1, countedBy: 'B. Counter', at: DateTime.utc(2026, 10, 2, 3)),
      );
      await pumpSummary(tester, sessionId);

      await tester.tap(find.text('Technical Detail'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Manual recount (not blind)'), findsOneWidget);
      // App 3 vs recount 4.
      expect(find.text('Colonies: app 3 · recount 4 · error -1 (-25.0%)'), findsOneWidget);
      // App 1/2 classified = 50 %, recount 1/4 = 25 %.
      expect(
        find.text('Bleaching prevalence: app 50.0% · recount 25.0% · difference +25.0 pp'),
        findsOneWidget,
      );
      expect(
        find.text("App prevalence is over the 2 classified colonies (Uncertain left out); "
            "the recount's is over all 4 counted colonies."),
        findsOneWidget,
      );
    });
  });

  // Sub-plan 16: a colony row on the Technical tab opens the transect video
  // just before that colony first appears.
  group('colony video jump', () {
    final videoStart = DateTime.utc(2026, 10, 1, 9, 0, 1);

    Future<int> seed(TransectDatabase db, {DateTime? videoStartedAt}) async {
      final sessionId = await db.insertSession(
        TransectSession(
          startedAt: DateTime.utc(2026, 10, 1, 9),
          tapeLengthMeters: 50,
          videoPath: '/docs/clip.mov',
          videoStartedAt: videoStartedAt,
        ),
      );
      await db.upsertColony(
        TrackedColonyRecord(
          sessionId: sessionId,
          trackId: 12,
          healthHistory: const [],
          firstSeenAt: videoStart.add(const Duration(minutes: 3, seconds: 41)),
          lastSeenAt: videoStart.add(const Duration(minutes: 3, seconds: 52)),
        ),
      );
      return sessionId;
    }

    Future<void> openTechnicalTab(
      WidgetTester tester,
      TransectDatabase db,
      int sessionId, {
      File? video,
    }) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: SummaryScreen(
              sessionId: sessionId,
              openDatabase: () async => db,
              resolveVideo: (_) async => video,
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Technical Detail'));
      await tester.pumpAndSettle();
      // The colony list is below the fold of the tab's lazy ListView.
      await tester.scrollUntilVisible(
        find.text('Track #12'),
        300,
        scrollable: find
            .byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down)
            .last,
      );
    }

    final playButton = find.byTooltip('Watch in video');

    testWidgets('no video, no play button on the colony rows', (tester) async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await seed(db, videoStartedAt: videoStart);

      await openTechnicalTab(tester, db, sessionId);

      expect(find.text('Track #12'), findsOneWidget);
      expect(playButton, findsNothing);
    });

    testWidgets('opens the player 2 s before the first sighting, titled with the window',
        (tester) async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await seed(db, videoStartedAt: videoStart);

      await openTechnicalTab(tester, db, sessionId, video: File('/docs/clip.mov'));
      await tester.ensureVisible(playButton);
      await tester.tap(playButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final player = tester.widget<VideoPlayerScreen>(find.byType(VideoPlayerScreen));
      expect(player.startAt, const Duration(minutes: 3, seconds: 39));
      expect(player.title, 'Colony #12 · 03:41–03:52');
      expect(player.note, isNull);
    });

    testWidgets('an older session without the video start time is marked approximate',
        (tester) async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await seed(db);

      await openTechnicalTab(tester, db, sessionId, video: File('/docs/clip.mov'));
      await tester.ensureVisible(playButton);
      await tester.tap(playButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final player = tester.widget<VideoPlayerScreen>(find.byType(VideoPlayerScreen));
      // No stored start and no timestamp in the file name: zero is startedAt.
      expect(player.startAt, const Duration(minutes: 3, seconds: 40));
      expect(player.note, 'Position approximate (recorded before video timing was stored)');
    });
  });
}
