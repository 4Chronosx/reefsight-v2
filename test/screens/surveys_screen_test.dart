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

    // No delete affordance anywhere on the screen (decision 8).
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

    await seed('Shown Site', hidden: false, colonies: 2);
    await seed('Hidden Site', hidden: true, colonies: 3);

    await tester.pumpWidget(
      _wrap(SurveysScreen(dataRevision: 0, openDatabase: () async => db)),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 colonies'), findsOneWidget);
    expect(find.text('3 colonies'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Results hidden — recount pending'), findsOneWidget);
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
}
