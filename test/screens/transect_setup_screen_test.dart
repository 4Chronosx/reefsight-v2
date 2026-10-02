import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/screens/transect_setup_screen.dart';
import 'package:reefsight_mobile/services/device_checks.dart';
import 'package:reefsight_mobile/services/device_info.dart';
import 'package:reefsight_mobile/widgets/ready_to_dive_card.dart';

import '../support/fake_device.dart';
import '../support/fake_location.dart';
import 'package:reefsight_mobile/services/geo_fix.dart';
import 'package:reefsight_mobile/services/location_provider.dart';
import 'package:reefsight_mobile/widgets/geo_fix_panel.dart';
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

Future<void> _pumpSetup(
  WidgetTester tester,
  TransectDatabase db, {
  FakeDevice? device,
  LocationProvider? location,
  StartTransect? onStart,
  bool settle = true,
}) async {
  final fake = device ?? FakeDevice();
  await tester.pumpWidget(
    _wrap(
      TransectSetupScreen(
        openDatabase: () async => db,
        storageInfo: fake,
        batteryInfo: fake,
        thermalInfo: fake,
        locationProvider: location ?? FakeLocationProvider.fix(),
        startTransect: onStart ?? (_, _) {},
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

/// A tall test surface, so every Setup card is built at once and the GPS
/// card's buttons can be tapped without scrolling the lazy list.
void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _enterManualFix(WidgetTester tester, String lat, String lon) async {
  await tester.tap(find.text('Enter manually'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const ValueKey('manual-lat')), lat);
  await tester.enterText(find.byKey(const ValueKey('manual-lon')), lon);
  await tester.pump();
}

/// Setup's `ListView` is a lazy sliver list -- on the default 800x600 test
/// surface, the Start button (the last item) isn't built until scrolled
/// into range. A single deterministic drag, not `scrollUntilVisible`
/// (its own internal re-lookup of an ambiguous finder mid-scroll threw
/// "Too many elements" here), reveals it.
Future<void> _revealStartButton(WidgetTester tester) async {
  await tester.drag(find.byType(ListView), const Offset(0, -1500));
  await tester.pumpAndSettle();
}

/// Back to the tape field after [_revealStartButton]: with the "Ready to dive"
/// card (sub-plan 13) the list is long enough that revealing Start scrolls
/// the field out of the lazy list.
Future<void> _scrollToTop(WidgetTester tester) async {
  await tester.drag(find.byType(ListView), const Offset(0, 1500));
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

    await _scrollToTop(tester);
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

    await _scrollToTop(tester);
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

  // Sub-plan 13 step 2 and "Tests": the card renders each status from the
  // fakes, and Start stays enabled when everything is red (decision 1).
  group('Ready to dive card', () {
    testWidgets('shows real readings from the providers', (tester) async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);

      await _pumpSetup(
        tester,
        db,
        device: FakeDevice(
          battery: const BatteryReading(percent: 30, charging: false),
          thermal: ThermalLevel.serious,
        ),
      );
      await _revealStartButton(tester);

      expect(find.text('Ready to dive'), findsOneWidget);
      expect(find.text('64.0 GB free'), findsOneWidget);
      expect(find.text('30%, may not last a long transect.'), findsOneWidget);
      expect(find.textContaining('Hot.'), findsOneWidget);
    });

    testWidgets('everything red still leaves Start enabled', (tester) async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);

      await _pumpSetup(
        tester,
        db,
        device: FakeDevice(
          bytes: 1000,
          battery: const BatteryReading(percent: 5, charging: false),
          thermal: ThermalLevel.critical,
        ),
      );
      await _revealStartButton(tester);

      for (final label in ['Storage', 'Battery', 'Heat']) {
        expect(
          tester.widget<Icon>(find.byKey(ValueKey('device-check-$label'))).icon,
          statusIcon(CheckStatus.critical),
          reason: label,
        );
      }
      expect(tester.widget<ElevatedButton>(_startButton()).onPressed, isNotNull);
    });

    testWidgets('unreadable providers show as unavailable, not as passed',
        (tester) async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);

      await _pumpSetup(
        tester,
        db,
        device: FakeDevice(bytes: null, battery: null, thermal: null),
      );
      await _revealStartButton(tester);

      for (final label in ['Storage', 'Battery', 'Heat']) {
        expect(
          tester.widget<Icon>(find.byKey(ValueKey('device-check-$label'))).icon,
          statusIcon(CheckStatus.unavailable),
          reason: label,
        );
      }
    });
  });

  // Sub-plan 12 tests: "success shows the fix and it's stored on Start;
  // failure shows manual entry, and the manual fix is stored with
  // source: manual; Start stays enabled with no fix." "Stored" here is
  // what Setup hands to Live via the injected `startTransect` -- Live's
  // camera can't run under `flutter test`; the insert itself is covered by
  // transect_database_test.dart's schema v6 group.
  group('Entry position (sub-plan 12)', () {
    testWidgets('a GPS fix is shown and handed to Live on Start', (tester) async {
      _useTallSurface(tester);
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      TransectStart? started;

      await _pumpSetup(tester, db, onStart: (_, start) => started = start);

      // In the Entry position card and in the "Ready to dive" row.
      expect(find.text(formatFix(testGpsFix())), findsNWidgets(2));
      expect(
        tester.widget<Icon>(find.byKey(const ValueKey('device-check-Entry position'))).icon,
        statusIcon(CheckStatus.ok),
      );

      await tester.tap(_startButton());
      await tester.pump();

      expect(started!.entryFix, testGpsFix());
      expect(started!.tapeLengthMeters, 50);
    });

    testWidgets('shows Acquiring… and Checking… until the fix arrives', (tester) async {
      _useTallSurface(tester);
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final location = FakeLocationProvider.fix()..hold = Completer<void>();

      await _pumpSetup(tester, db, location: location, settle: false);
      await tester.pump();

      expect(find.text('Acquiring…'), findsOneWidget);
      expect(find.text("No entry position — it'll be missing from the report."), findsNothing);
      expect(tester.widget<ElevatedButton>(_startButton()).onPressed, isNotNull);

      location.hold!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Acquiring…'), findsNothing);
      expect(find.text(formatFix(testGpsFix())), findsNWidgets(2));
    });

    testWidgets('a failure offers manual entry; the manual fix is handed to Live',
        (tester) async {
      _useTallSurface(tester);
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      TransectStart? started;
      const failure = LocationFailure(LocationFailureKind.permissionDenied);

      await _pumpSetup(
        tester,
        db,
        location: FakeLocationProvider([failure]),
        onStart: (_, start) => started = start,
      );

      expect(find.text(failure.reason), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      await _enterManualFix(tester, '10.2601', '123.9555');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      await tester.tap(_startButton());
      await tester.pump();

      final fix = started!.entryFix!;
      expect(fix.source, GeoFixSource.manual);
      expect(fix.lat, 10.2601);
      expect(fix.lon, 123.9555);
      expect(fix.accuracyM, isNull);
      expect(find.text(formatFix(fix)), findsNWidgets(2));
    });

    testWidgets('no fix warns but leaves Start enabled, and starts with none',
        (tester) async {
      _useTallSurface(tester);
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      TransectStart? started;

      await _pumpSetup(
        tester,
        db,
        location: FakeLocationProvider.failure(LocationFailureKind.servicesOff),
        onStart: (_, start) => started = start,
      );

      expect(
        find.text("No entry position — it'll be missing from the report."),
        findsOneWidget,
      );
      expect(
        tester.widget<Icon>(find.byKey(const ValueKey('device-check-Entry position'))).icon,
        statusIcon(CheckStatus.warn),
      );
      expect(tester.widget<ElevatedButton>(_startButton()).onPressed, isNotNull);

      await tester.tap(_startButton());
      await tester.pump();
      expect(started, isNotNull);
      expect(started!.entryFix, isNull);
    });

    testWidgets('manual entry rejects out-of-range values and hints far from Cordova',
        (tester) async {
      _useTallSurface(tester);
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);

      await _pumpSetup(
        tester,
        db,
        location: FakeLocationProvider.failure(),
      );

      Finder saveButton() => find.widgetWithText(TextButton, 'Save');

      // Swapped lat/lon: latitude 123.95 is out of range.
      await _enterManualFix(tester, '123.95', '10.25');
      expect(tester.widget<TextButton>(saveButton()).onPressed, isNull);

      // A dropped minus sign elsewhere is valid but far: hint, still savable.
      await tester.enterText(find.byKey(const ValueKey('manual-lat')), '10.25');
      await tester.enterText(find.byKey(const ValueKey('manual-lon')), '-123.95');
      await tester.pump();
      expect(find.text(farFromCordovaHint), findsOneWidget);
      expect(tester.widget<TextButton>(saveButton()).onPressed, isNotNull);
    });
  });

  // Sub-plan 14 decision 1: blinding is chosen per transect, at Setup.
  group('Recount planned', () {
    final recountSwitch = find.byKey(const ValueKey('recount-planned'));

    testWidgets('is off by default, so results are shown', (tester) async {
      _useTallSurface(tester);
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      TransectStart? started;
      await _pumpSetup(tester, db, onStart: (_, start) => started = start);

      expect(tester.widget<SwitchListTile>(recountSwitch).value, isFalse);
      await tester.tap(_startButton());
      await tester.pump();

      expect(started!.resultsHidden, isFalse);
    });

    testWidgets('switched on, Start hands Live resultsHidden', (tester) async {
      _useTallSurface(tester);
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      TransectStart? started;
      await _pumpSetup(tester, db, onStart: (_, start) => started = start);

      await tester.tap(recountSwitch);
      await tester.pump();
      await tester.tap(_startButton());
      await tester.pump();

      expect(started!.resultsHidden, isTrue);
    });
  });
}
