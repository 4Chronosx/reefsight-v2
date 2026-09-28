import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/screens/transect_setup_screen.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Sub-plan 6 (ui-ux-overhaul), step 8: "Setup defaults to 50 m. Tapping the
// 50, 75, or 100 chip fills the field. A blank or non-positive value
// disables start. A positive value outside 50-100 (for example 30 or 150)
// shows the hint but keeps start enabled. Site and observer are prefilled
// from the latest session." Uses `TransectDatabase.openInMemoryForTest()`
// via the injected `openDatabase` seam, not `path_provider` (see
// `flutter_test_config.dart`'s `databaseFactoryFfiNoIsolate`, required for
// real DB I/O to work under `testWidgets`).

Widget _wrap(Widget child) => MaterialApp(home: child);

Finder _startButton() => find.widgetWithText(ElevatedButton, 'Start Transect');
Finder _tapeField() => find.byType(TextField).first;

Future<void> _pumpSetup(WidgetTester tester, TransectDatabase db) async {
  await tester.pumpWidget(_wrap(TransectSetupScreen(openDatabase: () async => db)));
  await tester.pumpAndSettle();
}

/// Setup's `ListView` is a lazy sliver list -- on the default 800x600 test
/// surface, the Start button (the last item) isn't built until scrolled
/// into range. A single deterministic drag, not `scrollUntilVisible`
/// (its own internal re-lookup of an ambiguous finder mid-scroll threw
/// "Too many elements" here), reveals it.
Future<void> _revealStartButton(WidgetTester tester) async {
  await tester.drag(find.byType(ListView), const Offset(0, -400));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('defaults tape length to 50', (tester) async {
    final db = await TransectDatabase.openInMemoryForTest();
    addTearDown(db.close);

    await _pumpSetup(tester, db);

    final field = tester.widget<TextField>(_tapeField());
    expect(field.controller!.text, '50');
  });

  testWidgets('tapping a preset chip fills the field', (tester) async {
    final db = await TransectDatabase.openInMemoryForTest();
    addTearDown(db.close);

    await _pumpSetup(tester, db);

    await tester.tap(find.widgetWithText(ChoiceChip, '75 m'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(_tapeField());
    expect(field.controller!.text, '75');
  });

  testWidgets('a blank or non-positive value disables Start', (tester) async {
    final db = await TransectDatabase.openInMemoryForTest();
    addTearDown(db.close);

    await _pumpSetup(tester, db);

    await tester.enterText(_tapeField(), '0');
    await tester.pumpAndSettle();
    await _revealStartButton(tester);
    expect(tester.widget<ElevatedButton>(_startButton()).onPressed, isNull);

    await tester.enterText(_tapeField(), '');
    await tester.pumpAndSettle();
    await _revealStartButton(tester);
    expect(tester.widget<ElevatedButton>(_startButton()).onPressed, isNull);
  });

  testWidgets(
      'a positive value outside 50-100 shows the hint but keeps Start enabled',
      (tester) async {
    final db = await TransectDatabase.openInMemoryForTest();
    addTearDown(db.close);

    await _pumpSetup(tester, db);

    await tester.enterText(_tapeField(), '30');
    await tester.pumpAndSettle();

    expect(find.textContaining('Outside the usual 50-100 m range'), findsOneWidget);
    await _revealStartButton(tester);
    expect(tester.widget<ElevatedButton>(_startButton()).onPressed, isNotNull);

    await tester.enterText(_tapeField(), '150');
    await tester.pumpAndSettle();

    expect(find.textContaining('Outside the usual 50-100 m range'), findsOneWidget);
    await _revealStartButton(tester);
    expect(tester.widget<ElevatedButton>(_startButton()).onPressed, isNotNull);
  });

  testWidgets('prefills site and observer from the most recent session',
      (tester) async {
    final db = await TransectDatabase.openInMemoryForTest();
    addTearDown(db.close);
    await db.insertSession(
      TransectSession(
        startedAt: DateTime.utc(2026, 1, 1),
        tapeLengthMeters: 50,
        siteName: 'Old Site',
        observerName: 'Old Observer',
      ),
    );
    await db.insertSession(
      TransectSession(
        startedAt: DateTime.utc(2026, 1, 5),
        tapeLengthMeters: 60,
        siteName: 'Newest Site',
        observerName: 'Newest Observer',
      ),
    );

    await _pumpSetup(tester, db);

    expect(find.text('Newest Site'), findsOneWidget);
    expect(find.text('Newest Observer'), findsOneWidget);
  });
}
