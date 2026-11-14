import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/screens/point_review_screen.dart';
import 'package:reefsight_mobile/services/app_settings.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_frame.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Issue #10: the expert review screen -- each frame's 10 points over its
// photo, corrections (accept, change, clear), the reviewer's name, and
// genus-group (TAU) tags per frame and on the tape. Real in-memory SQLite
// (`ignoreClose`, since the screen closes each handle it opens).

const _corners = <NormPoint>[(x: 0.1, y: 0.1), (x: 0.9, y: 0.1), (x: 0.9, y: 0.9), (x: 0.1, y: 0.9)];
final _now = DateTime.utc(2026, 11, 16, 3);

void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// A station transect with two scored frames (meters 0 and 1), every point
/// labeled by the model: meter 0 branching coral, meter 1 sand.
Future<(TransectDatabase, int)> _setUp() async {
  final db = await TransectDatabase.openInMemoryForTest(ignoreClose: true);
  addTearDown(db.closeForTest);
  final stationId = await db.insertStation(Station(
    code: 'ALG-S1',
    surveyType: SurveyType.photoTransect,
    frameMode: FrameMode.physical,
    surveyedOn: DateTime(2026, 11, 15),
    observerName: 'Diver A',
    createdAt: DateTime.utc(2026, 11, 14),
  ));
  final session = await db.insertSession(TransectSession(
    startedAt: DateTime.utc(2026, 11, 15, 2),
    tapeLengthMeters: 50,
    stationId: stationId,
    transectNumber: 1,
    pointsPerFrame: 10,
  ));
  for (final meter in [0.0, 1.0]) {
    await db.insertFrame(TransectFrame(
      sessionId: session,
      meterMark: meter,
      imagePath: 'photo_transects/$session/m$meter.jpg',
      source: FrameSource.inApp,
      corners: _corners,
      cornerSource: CornerSource.manual,
    ));
  }
  await db.ensureFramePoints(session, newSeed: () => 7);
  for (final f in await db.framesForSession(session)) {
    for (final pt in await db.pointsForFrame(f.id!)) {
      final coral = f.meterMark == 0;
      await db.setPointModelLabel(pt.id!,
          modelClass: coral ? 'branching alive' : 'sand', confidence: 0.8, categoryCode: coral ? 'CB' : 'S');
    }
  }
  return (db, session);
}

Future<void> _open(WidgetTester tester, TransectDatabase db, int session) async {
  await tester.pumpWidget(MaterialApp(
    home: PointReviewScreen(
      sessionId: session,
      title: 'Review · T1',
      openDatabase: () async => db,
      documentsDirectory: () async => '/nonexistent',
      now: () => _now,
    ),
  ));
  await tester.pumpAndSettle();
}

Future<int> _firstFrame(TransectDatabase db, int session) async => (await db.framesForSession(session)).first.id!;

void main() {
  setUp(() => AppSettings.instance.reviewerName.value = '');

  testWidgets('shows the frame, its 10 points and how many are reviewed', (tester) async {
    _useTallSurface(tester);
    final (db, session) = await _setUp();
    await _open(tester, db, session);
    expect(find.text('Frame 1 of 2 · 0 m'), findsOneWidget);
    expect(find.text('0 of 10 points reviewed'), findsOneWidget);
    for (var i = 0; i < 10; i++) {
      expect(find.byKey(ValueKey('point-$i')), findsOneWidget, reason: 'point $i');
    }
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Frame 2 of 2 · 1 m'), findsOneWidget);
  });

  testWidgets('a correction asks the reviewer\'s name once, from the station observer, and saves it', (tester) async {
    _useTallSurface(tester);
    final (db, session) = await _setUp();
    await _open(tester, db, session);
    await tester.tap(find.byKey(const ValueKey('point-3')));
    await tester.pumpAndSettle();
    expect(find.textContaining('branching alive'), findsOneWidget);
    await tester.tap(find.text('Coral massive (CM)'));
    await tester.pumpAndSettle();

    expect(find.text('Reviewer name'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Diver A'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final point = (await db.pointsForFrame(await _firstFrame(db, session)))[3];
    expect(point.expertCategoryCode, 'CM');
    expect(point.expertName, 'Diver A');
    expect(point.reviewedAt, _now);
    expect(AppSettings.instance.reviewerName.value, 'Diver A');
    expect(find.text('1 of 10 points reviewed'), findsOneWidget);

    // Remembered: the next correction doesn't ask again.
    await tester.tap(find.byKey(const ValueKey('point-4')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accept model label'));
    await tester.pumpAndSettle();
    expect(find.text('Reviewer name'), findsNothing);
    expect(find.text('2 of 10 points reviewed'), findsOneWidget);
  });

  testWidgets('after a relaunch the name is pre-filled with the station\'s last reviewer', (tester) async {
    _useTallSurface(tester);
    final (db, session) = await _setUp();
    await db.setTransectTaus(session, {'PORM'}, by: 'Dr. Reyes', at: _now);
    await _open(tester, db, session);
    await tester.tap(find.byKey(const ValueKey('point-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accept model label'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Dr. Reyes'), findsOneWidget);
  });

  testWidgets('cancelling the name writes nothing', (tester) async {
    _useTallSurface(tester);
    final (db, session) = await _setUp();
    await _open(tester, db, session);
    await tester.tap(find.byKey(const ValueKey('point-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Coral massive (CM)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    final point = (await db.pointsForFrame(await _firstFrame(db, session))).first;
    expect(point.expertCategoryCode, isNull);
  });

  testWidgets('accepting the model\'s label marks the point reviewed with the same code (D3)', (tester) async {
    _useTallSurface(tester);
    AppSettings.instance.reviewerName.value = 'Expert';
    final (db, session) = await _setUp();
    await _open(tester, db, session);
    await tester.tap(find.byKey(const ValueKey('point-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accept model label'));
    await tester.pumpAndSettle();
    final point = (await db.pointsForFrame(await _firstFrame(db, session))).first;
    expect(point.expertCategoryCode, 'CB');
    expect(point.expertName, 'Expert');
  });

  testWidgets('a correction can be cleared', (tester) async {
    _useTallSurface(tester);
    AppSettings.instance.reviewerName.value = 'Expert';
    final (db, session) = await _setUp();
    final frame = await _firstFrame(db, session);
    await db.setExpertCategory((await db.pointsForFrame(frame)).first.id!, 'CM', by: 'Expert', at: _now);
    await _open(tester, db, session);
    expect(find.text('1 of 10 points reviewed'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('point-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear correction'));
    await tester.pumpAndSettle();
    expect((await db.pointsForFrame(frame)).first.expertCategoryCode, isNull);
    expect(find.text('0 of 10 points reviewed'), findsOneWidget);
  });

  testWidgets('tags genus groups on a frame, and counts the transect\'s TAUs', (tester) async {
    _useTallSurface(tester);
    AppSettings.instance.reviewerName.value = 'Expert';
    final (db, session) = await _setUp();
    await _open(tester, db, session);
    expect(find.text('Transect: 0 TAUs'), findsOneWidget);
    await tester.tap(find.text('Tag genus groups'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Porites massive (PORM)'));
    await tester.tap(find.text('Heliopora (HEL)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    final tags = await db.genusTagsForSession(session);
    expect({for (final t in tags) t.tauCode}, {'PORM', 'HEL'});
    expect(tags.every((t) => t.frameId == tags.first.frameId && t.frameId != null), isTrue);
    expect(find.text('Transect: 2 TAUs'), findsOneWidget);
  });

  testWidgets('a photo without points (not yet exported for analysis) can still be tagged', (tester) async {
    _useTallSurface(tester);
    AppSettings.instance.reviewerName.value = 'Expert';
    final (db, session) = await _setUp();
    final extra = await db.insertFrame(TransectFrame(
      sessionId: session,
      meterMark: 2,
      imagePath: 'photo_transects/$session/m2.jpg',
      source: FrameSource.inApp,
    ));
    await _open(tester, db, session);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Frame 3 of 3 · 2 m'), findsOneWidget);
    expect(find.textContaining('No points yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('point-0')), findsNothing);
    await tester.tap(find.text('Tag genus groups'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Porites massive (PORM)'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect((await db.genusTagsForSession(session)).single.frameId, extra);
  });

  testWidgets('tags a TAU seen on the tape but in no photo, found by search', (tester) async {
    _useTallSurface(tester);
    AppSettings.instance.reviewerName.value = 'Expert';
    final (db, session) = await _setUp();
    await _open(tester, db, session);
    await tester.tap(find.text('Seen on tape, not in a photo'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'tubi');
    await tester.pumpAndSettle();
    expect(find.text('Porites massive (PORM)'), findsNothing);
    await tester.tap(find.text('Tubipora musica (TUBI)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    final tags = await db.genusTagsForSession(session);
    expect(tags.single.tauCode, 'TUBI');
    expect(tags.single.frameId, isNull);
    expect(find.text('Transect: 1 TAUs'), findsOneWidget);
  });
}
