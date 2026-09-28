import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/screens/home_screen.dart';
import 'package:reefsight_mobile/screens/summary_screen.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Sub-plan 6 (ui-ux-overhaul), step 3: Home's "Recent surveys" strip, via
// `HomeScreen`'s injected `openDatabase` seam (real in-memory SQLite,
// `flutter_test_config.dart`'s `databaseFactoryFfiNoIsolate`, not
// `path_provider`).

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('shows a one-line empty state when there are no surveys yet',
      (tester) async {
    final db = await TransectDatabase.openInMemoryForTest();
    addTearDown(db.close);

    await tester.pumpWidget(
      _wrap(HomeScreen(
        dataRevision: 0,
        onSeeAllSurveys: () {},
        openDatabase: () async => db,
      )),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('No surveys yet'), findsOneWidget);
  });

  testWidgets('shows at most the latest 3 surveys and opens Summary on tap',
      (tester) async {
    final db = await TransectDatabase.openInMemoryForTest();
    addTearDown(db.close);

    for (var i = 0; i < 4; i++) {
      await db.insertSession(
        TransectSession(
          startedAt: DateTime.utc(2026, 1, i + 1),
          tapeLengthMeters: 50,
          siteName: 'Site $i',
        ),
      );
    }

    await tester.pumpWidget(
      _wrap(HomeScreen(
        dataRevision: 0,
        onSeeAllSurveys: () {},
        openDatabase: () async => db,
      )),
    );
    await tester.pumpAndSettle();

    // Newest 3 (Site 3, 2, 1) show; the oldest (Site 0) is beyond the cap.
    expect(find.text('Site 3'), findsOneWidget);
    expect(find.text('Site 0'), findsNothing);

    // The "Recent surveys" strip sits below the fold of Home's
    // `SingleChildScrollView` at the default 800x600 test surface --
    // `ensureVisible` scrolls it into view first, the same as a real user
    // would scroll before tapping.
    await tester.ensureVisible(find.text('Site 3'));
    await tester.tap(find.text('Site 3'));
    // Bounded pumps rather than `pumpAndSettle()`: `SummaryScreen`'s own
    // report load briefly shows an indeterminate `CircularProgressIndicator`
    // -- see `surveys_screen_test.dart`'s matching comment.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(SummaryScreen), findsOneWidget);
  });

  testWidgets('"See all" invokes onSeeAllSurveys', (tester) async {
    final db = await TransectDatabase.openInMemoryForTest();
    addTearDown(db.close);
    var tapped = false;

    await tester.pumpWidget(
      _wrap(HomeScreen(
        dataRevision: 0,
        onSeeAllSurveys: () => tapped = true,
        openDatabase: () async => db,
      )),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('See all'));
    await tester.tap(find.text('See all'));
    await tester.pump();

    expect(tapped, isTrue);
  });
}
