import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/screens/capture_placeholder_screen.dart';
import 'package:reefsight_mobile/screens/home_screen.dart';
import 'package:reefsight_mobile/screens/photo_import_screen.dart';
import 'package:reefsight_mobile/screens/photo_transect_capture_screen.dart';
import 'package:reefsight_mobile/screens/station_detail_screen.dart';
import 'package:reefsight_mobile/screens/station_edit_screen.dart';
import 'package:reefsight_mobile/screens/station_summary_screen.dart';
import 'package:reefsight_mobile/screens/station_transect_setup_screen.dart';
import 'package:reefsight_mobile/screens/summary_screen.dart';
import 'package:reefsight_mobile/screens/surveys_screen.dart';
import 'package:reefsight_mobile/screens/transect_setup_screen.dart';
import 'package:reefsight_mobile/services/health_aggregator.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/station_checks.dart';
import 'package:reefsight_mobile/services/station_diversity.dart';
import 'package:reefsight_mobile/services/station_summary.dart';
import 'package:reefsight_mobile/services/tracked_colony_record.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_frame.dart';
import 'package:reefsight_mobile/services/transect_placement.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

import '../support/fake_capture.dart';
import '../support/fake_device.dart';
import '../support/fake_location.dart';

// Issue #2: the station screens -- create/edit, detail, per-transect setup
// with TB 2019-04's random placement, and routing by survey type. Real
// in-memory SQLite (`ignoreClose`, since each screen closes the handle it
// opens) on the fake clock; a tall surface so every card is built.

void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<TransectDatabase> _db() async {
  final db = await TransectDatabase.openInMemoryForTest(ignoreClose: true);
  addTearDown(db.closeForTest);
  return db;
}

Station _station({
  SurveyType type = SurveyType.photoTransect,
  double? depthMaxM,
  String? siteName = 'Alegria MPA',
  String? observerName = 'Diver A',
}) =>
    Station(
      code: 'ALG-S1',
      surveyType: type,
      frameMode: type == SurveyType.photoTransect ? FrameMode.physical : null,
      surveyedOn: DateTime(2026, 11, 15),
      siteName: siteName,
      observerName: observerName,
      depthMaxM: depthMaxM,
      createdAt: DateTime.utc(2026, 11, 14),
    );

TransectSession _transect(int stationId, int number, {double tape = 50, double? depthEndM}) =>
    TransectSession(
      startedAt: DateTime.utc(2026, 11, 15, number),
      tapeLengthMeters: tape,
      stationId: stationId,
      transectNumber: number,
      depthEndM: depthEndM,
    );

Finder _field(String key) => find.byKey(ValueKey(key));

/// Issue #3: [bleached] bleached and [healthy] healthy colonies on a
/// colony-count transect, as Live's recorder writes them.
Future<void> _colonies(TransectDatabase db, int sessionId, {required int bleached, required int healthy}) async {
  final at = DateTime.utc(2026, 11, 15, 2);
  var trackId = 0;
  for (final label in [
    for (var i = 0; i < bleached; i++) HealthAggregator.bleachedLabel,
    for (var i = 0; i < healthy; i++) HealthAggregator.healthyLabel,
  ]) {
    await db.upsertColony(
      TrackedColonyRecord(
        sessionId: sessionId,
        trackId: ++trackId,
        healthLabel: label,
        healthHistory: const [],
        firstSeenAt: at,
        lastSeenAt: at,
      ),
    );
  }
}

/// A host screen with a button that pushes [screen], recording what it
/// pops with -- the edit screen pops the saved station's id.
class _Host extends StatelessWidget {
  const _Host({required this.screen, required this.onResult});

  final Widget screen;
  final ValueChanged<Object?> onResult;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async =>
                onResult(await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen))),
            child: const Text('open'),
          ),
        ),
      );
}

Widget _setup(
  Station station,
  TransectDatabase db, {
  StartTransect? onStart,
  OpenCapture? onCapture,
  Random? random,
}) {
  final fake = FakeDevice();
  return StationTransectSetupScreen(
    station: station,
    openDatabase: () async => db,
    storageInfo: fake,
    batteryInfo: fake,
    thermalInfo: fake,
    locationProvider: FakeLocationProvider.fix(),
    startTransect: onStart ?? (_, _) {},
    openCapture: onCapture ?? (_, _) {},
    random: random,
  );
}

void main() {
  group('StationEditScreen', () {
    testWidgets('a new station needs a code; frame mode shows for photo transects only',
        (tester) async {
      _useTallSurface(tester);
      final db = await _db();
      Object? result;
      await tester.pumpWidget(MaterialApp(
        home: _Host(
          screen: StationEditScreen(
            openDatabase: () async => db,
            locationProvider: FakeLocationProvider.fix(),
          ),
          onResult: (r) => result = r,
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final save = find.widgetWithText(ElevatedButton, 'Save station');
      expect(tester.widget<ElevatedButton>(save).onPressed, isNull);
      expect(find.text('Physical frame'), findsOneWidget);

      await tester.tap(find.text('Colony count (research)'));
      await tester.pump();
      expect(find.text('Physical frame'), findsNothing);

      await tester.tap(find.text('Photo transect'));
      await tester.pump();
      await tester.tap(find.text('Imported photos'));
      await tester.enterText(_field('station-code'), ' ALG-S2 ');
      await tester.enterText(_field('station-site'), 'Alegria MPA');
      await tester.enterText(_field('depth-min'), '4');
      await tester.enterText(_field('depth-max'), '5.5');
      await tester.tap(find.text('Upper slope'));
      await tester.pump();
      expect(tester.widget<ElevatedButton>(save).onPressed, isNotNull);

      await tester.tap(save);
      await tester.pumpAndSettle();

      final stations = await db.listStations();
      expect(stations, hasLength(1));
      final saved = stations.single.station;
      expect(result, saved.id);
      expect(saved.code, 'ALG-S2');
      expect(saved.surveyType, SurveyType.photoTransect);
      expect(saved.frameMode, FrameMode.importedMixed);
      expect(saved.reefZone, ReefZone.upperSlope);
      expect(saved.depthMinM, 4);
      expect(saved.depthMaxM, 5.5);
      expect(saved.siteName, 'Alegria MPA');
    });

    testWidgets('a max depth over 6 m is flagged, and below the min is an error',
        (tester) async {
      _useTallSurface(tester);
      final db = await _db();
      await tester.pumpWidget(MaterialApp(
        home: StationEditScreen(
          openDatabase: () async => db,
          locationProvider: FakeLocationProvider.fix(),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(_field('station-code'), 'ALG-S1');
      await tester.enterText(_field('depth-max'), '7');
      await tester.pump();
      expect(find.text(kFlagStationTooDeep), findsOneWidget);
      final save = find.widgetWithText(ElevatedButton, 'Save station');
      expect(tester.widget<ElevatedButton>(save).onPressed, isNotNull);

      await tester.enterText(_field('depth-min'), '8');
      await tester.pump();
      expect(find.text('Deeper than the max'), findsOneWidget);
      expect(tester.widget<ElevatedButton>(save).onPressed, isNull);
    });

    testWidgets('editing a station with transects locks survey type and frame mode',
        (tester) async {
      _useTallSurface(tester);
      final db = await _db();
      final id = await db.insertStation(_station());
      final existing = (await db.stationById(id))!;
      await tester.pumpWidget(MaterialApp(
        home: StationEditScreen(
          openDatabase: () async => db,
          locationProvider: FakeLocationProvider.fix(),
          existing: existing,
          transectCount: 1,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('Locked'), findsOneWidget);
      await tester.tap(find.text('Colony count (research)'));
      await tester.enterText(_field('station-code'), 'ALG-S1b');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save station'));
      await tester.pumpAndSettle();

      final saved = (await db.stationById(id))!;
      expect(saved.code, 'ALG-S1b');
      expect(saved.surveyType, SurveyType.photoTransect);
      expect(saved.createdAt, existing.createdAt);
    });
  });

  group('StationTransectSetupScreen', () {
    testWidgets('preselects the next free number and disables the used ones', (tester) async {
      _useTallSurface(tester);
      final db = await _db();
      final id = await db.insertStation(_station());
      await db.insertSession(_transect(id, 1));
      await db.insertSession(_transect(id, 3));
      final station = (await db.stationById(id))!;

      await tester.pumpWidget(MaterialApp(home: _setup(station, db)));
      await tester.pumpAndSettle();

      ChoiceChip chip(int n) => tester.widget<ChoiceChip>(_field('transect-number-$n'));
      expect(chip(4).selected, isTrue);
      expect(chip(1).onSelected, isNull);
      expect(chip(3).onSelected, isNull);
      expect(chip(2).onSelected, isNotNull);
    });

    testWidgets('Generate fills the random placement; flags show for depth and tape',
        (tester) async {
      _useTallSurface(tester);
      final db = await _db();
      final id = await db.insertStation(_station());
      final station = (await db.stationById(id))!;
      final expected = generateRandomPlacement(Random(3));

      await tester.pumpWidget(MaterialApp(home: _setup(station, db, random: Random(3))));
      await tester.pumpAndSettle();

      await tester.tap(_field('generate-placement'));
      await tester.pump();
      expect(
        tester.widget<TextField>(_field('random-along')).controller!.text,
        expected.alongM.toString(),
      );
      expect(
        tester.widget<TextField>(_field('random-swimout')).controller!.text,
        expected.swimoutM.toString(),
      );

      await tester.enterText(_field('tape-length'), '75');
      await tester.enterText(_field('depth-end'), '6.5');
      await tester.pump();
      expect(find.text('Not the standard 50 m tape (TB 2019-04)'), findsOneWidget);
      expect(find.text(kFlagTransectTooDeep), findsOneWidget);

      await tester.enterText(_field('random-along'), '80');
      await tester.pump();
      expect(find.text('Enter 0-75 m'), findsOneWidget);
    });

    testWidgets('colony count hands Live the station and placement', (tester) async {
      _useTallSurface(tester);
      final db = await _db();
      final id = await db.insertStation(_station(type: SurveyType.colonyCount));
      final station = (await db.stationById(id))!;
      TransectStart? started;

      await tester.pumpWidget(MaterialApp(
        home: _setup(station, db, onStart: (_, start) => started = start),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(_field('depth-start'), '4.5');
      await tester.enterText(_field('depth-end'), '5');
      await tester.enterText(_field('random-along'), '12.3');
      await tester.enterText(_field('random-swimout'), '8.1');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Start Transect'));
      await tester.pumpAndSettle();

      expect(started, isNotNull);
      expect(started!.tapeLengthMeters, 50);
      expect(started!.siteName, 'Alegria MPA');
      expect(started!.observerName, 'Diver A');
      final placement = started!.placement!;
      expect(placement.stationId, id);
      expect(placement.transectNumber, 1);
      expect(placement.captureSource, CaptureSource.legacyColony);
      expect(placement.depthStartM, 4.5);
      expect(placement.depthEndM, 5);
      expect(placement.randomAlongM, 12.3);
      expect(placement.randomSwimoutM, 8.1);
      // Live inserts the colony-count session, not Setup.
      expect(await db.transectsForStation(id), isEmpty);
    });

    // Review fix: Live inserts colony-count rows and keeps recording if that
    // insert fails, so a number taken since the screen opened must be caught
    // before Live is pushed.
    testWidgets('a number taken since opening is refused before Live', (tester) async {
      _useTallSurface(tester);
      final db = await _db();
      final id = await db.insertStation(_station(type: SurveyType.colonyCount));
      final station = (await db.stationById(id))!;
      var starts = 0;

      await tester.pumpWidget(MaterialApp(
        home: _setup(station, db, onStart: (_, _) => starts++),
      ));
      await tester.pumpAndSettle();
      await db.insertSession(_transect(id, 1)); // e.g. a Live left with back
      await tester.tap(find.widgetWithText(ElevatedButton, 'Start Transect'));
      await tester.pumpAndSettle();

      expect(starts, 0);
      expect(find.text('T1 is already taken. Pick another number.'), findsOneWidget);
      final t1 = tester.widget<ChoiceChip>(_field('transect-number-1'));
      expect(t1.onSelected, isNull);
      expect(tester.widget<ChoiceChip>(_field('transect-number-2')).selected, isTrue);
    });

    testWidgets('colony count: one Live per tap, numbers refreshed when Live returns',
        (tester) async {
      _useTallSurface(tester);
      final db = await _db();
      final id = await db.insertStation(_station(type: SurveyType.colonyCount));
      final station = (await db.stationById(id))!;
      final live = Completer<void>();
      var starts = 0;

      await tester.pumpWidget(MaterialApp(
        home: _setup(station, db, onStart: (_, _) {
          starts++;
          return live.future;
        }),
      ));
      await tester.pumpAndSettle();
      final start = find.widgetWithText(ElevatedButton, 'Start Transect');
      await tester.tap(start);
      await tester.pumpAndSettle();
      expect(tester.widget<ElevatedButton>(start).onPressed, isNull);
      await tester.tap(start);
      await tester.pumpAndSettle();
      expect(starts, 1);

      await db.insertSession(_transect(id, 1)); // what Live inserted
      live.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(_field('transect-number-1')).onSelected, isNull);
      expect(tester.widget<ChoiceChip>(_field('transect-number-2')).selected, isTrue);
      expect(tester.widget<ElevatedButton>(start).onPressed, isNotNull);
    });

    for (final (type, label, source) in [
      (SurveyType.photoTransect, 'Start photo capture', CaptureSource.inAppPhotos),
      (SurveyType.preliminaryVideo, 'Start video capture', CaptureSource.inAppVideo),
    ]) {
      testWidgets('${type.name} saves the transect and opens its capture flow', (tester) async {
        _useTallSurface(tester);
        final db = await _db();
        final id = await db.insertStation(_station(type: type));
        final station = (await db.stationById(id))!;
        CaptureStart? opened;

        await tester.pumpWidget(MaterialApp(
          home: _setup(station, db, onCapture: (_, start) => opened = start),
        ));
        await tester.pumpAndSettle();
        await tester.enterText(_field('depth-start'), '5');
        await tester.pump();
        await tester.tap(find.widgetWithText(ElevatedButton, label));
        await tester.pumpAndSettle();

        final transects = await db.transectsForStation(id);
        expect(transects, hasLength(1));
        final t = transects.single;
        expect(opened!.sessionId, t.id);
        expect(opened!.transectNumber, 1);
        expect(t.transectNumber, 1);
        expect(t.captureSource, source);
        expect(t.depthStartM, 5);
        expect(t.siteName, 'Alegria MPA');
        expect(t.pointsPerFrame, 10);
        expect(t.endedAt, isNull);
      });
    }
  });

  group('StationDetailScreen', () {
    testWidgets('lists transects with status and flags, and the station flags', (tester) async {
      _useTallSurface(tester);
      final db = await _db();
      final id = await db.insertStation(_station(depthMaxM: 7));
      await db.insertSession(_transect(id, 2, tape: 75));
      await db.insertSession(_transect(id, 1, depthEndM: 6.5));

      await tester.pumpWidget(MaterialApp(
        home: StationDetailScreen(stationId: id, openDatabase: () async => db),
      ));
      await tester.pumpAndSettle();

      expect(find.text('ALG-S1'), findsWidgets);
      expect(find.text(kFlagStationTooDeep), findsOneWidget);
      expect(find.text(kFlagFewTransects), findsOneWidget);
      expect(find.text('T1'), findsOneWidget);
      expect(find.text('T2'), findsOneWidget);
      expect(find.text('Awaiting capture'), findsNWidgets(2));
      expect(find.text(kFlagTransectTooDeep), findsOneWidget);
      expect(find.text('Tape is 75 m, not 50 m'), findsOneWidget);
      final add = find.widgetWithText(ElevatedButton, 'Add transect');
      expect(tester.widget<ElevatedButton>(add).onPressed, isNotNull);
    });

    testWidgets('long-press deletes a transect, its files, and reloads', (tester) async {
      _useTallSurface(tester);
      final db = await _db();
      final id = await db.insertStation(_station());
      await db.insertSession(_transect(id, 1));
      final t2 = await db.insertSession(_transect(id, 2));
      final filesDeleted = <int?>[];
      await tester.pumpWidget(MaterialApp(
        home: StationDetailScreen(
          stationId: id,
          openDatabase: () async => db,
          deleteFiles: (s) async => filesDeleted.add(s.id),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('T2'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(filesDeleted, [t2]);
      expect(find.text('T2'), findsNothing);
      expect(find.text('T1'), findsOneWidget);
      expect((await db.transectsForStation(id)).map((t) => t.transectNumber), [1]);
    });

    testWidgets('Add transect is disabled once T1-T5 exist', (tester) async {
      _useTallSurface(tester);
      final db = await _db();
      final id = await db.insertStation(_station());
      for (var n = 1; n <= 5; n++) {
        await db.insertSession(_transect(id, n));
      }
      await tester.pumpWidget(MaterialApp(
        home: StationDetailScreen(stationId: id, openDatabase: () async => db),
      ));
      await tester.pumpAndSettle();

      final add = find.widgetWithText(ElevatedButton, 'Add transect');
      expect(tester.widget<ElevatedButton>(add).onPressed, isNull);
      expect(find.text(kFlagFewTransects), findsNothing);
    });

    // Issue #3: a colony-count station is labelled research, its rows show
    // each transect's own colony results (never pooled into a cover
    // summary), and a blinded recount stays blinded.
    testWidgets('colony count: research label, per-transect results, hidden stays hidden',
        (tester) async {
      _useTallSurface(tester);
      final db = await _db();
      final id = await db.insertStation(_station(type: SurveyType.colonyCount));
      final t1 = await db.insertSession(_transect(id, 1));
      await db.closeSession(t1, DateTime.utc(2026, 11, 15, 1, 40));
      await _colonies(db, t1, bleached: 1, healthy: 2);
      final t2 = await db.insertSession(_transect(id, 2).copyWith(resultsHidden: true));
      await _colonies(db, t2, bleached: 4, healthy: 0);

      await tester.pumpWidget(MaterialApp(
        home: StationDetailScreen(stationId: id, openDatabase: () async => db),
      ));
      await tester.pumpAndSettle();

      expect(find.text(kResearchScopeNote), findsOneWidget);
      expect(find.textContaining('3 colonies'), findsOneWidget);
      expect(find.textContaining('4 colonies'), findsNothing);
      expect(find.text('Results hidden — recount pending'), findsOneWidget);
      expect(find.text(kColonyCountNoStationSummary), findsOneWidget);
      expect(find.textContaining('coming with #8'), findsNothing);
    });

    group('laptop analysis (#7)', () {
      const corners = [(x: 0.1, y: 0.1), (x: 0.9, y: 0.1), (x: 0.9, y: 0.9), (x: 0.1, y: 0.9)];

      /// A photo transect with one framed photo, sampled; returns the results
      /// file the notebook would send, with 3 of the 10 points on coral.
      Future<({int session, String results})> framedTransect(TransectDatabase db, int stationId) async {
        final session = await db.insertSession(_transect(stationId, 1).copyWith(pointsPerFrame: 10));
        final frame = await db.insertFrame(TransectFrame(
          sessionId: session,
          meterMark: 0,
          imagePath: 'photo_transects/$session/m0.jpg',
          source: FrameSource.inApp,
          corners: corners,
          cornerSource: CornerSource.manual,
        ));
        await db.ensureFramePoints(session);
        final points = await db.pointsForFrame(frame);
        final results = jsonEncode({
          'format': 'reefsight-analysis-results',
          'version': 1,
          'model_id': 'coralscapesv2-segformer-b5',
          'transects': [
            {
              'session_id': session,
              'point_seed': (await db.sessionById(session))!.pointSeed,
              'frames': [
                {
                  'frame_id': frame,
                  'corners': [for (final c in corners) [c.x, c.y]],
                  'points': [
                    for (final pt in points)
                      {'point_id': pt.id, 'model_class': pt.pointIndex < 3 ? 'branching alive' : 'sand'},
                  ],
                },
              ],
            },
          ],
        });
        return (session: session, results: results);
      }

      testWidgets('import labels the points and the transect shows its cover', (tester) async {
        _useTallSurface(tester);
        final db = await _db();
        final id = await db.insertStation(_station());
        final t = await framedTransect(db, id);

        await tester.pumpWidget(MaterialApp(
          home: StationDetailScreen(
            stationId: id,
            openDatabase: () async => db,
            pickResultsFile: () async => t.results,
          ),
        ));
        await tester.pumpAndSettle();
        expect(find.textContaining('HC '), findsNothing);

        await tester.tap(find.text('Import analysis results'));
        await tester.pumpAndSettle();
        expect(find.text('10 points labeled in 1 transect.'), findsOneWidget);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();

        expect(find.text('HC 30.0% · Bleached 0.0% · 10 points · laptop'), findsOneWidget);
        expect(find.text('Analysis done'), findsOneWidget);
      });

      testWidgets('a results file that does not match is refused, with the reason', (tester) async {
        _useTallSurface(tester);
        final db = await _db();
        final id = await db.insertStation(_station());
        await framedTransect(db, id);

        await tester.pumpWidget(MaterialApp(
          home: StationDetailScreen(
            stationId: id,
            openDatabase: () async => db,
            pickResultsFile: () async => '{"format": "reefsight-analysis"}',
          ),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Import analysis results'));
        await tester.pumpAndSettle();

        expect(find.text('Results not imported'), findsOneWidget);
        expect(find.textContaining('exported manifest'), findsOneWidget);
      });

      testWidgets('cancelling the picker does nothing', (tester) async {
        _useTallSurface(tester);
        final db = await _db();
        final id = await db.insertStation(_station());
        await tester.pumpWidget(MaterialApp(
          home: StationDetailScreen(stationId: id, openDatabase: () async => db, pickResultsFile: () async => null),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Import analysis results'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      });

      testWidgets('export hands the station to the exporter', (tester) async {
        _useTallSurface(tester);
        final db = await _db();
        final id = await db.insertStation(_station());
        final exported = <int>[];
        await tester.pumpWidget(MaterialApp(
          home: StationDetailScreen(
            stationId: id,
            openDatabase: () async => db,
            exportForAnalysis: (stationId) async => exported.add(stationId),
          ),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Export for laptop analysis'));
        await tester.pumpAndSettle();
        expect(exported, [id]);
      });

      testWidgets('an export that fails says why', (tester) async {
        _useTallSurface(tester);
        final db = await _db();
        final id = await db.insertStation(_station());
        await tester.pumpWidget(MaterialApp(
          home: StationDetailScreen(
            stationId: id,
            openDatabase: () async => db,
            exportForAnalysis: (_) async => throw StateError('Nothing to analyze yet'),
          ),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Export for laptop analysis'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Nothing to analyze yet'), findsOneWidget);
      });

      testWidgets('colony-count and preliminary stations have no laptop analysis', (tester) async {
        _useTallSurface(tester);
        final db = await _db();
        for (final type in [SurveyType.colonyCount, SurveyType.preliminaryVideo]) {
          final id = await db.insertStation(_station(type: type));
          await tester.pumpWidget(MaterialApp(
            key: ValueKey(type),
            home: StationDetailScreen(stationId: id, openDatabase: () async => db),
          ));
          await tester.pumpAndSettle();
          expect(find.text('Export for laptop analysis'), findsNothing, reason: type.db);
          expect(find.text('Import analysis results'), findsNothing, reason: type.db);
        }
      });
    });

    testWidgets('photo stations have no research label, and no summary before any cover', (tester) async {
      _useTallSurface(tester);
      final db = await _db();
      final id = await db.insertStation(_station());
      await db.insertSession(_transect(id, 1));
      await tester.pumpWidget(MaterialApp(
        home: StationDetailScreen(stationId: id, openDatabase: () async => db),
      ));
      await tester.pumpAndSettle();

      expect(find.text(kResearchScopeNote), findsNothing);
      final button = tester.widget<OutlinedButton>(find.ancestor(
        of: find.text('Station summary'),
        matching: find.byWidgetPredicate((w) => w is OutlinedButton),
      ));
      expect(button.onPressed, isNull);
      expect(find.text(kNoSummaryYet), findsOneWidget);
    });

    // Issue #8: the station summary and its CPCe export.
    group('station summary (#8)', () {
      const corners = [(x: 0.1, y: 0.1), (x: 0.9, y: 0.1), (x: 0.9, y: 0.9), (x: 0.1, y: 0.9)];

      /// Transect [number] with one framed photo whose 10 points are [coral]
      /// branching coral and the rest sand, scored as the laptop import does.
      Future<int> scored(TransectDatabase db, int stationId, int number, int coral, {bool label = true}) async {
        final session = await db.insertSession(_transect(stationId, number).copyWith(pointsPerFrame: 10));
        final frame = await db.insertFrame(TransectFrame(
          sessionId: session,
          meterMark: 0,
          imagePath: 'photo_transects/$session/m0.jpg',
          source: FrameSource.inApp,
          corners: corners,
          cornerSource: CornerSource.manual,
        ));
        await db.ensureFramePoints(session);
        if (label) {
          for (final pt in await db.pointsForFrame(frame)) {
            final isCoral = pt.pointIndex < coral;
            await db.setPointModelLabel(
              pt.id!,
              modelClass: isCoral ? 'branching alive' : 'sand',
              categoryCode: isCoral ? 'CB' : 'S',
            );
          }
          await db.refreshTransectCover(session);
        }
        return session;
      }

      // Issue #10: diversity doesn't wait for cover, so tags alone open it.
      testWidgets('opens from the station with genus tags and no cover, showing diversity', (tester) async {
        _useTallSurface(tester);
        final db = await _db();
        final id = await db.insertStation(_station());
        final t = await scored(db, id, 1, 0, label: false);
        await db.setTransectTaus(t, {'PORM', 'HEL'}, by: 'Expert', at: DateTime.utc(2026, 11, 16));
        await tester.pumpWidget(MaterialApp(
          home: StationDetailScreen(stationId: id, openDatabase: () async => db),
        ));
        await tester.pumpAndSettle();
        expect(find.text('Genus groups tagged: 2 TAUs'), findsOneWidget);
        expect(find.text(kNoSummaryYet), findsNothing);
        await tester.tap(find.text('Station summary'));
        await tester.pumpAndSettle();
        expect(find.text(kNoCoverYet), findsOneWidget);
        expect(find.text('2 TAUs: category D'), findsOneWidget);
        expect(find.text('Export CPCe sheet'), findsOneWidget);
      });

      testWidgets('opens from the station once a transect has cover', (tester) async {
        _useTallSurface(tester);
        final db = await _db();
        final id = await db.insertStation(_station());
        await scored(db, id, 1, 3);
        await tester.pumpWidget(MaterialApp(
          home: StationDetailScreen(stationId: id, openDatabase: () async => db),
        ));
        await tester.pumpAndSettle();

        expect(find.text(kNoSummaryYet), findsNothing);
        await tester.tap(find.text('Station summary'));
        await tester.pumpAndSettle();
        expect(find.byType(StationSummaryScreen), findsOneWidget);
      });

      testWidgets('shows the station mean, SE, grade, bleaching, flags and the table', (tester) async {
        _useTallSurface(tester);
        final db = await _db();
        final id = await db.insertStation(_station());
        await scored(db, id, 1, 3);
        await scored(db, id, 2, 4);
        await scored(db, id, 3, 5);
        await scored(db, id, 4, 0, label: false);
        StationCoverSummary? exported;
        await tester.pumpWidget(MaterialApp(
          home: StationSummaryScreen(
            stationId: id,
            openDatabase: () async => db,
            exportSheet: (summary, _) async => exported = summary,
          ),
        ));
        await tester.pumpAndSettle();

        expect(find.text('40.0%'), findsOneWidget);
        expect(find.text('± 5.8 SE · 3 of 4 transects analyzed'), findsOneWidget);
        expect(find.text('B (Good)'), findsOneWidget);
        expect(find.text('Bleached coral 0.0%'), findsOneWidget);
        expect(find.text('T4 not analyzed: left out of the summary'), findsOneWidget);
        expect(find.text(kPreliminaryStamp), findsNothing);
        for (final column in ['T1', 'T2', 'T3', 'Mean', 'SD', 'SE']) {
          expect(find.text(column), findsOneWidget, reason: column);
        }
        expect(find.text('Hard coral'), findsOneWidget);
        expect(find.text('Coral branching'), findsOneWidget);

        await tester.tap(find.text('Export CPCe sheet'));
        await tester.pumpAndSettle();
        expect(exported?.n, 3);
      });

      // Issue #10: an expert's correction changes cover; tags give diversity.
      testWidgets('a point correction changes the station\'s hard coral cover', (tester) async {
        _useTallSurface(tester);
        final db = await _db();
        final id = await db.insertStation(_station());
        final t1 = await scored(db, id, 1, 3);
        await scored(db, id, 2, 4);
        await scored(db, id, 3, 5);
        // T1: one sand point corrected to coral, 3 -> 4 of 10.
        final sand = (await db.pointsForSession(t1)).firstWhere((p) => p.categoryCode == 'S');
        await db.setExpertCategory(sand.id!, 'CB', by: 'Expert', at: DateTime.utc(2026, 11, 16));
        await tester.pumpWidget(MaterialApp(
          home: StationSummaryScreen(stationId: id, openDatabase: () async => db),
        ));
        await tester.pumpAndSettle();
        expect(find.text('43.3%'), findsOneWidget);
      });

      testWidgets('shows diversity per transect and for the station, and exports it', (tester) async {
        _useTallSurface(tester);
        final db = await _db();
        final id = await db.insertStation(_station());
        final t1 = await scored(db, id, 1, 3);
        final t2 = await scored(db, id, 2, 4);
        await scored(db, id, 3, 5);
        final at = DateTime.utc(2026, 11, 16);
        await db.setTransectTaus(t1, {'PORM', 'ACB'}, by: 'Expert', at: at);
        await db.setTransectTaus(t2, {'PORM'}, by: 'Expert', at: at);
        StationDiversity? exported;
        await tester.pumpWidget(MaterialApp(
          home: StationSummaryScreen(
            stationId: id,
            openDatabase: () async => db,
            exportSheet: (_, diversity) async => exported = diversity,
          ),
        ));
        await tester.pumpAndSettle();

        expect(find.text('Generic diversity (station)'), findsOneWidget);
        expect(find.text('2 TAUs: category D'), findsOneWidget);
        expect(find.text('T1 2 · T2 1 · T3 0 TAUs'), findsOneWidget);
        expect(find.text(kDiversityScale), findsOneWidget);
        expect(find.text('T3 has no genus tags'), findsOneWidget);

        await tester.tap(find.text('Export CPCe sheet'));
        await tester.pumpAndSettle();
        expect(exported?.stationCount, 2);
      });

      testWidgets('without tags, diversity says why instead of a grade', (tester) async {
        _useTallSurface(tester);
        final db = await _db();
        final id = await db.insertStation(_station());
        await scored(db, id, 1, 3);
        await tester.pumpWidget(MaterialApp(
          home: StationSummaryScreen(stationId: id, openDatabase: () async => db),
        ));
        await tester.pumpAndSettle();
        expect(find.text(kNoDiversityYet), findsOneWidget);
        expect(find.textContaining('TAUs: category'), findsNothing);
      });

      testWidgets('a preliminary station is stamped and its grade indicative', (tester) async {
        _useTallSurface(tester);
        final db = await _db();
        final id = await db.insertStation(_station(type: SurveyType.preliminaryVideo));
        await scored(db, id, 1, 5);
        await tester.pumpWidget(MaterialApp(
          home: StationSummaryScreen(stationId: id, openDatabase: () async => db),
        ));
        await tester.pumpAndSettle();

        expect(find.text(kPreliminaryStamp), findsOneWidget);
        expect(find.text('A (Excellent), indicative'), findsOneWidget);
        expect(find.text(kFlagFewTransects), findsOneWidget);
      });

      testWidgets('with no analyzed transect it says so and offers no export', (tester) async {
        _useTallSurface(tester);
        final db = await _db();
        final id = await db.insertStation(_station());
        await scored(db, id, 1, 0, label: false);
        await tester.pumpWidget(MaterialApp(
          home: StationSummaryScreen(stationId: id, openDatabase: () async => db),
        ));
        await tester.pumpAndSettle();

        expect(find.text(kNoCoverYet), findsOneWidget);
        expect(find.text('Export CPCe sheet'), findsNothing);
      });
    });
  });

  // Issue #3's "Done when": a colony-count station records transects as the
  // current app does, grouped under the station. Live needs the camera, so
  // the stub does what Live does at start and end: insert the session with
  // the placement, record colonies, close it.
  testWidgets('end to end: three colony-count transects, each with its own Summary',
      (tester) async {
    _useTallSurface(tester);
    final db = await _db();
    final id = await db.insertStation(_station(type: SurveyType.colonyCount));
    final fake = FakeDevice();
    final started = <TransectPlacement>[];

    Future<void> fakeLive(BuildContext context, TransectStart start) async {
      final placement = start.placement!;
      started.add(placement);
      final session = placement.applyTo(
        TransectSession(
          startedAt: DateTime.utc(2026, 11, 15, placement.transectNumber),
          tapeLengthMeters: start.tapeLengthMeters,
          siteName: start.siteName,
          observerName: start.observerName,
        ),
      );
      final sessionId = await db.insertSession(session);
      await _colonies(db, sessionId, bleached: 1, healthy: placement.transectNumber);
      await db.closeSession(sessionId, session.startedAt.add(const Duration(minutes: 40)));
    }

    await tester.pumpWidget(MaterialApp(
      home: StationDetailScreen(
        stationId: id,
        openDatabase: () async => db,
        buildTransectSetup: (station) => StationTransectSetupScreen(
          station: station,
          openDatabase: () async => db,
          storageInfo: fake,
          batteryInfo: fake,
          thermalInfo: fake,
          locationProvider: FakeLocationProvider.fix(),
          startTransect: fakeLive,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    for (var n = 1; n <= 3; n++) {
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add transect'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Start Transect'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(StationDetailScreen), findsOneWidget);
    }

    expect(started.map((p) => p.transectNumber), [1, 2, 3]);
    expect(started.every((p) => p.captureSource == CaptureSource.legacyColony), isTrue);
    final transects = await db.transectsForStation(id);
    expect(transects.map((t) => t.transectNumber), [1, 2, 3]);
    expect(find.text('Complete'), findsNWidgets(3));
    for (var n = 1; n <= 3; n++) {
      expect(find.textContaining('${n + 1} colonies'), findsOneWidget);
    }
    expect(find.text(kFlagFewTransects), findsNothing);
    // Colony count never reaches the cover tables.
    for (final t in transects) {
      expect(await db.coverForSession(t.id!), isEmpty);
      expect(await db.framesForSession(t.id!), isEmpty);
    }

    // Each transect opens its own Summary, named by station and T-number.
    // Bounded pumps, not pumpAndSettle: a finished transect's Summary shows
    // the exit-fix panel, whose GPS spinner never settles under test.
    await tester.tap(find.text('T2'));
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(find.byType(SummaryScreen), findsOneWidget);
    expect(find.text('ALG-S1 · T2'), findsWidgets);
  });

  testWidgets('Home recent surveys skip photo and preliminary station transects', (tester) async {
    final db = await _db();
    final photo = await db.insertStation(_station());
    final colony = await db.insertStation(_station(type: SurveyType.colonyCount));
    await db.insertSession(_transect(photo, 1).copyWith(
      siteName: 'Photo T1',
      captureSource: CaptureSource.inAppPhotos,
    ));
    await db.insertSession(_transect(colony, 1).copyWith(
      siteName: 'Colony T1',
      captureSource: CaptureSource.legacyColony,
    ));
    await db.insertSession(
      TransectSession(startedAt: DateTime.utc(2026, 10, 4), tapeLengthMeters: 50, siteName: 'Loose'),
    );

    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(dataRevision: 0, onSeeAllSurveys: () {}, openDatabase: () async => db),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Photo T1'), findsNothing);
    expect(find.text('Colony T1'), findsOneWidget);
    expect(find.text('Loose'), findsOneWidget);
  });

  testWidgets('Surveys lists stations, and only station-less surveys as Unassigned',
      (tester) async {
    _useTallSurface(tester);
    final db = await _db();
    final id = await db.insertStation(_station());
    await db.insertSession(_transect(id, 1).copyWith(siteName: 'In Station'));
    await db.insertSession(
      TransectSession(startedAt: DateTime.utc(2026, 10, 4), tapeLengthMeters: 50, siteName: 'Loose'),
    );

    await tester.pumpWidget(MaterialApp(
      home: SurveysScreen(dataRevision: 0, openDatabase: () async => db),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Stations'), findsOneWidget);
    expect(find.text('ALG-S1'), findsOneWidget);
    expect(find.text('1 of 5 transects'), findsOneWidget);
    expect(find.text('Unassigned'), findsOneWidget);
    expect(find.text('Loose'), findsOneWidget);
    expect(find.text('In Station'), findsNothing);

    await tester.tap(find.text('ALG-S1'));
    await tester.pumpAndSettle();
    expect(find.byType(StationDetailScreen), findsOneWidget);
  });

  // Issue #4: which capture flow a station transect opens.
  test('buildCaptureScreen: in-app capture for a physical or virtual frame, import for imported, else the placeholder', () {
    CaptureStart start(SurveyType type, FrameMode? mode) => CaptureStart(
          station: Station(
            code: 'ALG-S1',
            surveyType: type,
            frameMode: mode,
            surveyedOn: DateTime(2026, 11, 15),
            createdAt: DateTime.utc(2026, 11, 14),
          ),
          sessionId: 1,
          transectNumber: 1,
        );
    expect(buildCaptureScreen(start(SurveyType.photoTransect, FrameMode.physical)),
        isA<PhotoTransectCaptureScreen>());
    expect(buildCaptureScreen(start(SurveyType.photoTransect, FrameMode.virtual)),
        isA<PhotoTransectCaptureScreen>());
    expect(buildCaptureScreen(start(SurveyType.photoTransect, FrameMode.importedMixed)),
        isA<PhotoImportScreen>());
    expect(buildCaptureScreen(start(SurveyType.preliminaryVideo, null)), isA<CapturePlaceholderScreen>());
  });

  // Issue #2's "Done when": a station with 3 transects, each opening its
  // capture flow -- since #4, the photo capture screen (fake camera), and
  // back to the station.
  testWidgets('end to end: three photo transects, each opening capture', (tester) async {
    _useTallSurface(tester);
    final db = await _db();
    final id = await db.insertStation(_station());
    final fake = FakeDevice();
    final docs = Directory.systemTemp.createTempSync('reefsight_e2e_capture_');
    addTearDown(() => docs.deleteSync(recursive: true));
    Widget capture(CaptureStart start) => PhotoTransectCaptureScreen(
          station: start.station,
          sessionId: start.sessionId,
          transectNumber: start.transectNumber,
          openDatabase: () async => db,
          cameraOpener: FakeStillCameraOpener(FakeStillCamera(docs)),
          tiltSource: FakeTiltSource(),
          screenAwake: FakeScreenAwake(),
          documentsDirectory: () async => docs.path,
        );

    await tester.pumpWidget(MaterialApp(
      home: StationDetailScreen(
        stationId: id,
        openDatabase: () async => db,
        buildTransectSetup: (station) => StationTransectSetupScreen(
          station: station,
          openDatabase: () async => db,
          storageInfo: fake,
          batteryInfo: fake,
          thermalInfo: fake,
          locationProvider: FakeLocationProvider.fix(),
          openCapture: (context, start) => Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(builder: (_) => capture(start)),
          ),
        ),
        buildCapture: capture,
      ),
    ));
    await tester.pumpAndSettle();

    for (var n = 1; n <= 3; n++) {
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add transect'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Start photo capture'));
      await tester.pumpAndSettle();
      expect(find.byType(PhotoTransectCaptureScreen), findsOneWidget);
      expect(find.text('ALG-S1 · T$n'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(StationDetailScreen), findsOneWidget);
    }

    expect(find.text('T1'), findsOneWidget);
    expect(find.text('T2'), findsOneWidget);
    expect(find.text('T3'), findsOneWidget);
    expect(find.text(kFlagFewTransects), findsNothing);
    final transects = await db.transectsForStation(id);
    expect(transects.map((t) => t.transectNumber), [1, 2, 3]);
    expect(transects.every((t) => t.captureSource == CaptureSource.inAppPhotos), isTrue);
  });
}
