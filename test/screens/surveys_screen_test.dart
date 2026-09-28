import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/screens/summary_screen.dart';
import 'package:reefsight_mobile/screens/surveys_screen.dart';
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
}
