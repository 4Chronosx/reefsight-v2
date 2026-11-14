import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/screens/frame_corner_editor_screen.dart';
import 'package:reefsight_mobile/screens/photo_import_screen.dart';
import 'package:reefsight_mobile/screens/station_transect_setup_screen.dart';
import 'package:reefsight_mobile/services/frame_point.dart';
import 'package:reefsight_mobile/services/photo_import.dart';
import 'package:reefsight_mobile/services/photo_metadata.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_frame.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Issue #5: the import screen (pick, order, lens question, save) and the
// corner editor (drag, copy previous, no frame visible), with a fake picker
// and metadata reader over real SQLite and real files.

class _FakeSource implements PhotoSource {
  _FakeSource(this.files);
  final List<PickedPhoto> files;

  @override
  Future<List<PickedPhoto>> pickFromFiles() async => files;

  @override
  Future<List<PickedPhoto>> pickFromLibrary() async => const [];
}

/// Copies hold their source's name, so metadata is found by contents.
class _FakeReader implements PhotoMetadataReader {
  @override
  Future<PhotoMetadata> read(String path) async {
    final name = File(path).readAsStringSync();
    final n = int.parse(RegExp(r'\d+').firstMatch(name)![0]!);
    return PhotoMetadata(
      width: 4000,
      height: 3000,
      make: 'GoPro',
      model: 'HERO11 Black',
      capturedAt: DateTime(2026, 11, 15, 9, 0, n),
    );
  }
}

void main() {
  late Directory docs;
  late Directory src;
  late TransectDatabase db;
  late Station station;
  late int sessionId;

  setUp(() async {
    docs = Directory.systemTemp.createTempSync('reefsight_import_screen_');
    src = Directory.systemTemp.createTempSync('reefsight_import_src_');
    db = await TransectDatabase.openInMemoryForTest(ignoreClose: true);
    final stationId = await db.insertStation(Station(
      code: 'ALG-S2',
      surveyType: SurveyType.photoTransect,
      frameMode: FrameMode.importedMixed,
      surveyedOn: DateTime(2026, 11, 15),
      siteName: 'Alegria MPA',
      createdAt: DateTime.utc(2026, 11, 15, 1),
    ));
    station = (await db.stationById(stationId))!;
    sessionId = await db.insertSession(TransectSession(
      startedAt: DateTime.utc(2026, 11, 15, 2),
      tapeLengthMeters: 2,
      stationId: stationId,
      transectNumber: 1,
      captureSource: CaptureSource.importedPhotos,
    ));
  });
  tearDown(() async {
    await db.closeForTest();
    for (final d in [docs, src]) {
      try {
        d.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows can hold a just-decoded image file open briefly.
      }
    }
  });

  List<PickedPhoto> files(List<String> names) => [
        for (final n in names)
          PickedPhoto(path: (File(p.join(src.path, n))..writeAsStringSync(n)).path, name: n),
      ];

  Future<void> sized(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 4200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  /// Real file and SQLite I/O runs outside the fake clock. With [until],
  /// keeps letting it run (up to ~5 s) until that finder matches -- a fixed
  /// wait was flaky under full-suite load.
  Future<void> settleIo(WidgetTester tester, [Future<void> Function()? action, Finder? until]) async {
    await tester.runAsync(() async {
      await action?.call();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    for (var i = 0; until != null && until.evaluate().isEmpty && i < 50; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
    }
  }

  Widget importScreen(List<PickedPhoto> picked) => MaterialApp(
        home: PhotoImportScreen(
          station: station,
          sessionId: sessionId,
          transectNumber: 1,
          openDatabase: () async => db,
          documentsDirectory: () async => docs.path,
          photoSource: _FakeSource(picked),
          reader: _FakeReader(),
        ),
      );

  testWidgets('an imported-photo station routes to the import screen', (tester) async {
    final w = buildCaptureScreen(CaptureStart(station: station, sessionId: sessionId, transectNumber: 1));
    expect(w, isA<PhotoImportScreen>());
  });

  testWidgets('pick from Files, ordered by time, answer the lens, save', (tester) async {
    await sized(tester);
    await tester.pumpWidget(importScreen(files(['G3.JPG', 'G1.JPG', 'G2.JPG'])));
    await settleIo(tester);

    await settleIo(tester, () => tester.tap(find.text('From Files')), find.text('2 m · G3.JPG'));
    expect(find.text('0 m · G1.JPG'), findsOneWidget);
    expect(find.text('1 m · G2.JPG'), findsOneWidget);
    expect(find.text('2 m · G3.JPG'), findsOneWidget);
    expect(find.textContaining('ordered by capture time'), findsOneWidget);
    expect(find.textContaining('Which GoPro lens mode'), findsOneWidget);
    expect(find.textContaining('Fisheye?'), findsNWidgets(3));

    await tester.tap(find.text('Linear'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Fisheye?'), findsNothing);

    await settleIo(tester, () => tester.tap(find.text('Save order')), find.text('Set corners (3 left)'));
    final frames = await tester.runAsync(() => db.framesForSession(sessionId));
    expect(frames!.map((f) => f.meterMark), [0, 1, 2]);
    expect(frames.every((f) => f.source == FrameSource.imported && f.fisheyeFlag == false), isTrue);
    expect(find.text('Set corners (3 left)'), findsOneWidget);
  });

  testWidgets('too many photos for the tape blocks saving until extras are removed', (tester) async {
    await sized(tester);
    await tester.pumpWidget(importScreen(files(['G1.JPG', 'G2.JPG', 'G3.JPG', 'G4.JPG'])));
    await settleIo(tester);
    await settleIo(tester, () => tester.tap(find.text('From Files')), find.textContaining('past the end of the tape'));

    expect(find.textContaining('past the end of the tape'), findsOneWidget);
    await settleIo(tester, () => tester.tap(find.text('Save order')));
    expect(await tester.runAsync(() => db.framesForSession(sessionId)), isEmpty);

    await tester.tap(find.byKey(const ValueKey('menu-3')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.textContaining('past the end of the tape'), findsNothing);
    await settleIo(tester, () => tester.tap(find.text('Save order')), find.text('Set corners (3 left)'));
    expect(await tester.runAsync(() => db.framesForSession(sessionId)), hasLength(3));
  });

  testWidgets('corner editor: drag a corner, save, then copy to the next photo', (tester) async {
    await sized(tester);
    await tester.runAsync(() => db.saveImportedFrames(sessionId, [
          for (var m = 0; m < 2; m++)
            TransectFrame(
              sessionId: sessionId,
              meterMark: m.toDouble(),
              imagePath: 'transect_photos/x$m.jpg',
              source: FrameSource.imported,
              widthPx: 4000,
              heightPx: 3000,
            ),
        ]));
    await tester.pumpWidget(MaterialApp(
      home: FrameCornerEditorScreen(db: db, sessionId: sessionId, documentsDirectory: docs.path, title: 'T1'),
    ));
    await settleIo(tester);
    expect(find.textContaining('2 without corners'), findsOneWidget);

    await tester.drag(find.byKey(const ValueKey('corner-0')), const Offset(-20, -20));
    await tester.pumpAndSettle();
    await settleIo(tester, () => tester.tap(find.text('Save corners')));

    var frames = (await tester.runAsync(() => db.framesForSession(sessionId)))!;
    expect(frames[0].corners, isNotNull);
    expect(frames[0].cornerSource, CornerSource.manual);
    expect(frames[0].corners!.first.x, lessThan(0.15), reason: 'dragged up-left from the default');
    expect(find.textContaining('1 without corners'), findsOneWidget, reason: 'moved on to the next photo');

    await tester.tap(find.text('Copy previous'));
    await tester.pumpAndSettle();
    await settleIo(tester, () => tester.tap(find.text('Save corners')));

    frames = (await tester.runAsync(() => db.framesForSession(sessionId)))!;
    expect(frames[1].corners, frames[0].corners);
    expect(frames[1].cornerSource, CornerSource.copied);
  });

  // Issue #10: moving corners resamples the points, so corrections go.
  testWidgets('corner editor: moving corners on a reviewed frame asks before discarding corrections',
      (tester) async {
    await sized(tester);
    const corners = <NormPoint>[(x: 0.1, y: 0.1), (x: 0.9, y: 0.1), (x: 0.9, y: 0.9), (x: 0.1, y: 0.9)];
    late int frameId;
    await tester.runAsync(() async {
      frameId = await db.insertFrame(TransectFrame(
        sessionId: sessionId,
        meterMark: 0,
        imagePath: 'transect_photos/x0.jpg',
        source: FrameSource.imported,
        widthPx: 4000,
        heightPx: 3000,
        corners: corners,
        cornerSource: CornerSource.manual,
      ));
      await db.insertFramePoints([FramePoint(frameId: frameId, pointIndex: 0, xNorm: .5, yNorm: .5, categoryCode: 'S')]);
      final point = (await db.pointsForFrame(frameId)).single.id!;
      await db.setExpertCategory(point, 'CM', by: 'Expert', at: DateTime.utc(2026, 11, 16));
    });
    await tester.pumpWidget(MaterialApp(
      home: FrameCornerEditorScreen(db: db, sessionId: sessionId, documentsDirectory: docs.path, title: 'T1'),
    ));
    await settleIo(tester);

    await tester.drag(find.byKey(const ValueKey('corner-0')), const Offset(-20, -20));
    await tester.pumpAndSettle();
    await settleIo(tester, () => tester.tap(find.text('Save corners')), find.text('Discard expert corrections?'));
    expect(find.textContaining('correction on 1 of its points'), findsOneWidget);
    await tester.tap(find.text('Keep corners'));
    await tester.pumpAndSettle();
    var points = (await tester.runAsync(() => db.pointsForFrame(frameId)))!;
    expect(points.single.expertCategoryCode, 'CM', reason: 'kept');

    await settleIo(tester, () => tester.tap(find.text('Save corners')), find.text('Move corners'));
    await settleIo(tester, () => tester.tap(find.text('Move corners')));
    points = (await tester.runAsync(() => db.pointsForFrame(frameId)))!;
    expect(points, isEmpty, reason: 'points go with the old corners');
  });

  testWidgets('corner editor: no frame visible excludes the photo', (tester) async {
    await sized(tester);
    await tester.runAsync(() => db.saveImportedFrames(sessionId, [
          TransectFrame(sessionId: sessionId, meterMark: 0, imagePath: 'transect_photos/x.jpg', source: FrameSource.imported),
        ]));
    await tester.pumpWidget(MaterialApp(
      home: FrameCornerEditorScreen(db: db, sessionId: sessionId, documentsDirectory: docs.path, title: 'T1'),
    ));
    await settleIo(tester);
    await settleIo(tester, () => tester.tap(find.text('No frame visible')));

    final frame = (await tester.runAsync(() => db.framesForSession(sessionId)))!.single;
    expect(frame.excluded, isTrue);
    expect(frame.excludeReason, kNoFrameReason);
    expect(find.textContaining('0 without corners'), findsOneWidget);
  });
}
