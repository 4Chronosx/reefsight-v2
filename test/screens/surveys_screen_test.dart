import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/screens/summary_screen.dart';
import 'package:reefsight_mobile/screens/surveys_screen.dart';
import 'package:reefsight_mobile/services/tracked_colony_record.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Sub-plan 6 (ui-ux-overhaul), step 8: "Surveys shows its empty state with
// an empty DB, lists seeded sessions newest first, marks an incomplete one,
// and a tap opens Summary with the right sessionId. There's no delete
// affordance." Uses `TransectDatabase.openInMemoryForTest()` (real SQLite
// via `sqflite_common_ffi`, see `flutter_test_config.dart`'s
// `databaseFactoryFfiNoIsolate`) through `SurveysScreen`'s injected
// `openDatabase`, not `path_provider`.

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('shows an empty state with an empty DB', (tester) async {
    final db = await TransectDatabase.openInMemoryForTest();
    addTearDown(db.close);

    await tester.pumpWidget(
      _wrap(SurveysScreen(dataRevision: 0, openDatabase: () async => db)),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Completed and in-progress surveys will show up here.'),
      findsOneWidget,
    );
    expect(find.text('Start your first survey'), findsOneWidget);
  });

  testWidgets(
      'lists seeded sessions newest first, marks only the in-progress one '
      'incomplete, and opens the right Summary on tap', (tester) async {
    final db = await TransectDatabase.openInMemoryForTest();
    addTearDown(db.close);

    final olderCompletedId = await db.insertSession(
      TransectSession(
        startedAt: DateTime.utc(2026, 1, 1),
        tapeLengthMeters: 50,
        siteName: 'Older Site',
      ),
    );
    await db.closeSession(olderCompletedId, DateTime.utc(2026, 1, 1, 1));

    final newerInProgressId = await db.insertSession(
      TransectSession(
        startedAt: DateTime.utc(2026, 1, 5),
        tapeLengthMeters: 75,
        siteName: 'Newer Site',
      ),
    );

    await tester.pumpWidget(
      _wrap(SurveysScreen(dataRevision: 0, openDatabase: () async => db)),
    );
    await tester.pumpAndSettle();

    // Only the in-progress session is flagged, not the completed one.
    expect(find.text('Incomplete'), findsOneWidget);

    final siteTexts = tester
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data)
        .whereType<String>()
        .where((t) => t == 'Older Site' || t == 'Newer Site')
        .toList();
    // Newest-started-first: Newer Site's card renders before Older Site's.
    expect(siteTexts, ['Newer Site', 'Older Site']);

    // No delete button on the cards: deleting is behind a long-press.
    expect(find.byIcon(Icons.delete), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);

    await tester.ensureVisible(find.text('Newer Site'));
    await tester.tap(find.text('Newer Site'));
    // Bounded pumps rather than `pumpAndSettle()`: `SummaryScreen`'s own
    // report load briefly shows an indeterminate `CircularProgressIndicator`
    // -- an actively-ticking widget can make `pumpAndSettle()` hang if
    // anything upstream delays settling, so this only pumps enough to reach
    // the pushed screen rather than waiting for full animation quiescence.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final summary = tester.widget<SummaryScreen>(find.byType(SummaryScreen));
    expect(summary.sessionId, newerInProgressId);
  });

  // Sub-plan 14: a "Recount planned" survey's card shows no app numbers
  // until its results are revealed.
  testWidgets('a hidden-results survey card shows no count or bleaching bar',
      (tester) async {
    final db = await TransectDatabase.openInMemoryForTest();
    addTearDown(db.close);
    Future<void> seed(String site, {required bool hidden, required int colonies}) async {
      final id = await db.insertSession(
        TransectSession(
          startedAt: DateTime.utc(2026, 1, colonies),
          tapeLengthMeters: 50,
          siteName: site,
          resultsHidden: hidden,
        ),
      );
      for (var i = 0; i < colonies; i++) {
        await db.upsertColony(
          TrackedColonyRecord(
            sessionId: id,
            trackId: i + 1,
            healthLabel: 'CORAL_BL',
            healthHistory: const [],
            firstSeenAt: DateTime.utc(2026, 1, 1),
            lastSeenAt: DateTime.utc(2026, 1, 1),
          ),
        );
      }
    }

    // 10 colonies: at the sub-plan 17 threshold, so the bar shows.
    await seed('Shown Site', hidden: false, colonies: 10);
    await seed('Hidden Site', hidden: true, colonies: 3);

    await tester.pumpWidget(
      _wrap(SurveysScreen(dataRevision: 0, openDatabase: () async => db)),
    );
    await tester.pumpAndSettle();

    expect(find.text('10 colonies'), findsOneWidget);
    expect(find.text('3 colonies'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Results hidden — recount pending'), findsOneWidget);
  });

  // Sub-plan 17: the bar and figure are over classified colonies (sub-plan
  // 10's denominator, as on Summary), with the Wilson interval -- or "too
  // few" and no bar below `minClassifiedForPrevalence`.
  testWidgets('bleaching is over classified colonies, with its interval or too few',
      (tester) async {
    final db = await TransectDatabase.openInMemoryForTest();
    addTearDown(db.close);
    Future<void> seed(String site, List<String?> labels, {required int day}) async {
      final id = await db.insertSession(
        TransectSession(
          startedAt: DateTime.utc(2026, 1, day),
          tapeLengthMeters: 50,
          siteName: site,
        ),
      );
      for (var i = 0; i < labels.length; i++) {
        await db.upsertColony(
          TrackedColonyRecord(
            sessionId: id,
            trackId: i + 1,
            healthLabel: labels[i],
            healthHistory: const [],
            firstSeenAt: DateTime.utc(2026, 1, day),
            lastSeenAt: DateTime.utc(2026, 1, day),
          ),
        );
      }
    }

    // 2 bleached of 10 classified, plus 10 uncertain: 20%, not 2 / 20.
    await seed('Big Site', [
      ...List.filled(2, 'CORAL_BL'),
      ...List.filled(8, 'CORAL'),
      ...List<String?>.filled(10, null),
    ], day: 1);
    await seed('Small Site', [
      ...List.filled(3, 'CORAL_BL'),
      ...List.filled(3, 'CORAL'),
    ], day: 2);

    await tester.pumpWidget(
      _wrap(SurveysScreen(dataRevision: 0, openDatabase: () async => db)),
    );
    await tester.pumpAndSettle();

    expect(find.text('20% bleached (6–51%)'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, 0.2);
    expect(find.text('Too few classified (n = 6)'), findsOneWidget);
  });

  testWidgets('nothing classified says so; a narrow phone at 1.5x text does not overflow',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final db = await TransectDatabase.openInMemoryForTest();
    addTearDown(db.close);
    Future<void> seed(String site, List<String?> labels, {required int day}) async {
      final id = await db.insertSession(
        TransectSession(startedAt: DateTime.utc(2026, 1, day), tapeLengthMeters: 50, siteName: site),
      );
      for (var i = 0; i < labels.length; i++) {
        await db.upsertColony(
          TrackedColonyRecord(
            sessionId: id,
            trackId: i + 1,
            healthLabel: labels[i],
            healthHistory: const [],
            firstSeenAt: DateTime.utc(2026, 1, day),
            lastSeenAt: DateTime.utc(2026, 1, day),
          ),
        );
      }
    }

    await seed('Unclassified Site', List<String?>.filled(4, null), day: 1);
    await seed('Small Site', [...List.filled(3, 'CORAL_BL'), ...List.filled(3, 'CORAL')], day: 2);

    await tester.pumpWidget(
      _wrap(SurveysScreen(dataRevision: 0, openDatabase: () async => db)),
    );
    await tester.pumpAndSettle();

    expect(find.text('None classified'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // File-backed, not in-memory: the export re-reads the list through a new
  // handle, and Surveys closes every handle it opens.
  testWidgets('exporting recount comparisons with none recounted says so',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('reefsight_surveys_export_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final message = find.text('No recounted surveys to export yet.');

    await tester.runAsync(() async {
      final db = await TransectDatabase.open(dir.path);
      await db.insertSession(
        TransectSession(startedAt: DateTime.utc(2026, 1, 1), tapeLengthMeters: 50),
      );
      await db.close();

      await tester.pumpWidget(
        _wrap(SurveysScreen(
          dataRevision: 0,
          openDatabase: () => TransectDatabase.open(dir.path),
        )),
      );
      for (var i = 0; i < 50 && find.byType(Card).evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }

      await tester.tap(find.byTooltip('Export recount comparisons'));
      for (var i = 0; i < 50 && message.evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();

    expect(message, findsOneWidget);
  });

  // Survey deletion (phone only): long-press -> "Delete survey" -> confirm.
  // File-backed for the same reason as the export test.
  group('deleting a survey', () {
    late Directory dir;
    late List<int?> filesDeletedFor;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('reefsight_surveys_delete_');
      filesDeletedFor = [];
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<void> pumpUntil(WidgetTester tester, Finder finder, {bool gone = false}) async {
      for (var i = 0; i < 50 && finder.evaluate().isEmpty != gone; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    // DB I/O inside `runAsync` (real SQLite); the gestures outside it, on
    // the fake clock -- a long-press timer started inside `runAsync` is a
    // real timer the pumps never fire, so the press lands as a tap.
    Future<void> seedAndOpen(WidgetTester tester) async {
      await tester.runAsync(() async {
        final db = await TransectDatabase.open(dir.path);
        for (final (day, site) in [(1, 'Keep Site'), (2, 'Drop Site')]) {
          final id = await db.insertSession(
            TransectSession(startedAt: DateTime.utc(2026, 1, day), tapeLengthMeters: 50, siteName: site),
          );
          await db.upsertColony(
            TrackedColonyRecord(
              sessionId: id,
              trackId: 1,
              healthHistory: const [],
              firstSeenAt: DateTime.utc(2026, 1, day),
              lastSeenAt: DateTime.utc(2026, 1, day),
            ),
          );
        }
        await db.close();

        await tester.pumpWidget(
          _wrap(SurveysScreen(
            dataRevision: 0,
            openDatabase: () => TransectDatabase.open(dir.path),
            deleteFiles: (session) async => filesDeletedFor.add(session.id),
          )),
        );
        await pumpUntil(tester, find.text('Drop Site'));
      });

      await tester.longPress(find.text('Drop Site'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete survey'));
      await tester.pumpAndSettle();
    }

    Future<List<String?>> remainingSites() async {
      final db = await TransectDatabase.open(dir.path);
      try {
        return [for (final s in await db.listSessions()) s.session.siteName];
      } finally {
        await db.close();
      }
    }

    testWidgets('confirming removes it from the list, the DB and its files', (tester) async {
      late List<String?> sites;
      await seedAndOpen(tester);
      expect(find.textContaining("can't be undone"), findsOneWidget);

      // Tapped inside `runAsync`, like the export test: the delete's DB
      // open/close must run on the real clock, or sqflite's open lock is
      // still held when `remainingSites` opens the file.
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
        // Wait on the deleted card first: "Keep Site" and "no spinner" are
        // both already true before the delete runs, so waiting on them alone
        // raced the delete. Then until the reloaded list is up -- the
        // reload's spinner would keep `pumpAndSettle` from settling.
        await pumpUntil(tester, find.text('Drop Site'), gone: true);
        await pumpUntil(tester, find.byType(CircularProgressIndicator), gone: true);
        await pumpUntil(tester, find.text('Keep Site'));
        sites = await remainingSites();
      });
      await tester.pumpAndSettle();

      expect(find.text('Drop Site'), findsNothing);
      expect(find.text('Survey deleted.'), findsOneWidget);
      expect(find.text('Keep Site'), findsOneWidget);
      expect(sites, ['Keep Site']);
      expect(filesDeletedFor, hasLength(1));
    });

    testWidgets('cancelling keeps it', (tester) async {
      late List<String?> sites;
      await seedAndOpen(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this survey?'), findsNothing);
      await tester.runAsync(() async => sites = await remainingSites());

      expect(find.text('Drop Site'), findsOneWidget);
      expect(sites, ['Drop Site', 'Keep Site']);
      expect(filesDeletedFor, isEmpty);
    });
  });
}
